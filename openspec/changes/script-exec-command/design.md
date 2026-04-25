## Context

`safari-browser` today is a pure per-invocation CLI. Every command spawns a new process (or routes through the daemon for Phase 1 commands), parses its args, resolves a target tab, runs one AppleScript block, emits JSON, and exits. This is excellent for humans and shell users but leaves agents — which often perform multi-step automation — doing repetitive plumbing: resolving the same tab three times, re-opening daemon connections, shuttling results through bash variables.

The `persistent-daemon` archive (2026-04-25) solved the cold-start tax. With a warm daemon, a 10-step shell pipeline executes in ~500ms instead of ~30s. The remaining friction is **agent ergonomics and determinism**:

1. **Tab drift** — each CLI invocation re-resolves `--url plaud` independently. If the user clicks between steps 2 and 3, the target moves.
2. **Variable shuffling** — capturing `get url` output into a shell variable and interpolating into a later step is error-prone.
3. **Conditional flow** — "only click upload if the page URL matches X" requires bash conditionals that don't compose well with JSON output.

**Stakeholders:**
- LLM agents generating scripts for headless automation
- Developers writing Safari-based integration tests
- CI pipelines verifying live deployment

**Constraints:**
- Must preserve the stateless CLI contract: no state carries across `exec` invocations
- Must not break the single-binary Swift promise (no embedded Python/JS runtime)
- Must work with and without the daemon (daemon enhances, doesn't gate)

## Goals / Non-Goals

**Goals:**
- One `exec` invocation = one daemon connection + one target resolution shared across N steps
- JSON script format simple enough for an LLM to emit without a schema library
- Clear execution semantics: straight-line steps, abort-on-error default, per-step override
- Capture-and-reference pattern for values (`var:` + `$name` substitution)
- Minimal conditional gating (`if:` with 3 operators) to avoid duplicating the host language
- Default max-steps cap (1000) preventing runaway scripts
- Testable without live Safari (interpreter unit tests + fake dispatch)

**Non-Goals:**
- In-binary DSL parser / evaluator / compiler
- Arithmetic, loops, functions, boolean combinators in the `if:` language
- Retry / backoff / timeouts per step (host handles retries by regenerating)
- Cross-invocation variable persistence
- Script-level non-interference budget
- Parallelism across steps (steps run in document order; concurrency is a footgun in browser automation)

## Decisions

### JSON script format

Each step is a JSON object with these keys:

| Key | Type | Required | Meaning |
|---|---|---|---|
| `cmd` | string | yes | Subcommand name (e.g., `"click"`, `"get url"`, `"storage local get"`) |
| `args` | array<string> | no | Positional args passed to the subcommand (default `[]`) |
| `var` | string | no | Name to bind this step's result to |
| `if` | string | no | Expression evaluated against captured vars; step skipped if false |
| `onError` | string | no | `"abort"` (default) or `"continue"` |

**Alternatives considered:**
- **Named steps with DAG edges** (`dependsOn: [...]`) — rejected. Adds graph-execution complexity for negligible gain; straight-line document order is how agents think about scripts.
- **YAML format** — rejected. JSON is universally available in every agent runtime; YAML adds a parser dependency and an indentation-sensitivity footgun.
- **TOML/HCL** — rejected for same reason as YAML.

**Rationale**: An LLM can emit the JSON format with zero schema prompting. A 10-step script is readable by a human. The Swift Codable story is trivial.

### Variable capture

A step with `"var": "result"` binds its stdout JSON value to `$result`. In later steps, any string arg starting with `$` is looked up in the variable store and replaced before dispatch.

- Values are stored as their string JSON representation (`"https://..."` becomes the string `https://...`; objects/arrays are kept as their JSON text).
- No nested paths (`$result.field`); if agents need field extraction, they use `jq` to pre-process.
- Scope is one `exec` invocation. No persistence.

**Alternatives considered:**
- **Typed variable store with JSONPath access** — rejected. Adds a path parser; agents can pre-process with `jq` or the host language.
- **No variable capture; rely on daemon state** — rejected. Daemon has no notion of "the URL returned by step 2"; state would need to be agent-assembled anyway.

**Rationale**: String substitution is the simplest thing that works. The 5% of cases needing structured access can use `jq` in the host language.

### `if:` expression language

Supported expressions:

| Form | Example | Meaning |
|---|---|---|
| `$var contains "<literal>"` | `$url contains "plaud"` | String contains |
| `$var equals "<literal>"` | `$title equals "Dashboard"` | String equality |
| `$var exists` | `$token exists` | Variable is set and non-empty |

No `and`/`or`/`not`. No parens. If agents need compound logic, they chain steps with separate `if:` clauses.

**Alternatives considered:**
- **Full JavaScript expressions via JavaScriptCore** — rejected. Adds a heavyweight framework dependency; expression evaluation becomes hard to test; security concerns around untrusted script input.
- **Lua / Starlark embedded interpreter** — rejected. New dependency; new language for agents to learn.
- **No conditional at all — every step always runs** — rejected. A huge class of real scripts needs "only do X if Y" without a bash wrapper.

**Rationale**: A tiny predicate language covers the common case (URL check, existence check) without pulling in an expression evaluator. Complex logic lives in the host.

### Command dispatch

**v1 trade-off (recorded post-implementation 2026-04-25)**: the original design called for direct `SafariBridge` calls per step, sharing one daemon connection across the whole script. The implemented v1 instead **shells out to the same `safari-browser` binary as a subprocess per step**. Reasons:

- A direct-dispatch table for all 11 Phase 1 commands (each with bespoke arg shapes — selectors, key names, target overrides, storage subcommands) is hours of mechanical work that adds little value over the subprocess fallback.
- Subprocess steps still ride the warm daemon (~50ms each) when daemon mode is opt-in, because the child binary calls `runViaRouter` at the bridge layer. The latency floor is the same.
- The motivating value of `exec` (variable capture + conditional flow + structured result array) is **independent of connection sharing** and works identically in either path.

The connection-sharing optimization is deferred to a future change. The v1 implementation:

```swift
case "click":
    let selector = args[0]
    return try await SafariBridge.click(selector: selector, target: sharedTarget, ...)
case "get url":
    return try await SafariBridge.getURL(target: sharedTarget)
```

**Alternatives considered:**
- **Invoke `safari-browser <cmd>` as subprocess per step** — rejected. Defeats the daemon-share goal; each subprocess re-resolves targets.
- **Parse args into ArgumentParser command, call its `.run()`** — rejected. ArgumentParser commands have I/O side effects (print to stdout) that don't compose into a JSON result array.
- **Reflection-driven dispatch** — rejected. Swift's reflection is weak and slow; explicit switch statement is clearer and faster.

**Rationale**: A single switch statement mapping cmd names to bridge functions is ~200 lines and has zero dependencies. Every subcommand that gets exec support needs one case added — this is low friction and explicit.

### Shared target resolution

The outer `exec` accepts `--url`/`--window`/`--document` via `TargetOptions`. The resolved `ResolvedWindowTarget` is computed once and passed to every step's dispatch call. A step can override by including a target flag in its args (e.g., `{"cmd": "get url", "args": ["--window", "2"]}`), in which case that step re-resolves.

**Rationale**: The dominant case is "all steps target the same tab"; overrides are rare enough to tolerate per-step re-resolution cost.

### Error handling

Output is a single JSON array written to stdout at end-of-script:

```json
[
  {"step": 0, "status": "ok", "value": "https://...", "var": "url"},
  {"step": 1, "status": "skipped", "reason": "if:false"},
  {"step": 2, "status": "error", "error": {"code": "elementNotFound", "message": "..."}}
]
```

- `status`: `"ok"` | `"error"` | `"skipped"`
- `value`: present only for `"ok"` steps
- `var`: present only when the step declared one
- `reason`: present only for `"skipped"` steps
- `error`: present only for `"error"` steps; same shape as top-level CLI errors

With `onError: abort` (default), the array ends at the first error step — subsequent steps are omitted (not marked `skipped`). With `onError: continue`, subsequent steps still run.

**Rationale**: A single output document is easier to parse than streaming events. Agents can `jq '.[] | select(.status == "error")'` trivially.

### Max-steps cap

Default cap enforced at parse time. `--max-steps <N>` overrides. Exceeding the cap returns a parse error without executing any steps.

**Rationale**: Defense in depth against bugs in the agent generating the script. 1000 is high enough for realistic use, low enough to prevent a runaway from burning through Safari.

### Daemon integration

When the daemon is available, the exec command opens a single connection, sends an `exec.runScript` request containing the full step array and the pre-resolved target, and receives the result array. The daemon-side handler runs the steps serially sharing the same `ResolvedWindowTarget`.

When the daemon is unavailable, exec falls through to stateless execution: each step runs via direct `SafariBridge` calls with the shared resolved target. No connection sharing, but tab-resolution sharing still holds.

**Alternatives considered:**
- **Per-step `applescript.execute` RPC** — rejected. Target resolution state would have to be serialized per request; loses the one-resolution goal.

## Risks / Trade-offs

- **[Risk] Agents over-rely on `exec` for single-step cases** → Mitigation: document that single-step exec is equivalent to direct command invocation; no performance benefit for N=1.
- **[Risk] `if:` language proves too thin and we pile on operators** → Mitigation: explicit Non-Goal; if the community needs compound logic, a future change introduces a richer evaluator as a new capability, not extension of this one.
- **[Risk] Variable substitution collides with real `$` in user data** → Mitigation: only string args starting with `$` followed by `[A-Za-z_]` are treated as vars; `\$literal` as escape; documented as a known edge case.
- **[Risk] Daemon exec handler blocks the main request actor for long scripts** → Mitigation: scripts run serially anyway; the actor model handles this naturally. A script step that would otherwise hit the actor is just "another step" — no special treatment.
- **[Risk] Stale target resolution: user clicks mid-script, target handle is still the old tab** → Mitigation: this is the **intended** semantics (determinism over user-click chasing). Documented as a feature, not a bug. Agents who want re-resolution per step pass target flags per step.
- **[Trade-off] 200-line switch in CommandDispatch.swift vs reflection** → Accept verbosity; explicit is better for testing and tooling.

## Migration Plan

1. No migration needed for existing commands or scripts. `exec` is purely additive.
2. Initial rollout implements dispatch for the Phase 1 daemon-routed commands (`click`, `fill`, `type`, `press`, `js`, `documents`, `get url`, `get title`, `wait`, `storage`, `snapshot`) — same surface as daemon coverage.
3. Commands outside Phase 1 (`screenshot`, `pdf`, `upload --native`, `upload --allow-hid`) return an `unsupportedInExec` error initially. Subsequent changes expand coverage.
4. No rollback concerns — the subcommand can be removed without affecting any other code path.

## Open Questions

- **Output streaming vs batch?** Initial design is batch (full result array at end). If scripts grow to 100+ steps and users want progress feedback, a future change could add `--stream` for NDJSON output.
- **Should `exec` register a dedicated capability in the daemon protocol, or piggy-back on existing `applescript.execute`?** Design assumes a new `exec.runScript` RPC for clarity; the daemon already has the routing scaffolding for adding one.
- **Do we need a companion `safari-browser exec --dry-run` that validates the script without running it?** Useful for CI lint; defer to a follow-up unless validation complexity demands it.
