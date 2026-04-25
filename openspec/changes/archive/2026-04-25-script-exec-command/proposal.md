## Why

Agents driving `safari-browser` for multi-step automation currently have two suboptimal options:

1. **Shell pipelining** — each call re-parses arguments and re-resolves the target tab, so `click; wait; get url` against `--url plaud` resolves the tab three times. If the user clicks mid-script, step 2 may target a different tab than step 1. No variable capture means bash-level `result=$(...)` dance for every value.
2. **Inline JS via `safari-browser js`** — works for everything happening inside the page, but can't orchestrate across tabs, can't call native ops like `storage local get`, and requires hand-written wrapping.

Both options leave agents doing plumbing work the binary could handle. The `persistent-daemon` archive (2026-04-25) already solved cold-start latency (~3s → ~50ms per call), so this change is about **ergonomics and determinism**, not performance: one daemon connection, one tab resolution, variable capture, minimal conditional flow, and guaranteed abort-on-error semantics.

## What Changes

- Add `safari-browser exec` subcommand that reads a JSON script from `--script <file>` or `stdin` (heredoc-friendly)
- Script format: JSON array of step objects, each shaped `{"cmd": "<command>", "args": [...], "var": "<name>"?, "if": "<expr>"?, "onError": "abort"|"continue"?}`
- **Variable capture**: step result bound to `$<var>` and usable in later step args (`{"cmd": "click", "args": ["$selector"]}`)
- **Conditional execution**: `if:` expression evaluated against captured vars; supports `contains`, `equals`, `exists` operators only (no arithmetic, no boolean combinators beyond single-predicate)
- **Error handling**: default `abort` on first step failure; `onError: continue` opt-in per step
- **Default max-steps cap**: 1000 steps per invocation (overridable via `--max-steps`), prevents runaway scripts
- **Target resolution**: single `--url` / `--window` / `--document` at the `exec` level applies to all steps unless overridden per-step
- **Daemon routing**: when daemon is available, all steps share one connection; when stateless, each step still runs but without shared connection
- **Output format**: JSON array of `{"step": N, "status": "ok"|"error"|"skipped", "value": ..., "var": "..."?}` results on stdout, one per executed step

## Non-Goals

- **Embedded Python / JS runtime** — rejected; breaks single-binary Swift promise. Users who want Python compose JSON in Python and pipe.
- **In-binary DSL with parser/evaluator** — rejected; the JSON primitive is sufficient for 95% of agent workflows. A richer DSL can be a separate layer if ever needed.
- **Arithmetic / loops / functions** — rejected; steps are straight-line with `if:` gating only. If a script needs loops, the host language (Python, shell) generates the JSON.
- **Cross-invocation state** — rejected; `var:` bindings live for one `exec` invocation only. Stateless-CLI contract preserved.
- **Script-level non-interference budget** — rejected; per-step `Spatial Gradient` rules apply individually (Layer 3 step warns; other steps stay non-interfering). No `--interference-budget=passive` flag.
- **Sandboxing beyond existing per-command semantics** — rejected; `exec` doesn't add a new attack surface. Each step still runs through the same `SafariBridge` as its standalone command.
- **Retry logic / backoff** — rejected; host language handles retry by regenerating the script. Binary stays simple.

## Capabilities

### New Capabilities

- `script-exec`: JSON-script batch execution with variable capture, conditional steps, shared target resolution, and daemon-routed execution

### Modified Capabilities

_(none)_

## Impact

**Affected specs:**
- New `openspec/specs/script-exec/spec.md` (full capability)

**Affected code:**
- `Sources/SafariBrowser/Commands/ExecCommand.swift` — new `AsyncParsableCommand`
- `Sources/SafariBrowser/SafariBrowser.swift` — register `ExecCommand` in subcommands
- `Sources/SafariBrowser/Exec/ScriptInterpreter.swift` — new module: JSON parse, step dispatch, variable store, `if:` expression eval
- `Sources/SafariBrowser/Exec/ScriptStep.swift` — new: step codable struct
- `Sources/SafariBrowser/Exec/CommandDispatch.swift` — new: maps `{"cmd":"click","args":[...]}` → existing command logic without re-parsing through ArgumentParser (direct call into `SafariBridge`)
- `Sources/SafariBrowser/Daemon/DaemonDispatch.swift` — register `exec.runScript` handler that shares one daemon connection across steps

**Affected tests:**
- `Tests/SafariBrowserTests/ScriptInterpreterTests.swift` — step parsing, variable substitution, `if:` evaluation, error semantics, max-steps cap
- `Tests/SafariBrowserTests/ExecCommandTests.swift` — end-to-end: JSON in → JSON out
- `Tests/e2e-exec-script.sh` — integration: 10-step script against live Safari, asserts shared tab resolution and variable capture

**Dependencies:**
- **Hard** — `persistent-daemon` archive (2026-04-25) for the daemon-routed path; stateless path works without
- **Soft** — `json-output` capability for output format conventions

**Breaking:** none. Purely additive subcommand.
