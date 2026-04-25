# script-exec

## Purpose

Provide `safari-browser exec` — a JSON-script batch execution subcommand that runs multiple safari-browser operations in a single invocation with shared daemon connection, shared target resolution, variable capture across steps, and minimal conditional flow. Designed for LLM agents and CI pipelines that need deterministic multi-step browser automation without the plumbing cost of shell-composing individual invocations.

## ADDED Requirements

### Requirement: `exec` subcommand reads a JSON script from file or stdin

The CLI SHALL expose `safari-browser exec` as a new subcommand. It SHALL accept a JSON-script document from either `--script <path>` (file path, with tilde expansion) or standard input when no `--script` is provided. The script SHALL be a JSON array whose elements are step objects as defined in Requirement: Step object schema. Non-array roots SHALL be rejected with error code `invalidScriptFormat`.

#### Scenario: reading script from file

- **WHEN** a user runs `safari-browser exec --script /tmp/steps.json`
- **AND** the file exists and contains a valid JSON array of step objects
- **THEN** the command SHALL execute each step in document order
- **AND** SHALL emit a result array on stdout per Requirement: Exec emits a structured result array

#### Scenario: reading script from stdin

- **WHEN** a user runs `safari-browser exec` with a JSON array piped to stdin
- **THEN** the command SHALL read until EOF
- **AND** SHALL execute the steps identically to the `--script` path

#### Scenario: malformed JSON is rejected before execution

- **WHEN** the input is not valid JSON or the root is not an array
- **THEN** the command SHALL exit non-zero with `{"error":{"code":"invalidScriptFormat","message":"..."}}` on stderr
- **AND** SHALL NOT execute any steps

### Requirement: Step object schema

Each step object SHALL support the following keys, all optional except `cmd`:

| Key | Type | Required | Meaning |
|---|---|---|---|
| `cmd` | string | yes | Subcommand name, e.g., `"click"`, `"get url"`, `"storage local get"` |
| `args` | array of strings | no (default `[]`) | Positional arguments to the subcommand |
| `var` | string | no | Name under which to bind this step's result for later reference |
| `if` | string | no | Expression evaluated against captured variables; step skipped when false |
| `onError` | string | no (default `"abort"`) | `"abort"` or `"continue"` |

Unknown keys SHALL be rejected with error code `invalidStepSchema`. This is strict by design — typos like `"command"` for `"cmd"` fail loudly rather than being silently ignored.

#### Scenario: minimal step object

- **WHEN** a step is `{"cmd": "get url"}`
- **THEN** the command SHALL execute `get url` with no args and no variable binding

#### Scenario: unknown key is rejected

- **WHEN** a step contains `{"cmd": "click", "command": "button"}`
- **THEN** parsing SHALL fail with `{"error":{"code":"invalidStepSchema","message":"unknown key 'command' in step 0"}}`
- **AND** no steps SHALL execute

### Requirement: Variable capture and substitution

When a step declares `"var": "<name>"`, the command SHALL store the step's result string under that name in a per-invocation variable store. In subsequent steps, any element of `args` that is a string starting with `$` followed by one or more `[A-Za-z0-9_]` characters SHALL be looked up in the store and substituted before dispatch. Unresolved references SHALL produce error code `undefinedVariable`. The literal string `\$` SHALL pass through as `$` without lookup. Variable scope SHALL be limited to one `exec` invocation.

#### Scenario: capture and reuse

- **WHEN** step 0 is `{"cmd": "get url", "var": "currentUrl"}` and returns `"https://plaud.ai/dashboard"`
- **AND** step 1 is `{"cmd": "js", "args": ["document.title"], "var": "title"}`
- **AND** step 2 is `{"cmd": "js", "args": ["'Page at $currentUrl has title $title'"]}`
- **THEN** step 2 SHALL receive the substituted arg `'Page at https://plaud.ai/dashboard has title <title>'`

#### Scenario: undefined reference fails

- **WHEN** a step references `$unset` but no prior step bound that name
- **THEN** that step SHALL fail with `{"error":{"code":"undefinedVariable","message":"$unset is not bound"}}`
- **AND** subsequent behavior SHALL follow the step's `onError` mode

#### Scenario: escaped dollar sign is literal

- **WHEN** a step arg is `"price: \$10"`
- **THEN** the arg SHALL be dispatched as `"price: $10"` without variable lookup

### Requirement: Conditional step execution via `if:` expressions

A step with an `if:` expression SHALL be skipped when the expression evaluates to false. The expression language SHALL support exactly three operators and no boolean combinators, parentheses, arithmetic, or function calls:

| Form | Example | True when |
|---|---|---|
| `$var contains "<literal>"` | `$url contains "plaud"` | `$var` string contains the literal as a substring |
| `$var equals "<literal>"` | `$title equals "Dashboard"` | `$var` string equals the literal exactly |
| `$var exists` | `$token exists` | `$var` is bound and non-empty |

Skipped steps SHALL appear in the result array with `"status": "skipped"` and a `reason` field of `"if:false"`. Malformed expressions SHALL fail with `invalidCondition`.

#### Scenario: if:true executes step

- **WHEN** a prior step bound `$url` to `"https://plaud.ai/..."`
- **AND** the current step is `{"cmd": "click", "args": ["button.upload"], "if": "$url contains \"plaud\""}`
- **THEN** the step SHALL execute normally

#### Scenario: if:false skips step

- **WHEN** `$url` equals `"https://example.com"`
- **AND** the current step is `{"cmd": "click", "args": ["button.upload"], "if": "$url contains \"plaud\""}`
- **THEN** the step SHALL NOT execute
- **AND** the result entry SHALL be `{"step": N, "status": "skipped", "reason": "if:false"}`

#### Scenario: boolean combinators are rejected

- **WHEN** an expression contains `and`, `or`, `&&`, `||`, `!`, or parentheses
- **THEN** evaluation SHALL fail with `{"error":{"code":"invalidCondition","message":"..."}}` before executing the step

### Requirement: Error handling and abort semantics

Each step SHALL have an `onError` mode of either `"abort"` (default) or `"continue"`. When a step fails and its mode is `"abort"`, the command SHALL stop execution, emit the partial result array (ending at the failed step), and exit non-zero. When a step fails and its mode is `"continue"`, the command SHALL record the error in the result array and proceed to the next step. The invocation exit code SHALL be non-zero when the result array contains any step with `"status": "error"`, regardless of mode.

#### Scenario: default abort on first error

- **WHEN** a 5-step script has a failure at step 2 with default `onError`
- **THEN** the result array SHALL contain 3 entries (steps 0, 1, 2)
- **AND** step 2's entry SHALL have `"status": "error"`
- **AND** the command SHALL exit non-zero

#### Scenario: continue on failure

- **WHEN** a 5-step script has `onError: "continue"` on step 2 and step 2 fails
- **THEN** the result array SHALL contain 5 entries
- **AND** step 2's entry SHALL have `"status": "error"`
- **AND** steps 3 and 4 SHALL have executed normally
- **AND** the command SHALL exit non-zero because any error produces non-zero exit

### Requirement: Shared target resolution

The `exec` command SHALL accept `--url`, `--window`, `--document`, and `--tab` flags via the standard TargetOptions group. When provided, the resolved `ResolvedWindowTarget` SHALL be computed once before any step runs and passed to every step's dispatch. When a step's `args` include target flags (e.g., `["--window", "2"]`), that step SHALL re-resolve using the overriding flags. Multi-match `--url` at `exec` level SHALL behave identically to other commands per the ambiguous-window-match rules (fail-closed unless `--first-match` supplied).

#### Scenario: shared resolution across steps

- **WHEN** `safari-browser exec --url plaud --script steps.json` runs a 3-step script
- **AND** none of the steps include per-step target flags
- **THEN** target resolution SHALL run exactly once at `exec` start
- **AND** all 3 steps SHALL dispatch against the same resolved window + tab pair

#### Scenario: per-step override

- **WHEN** the exec-level target is `--url plaud` but step 2's `args` include `["--window", "2"]`
- **THEN** step 2 SHALL re-resolve for window 2 and dispatch against that target
- **AND** steps 0, 1, and 3+ SHALL continue using the exec-level resolution

### Requirement: Default max-steps cap

The command SHALL enforce a default maximum of 1000 steps per invocation. A `--max-steps <N>` flag SHALL override the default for any positive integer N. Exceeding the cap SHALL be detected at parse time and produce error code `maxStepsExceeded` without executing any steps.

#### Scenario: default cap triggers

- **WHEN** a script contains 1001 steps and no `--max-steps` override
- **THEN** parsing SHALL fail with `{"error":{"code":"maxStepsExceeded","message":"1001 steps exceeds default cap of 1000"}}`
- **AND** no steps SHALL execute

#### Scenario: override allows larger scripts

- **WHEN** `--max-steps 5000` is passed and the script has 3000 steps
- **THEN** execution SHALL proceed normally

### Requirement: Exec emits a structured result array

Upon completion (successful, aborted, or with continued errors), the command SHALL write a single JSON array to stdout. Each element SHALL be an object with:

- `step`: integer (0-indexed position in the input script)
- `status`: string `"ok"` | `"error"` | `"skipped"`
- `value`: present only for `"ok"` — string result of the step
- `var`: present only when the step declared a binding — the variable name
- `reason`: present only for `"skipped"` — skip explanation
- `error`: present only for `"error"` — object with `code` and `message` matching the standard top-level error shape

The array SHALL be the only stdout content. Non-result diagnostics (daemon fallback warnings, multi-match warnings) SHALL go to stderr.

#### Scenario: successful 3-step run

- **WHEN** three steps all succeed with step 1 binding `var: "url"`
- **THEN** stdout SHALL contain one JSON array with three elements, each `"status": "ok"`, element 1 having `"var": "url"`

#### Scenario: aborted run ends at failure

- **WHEN** step 2 of a 5-step script fails with default `abort`
- **THEN** stdout SHALL contain a 3-element array (steps 0, 1, 2)
- **AND** element 2's `status` SHALL be `"error"` with populated `error.code` and `error.message`

### Requirement: Daemon-routed execution when available

When a daemon is detected per the standard daemon opt-in rules (see `persistent-daemon` capability), the `exec` command SHALL open one daemon connection, send a single `exec.runScript` request containing the full step array plus the pre-resolved target descriptor, and receive the result array. When the daemon is unavailable, the command SHALL fall back to stateless execution: every step runs via direct `SafariBridge` calls with the shared resolved target. The stateless path SHALL produce a byte-identical result array to the daemon path for the same script + Safari state.

#### Scenario: daemon path shares one connection

- **WHEN** daemon mode is active and a 10-step script runs
- **THEN** only one socket connection SHALL be opened for the lifetime of the `exec` invocation
- **AND** no per-step connection overhead SHALL appear in telemetry

#### Scenario: daemon unavailable triggers stateless fallback

- **WHEN** the daemon opt-in signals indicate a daemon mode but the socket is missing
- **THEN** a single `[daemon fallback: <reason>]` warning SHALL appear on stderr
- **AND** the script SHALL execute through the stateless path
- **AND** the result array SHALL be byte-identical to what the daemon path would produce

### Requirement: Phase 1 command coverage

The initial implementation SHALL support dispatching at minimum the same command set covered by `persistent-daemon` Phase 1: `click`, `fill`, `type`, `press`, `js`, `documents`, `get url`, `get title`, `wait`, `storage`, and `snapshot`. Commands outside this set SHALL return error code `unsupportedInExec` when used as a step's `cmd`. The set SHALL expand in follow-up changes; additions SHALL be tracked as tasks and verified against this requirement's scenario.

#### Scenario: Phase 1 command dispatches

- **WHEN** a step is `{"cmd": "get url"}`
- **THEN** the step SHALL execute successfully against the resolved target

#### Scenario: unsupported command rejected

- **WHEN** a step is `{"cmd": "screenshot", "args": ["/tmp/out.png"]}` during initial rollout
- **THEN** the step SHALL fail with `{"error":{"code":"unsupportedInExec","message":"command 'screenshot' is not yet available in exec scripts"}}`
- **AND** subsequent step handling SHALL follow the step's `onError` mode
