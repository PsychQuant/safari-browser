## MODIFIED Requirements

### Requirement: Shared target resolution

The `exec` command SHALL accept the standard TargetOptions flags (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window`, `--tab-in-window`, `--document`, `--tab`, `--profile`, `--first-match`). When a step's `args` include any target flag (`--profile` included, e.g., `["--window", "2"]`), that step SHALL resolve using only its own target flags, which replace the exec-level ones for that step on both paths, and that resolution SHALL NOT replace the exec-level one. A multi-match `--url` at `exec` level SHALL fail closed on an ambiguous match unless `--first-match` is supplied, as the ambiguous-window-match rules say for other commands (the warning those rules write to stderr is not written on the daemon path, #220); ambiguity and `--first-match` SHALL be decided at each resolution of the exec-level target.

On the daemon path, the exec-level target SHALL be resolved when the first dispatched step needs it, not before the run (the tab-ownership marker, `--mark-tab`, is the one exception: it reads and rewrites the target's title before the first step and, in ephemeral mode, again when the run ends, and it resolves the target within `--profile` like everything else): a step skipped by `if:`, a `documents` step, and a step whose command cannot run in-process SHALL NOT trigger a resolution, and a step whose command cannot run in-process SHALL fail before any resolution. A successful resolution SHALL be reused by a later step in exactly one case: the exec-level target is a URL pattern (`--url`, `--url-exact`, `--url-endswith`, or `--url-regex`, with or without `--profile`), and a check made immediately before that step, in one AppleScript, confirms that the resolved tab still shows a URL the pattern accepts. This is a closed list; no other target form SHALL be reused on the grounds that it resembles one. Every other exec-level target form — `--document N`, `--tab N`, `--window N`, `--window N --tab-in-window M`, `--profile` alone, and no target flag — SHALL be resolved afresh for every step. If the check fails or raises any error while the request is not cancelled, the system SHALL discard the resolution and resolve afresh; when the request is cancelled, whatever error the check raised, the system SHALL propagate the cancellation without resolving. A failed resolution SHALL leave nothing to reuse.

Reuse is confined to one `exec.runScript` request: nothing resolved SHALL be carried across requests, and every reuse within a request is checked first. This is the scope in which the persistent-daemon rule against caching Safari state applies to exec. The reused resolution is held by the exec dispatcher, the caller of the resolver; the resolver itself keeps no state between calls, as the document-targeting requirement says.

The subprocess path resolves the exec-level target inside every step's own command and reuses nothing.

#### Scenario: shared resolution across steps

- **WHEN** `safari-browser exec --url plaud --script steps.json` runs a 3-step script on the daemon path
- **AND** none of the steps include per-step target flags
- **AND** the resolved tab keeps showing a URL that contains `plaud`
- **THEN** target resolution SHALL run exactly once, at the first step
- **AND** steps 2 and 3 SHALL each be preceded by one check of the resolved tab
- **AND** all 3 steps SHALL dispatch against the same resolved window + tab pair

#### Scenario: per-step override

- **WHEN** the exec-level target is `--url plaud` but step 2's `args` include `["--window", "2"]`
- **THEN** step 2 SHALL resolve window 2 and dispatch against that target
- **AND** the first step that needs the exec-level target SHALL resolve it, and each later step that uses it SHALL be subject to the check before reuse

#### Scenario: resolved tab no longer matches

- **WHEN** a daemon exec run has resolved `--url plaud` and the tab navigates away, closes, or its window closes before the next step
- **THEN** the next step SHALL resolve `--url plaud` afresh
- **AND** SHALL report the not-found error of that resolution, or dispatch against the tab it finds

#### Scenario: check fails with an unrecognised error

- **WHEN** the check before reuse raises an AppleScript error whose message carries no numeric code
- **THEN** the system SHALL treat the check as failed and resolve afresh rather than fail the step

#### Scenario: a failed resolution is not reused

- **WHEN** a daemon exec run resolved `--url target` to one tab, a later step found no matching tab, and before the step after that the tab matches again while a second tab also matches
- **THEN** that step SHALL resolve afresh and report the ambiguous match
- **AND** SHALL NOT dispatch against the tab resolved before the failure

#### Scenario: `--first-match` is decided at each resolution

- **WHEN** a daemon exec run has `--url plaud --first-match`, several tabs match, and 3 steps dispatch while the resolved tab keeps matching
- **THEN** the first match in window and tab order SHALL be resolved once, at the first step
- **AND** steps 2 and 3 SHALL reuse it after the check

#### Scenario: position-based targets resolve every step

- **WHEN** a daemon exec run's exec-level target is `--document 2`, `--window 1`, or `--profile Work` alone, and 3 steps dispatch
- **THEN** the target SHALL be resolved for each of the 3 steps
- **AND** no check before reuse SHALL be made

### Requirement: Daemon-routed execution when available

When command pacing is disabled and a daemon is detected per the standard daemon opt-in rules (see `persistent-daemon` capability), the `exec` command SHALL open one daemon connection, send a single `exec.runScript` request containing the full step array plus the exec-level target arguments, and receive the result array. When the daemon is unavailable, or a step cannot run in-process, the command SHALL execute through the subprocess path: every step runs as its own command, which resolves the exec-level target itself and rides the daemon when the daemon opt-in is active.

A step can run in-process only when its command is in the in-process set and, once its target flags are removed, its arguments have one of the following shapes (a closed list of shapes; no other shape is run in-process on the ground that it resembles one): for `js`, exactly one argument, the code, which does not start with `-`; for `documents`, no argument or only `--json`; for `get url`, `get title`, `get text` and `get source`, no argument. A step with a step-level `--first-match` and no target flag of its own is not run in-process either, because the in-process dispatcher would drop it. The client SHALL send a script to the daemon only when every step can run in-process, judged on the arguments as written in the script: a step whose arguments reference a variable (`$name`) has no shape until it runs (`$code` may become `-1`), so it is not sent to the daemon. The in-process dispatcher SHALL refuse a step that cannot run in-process, with `unsupportedArguments`, before it resolves anything; a target flag with no value after it is not a runnable shape. A `js` step whose code starts with `-` is run by a child, where the CLI parser reads it as an option and the step fails, as `safari-browser js -1` does; in-process it used to run. A `documents` step run by a child process SHALL be run with `--json`, so that it returns the same JSON rows (`[]` when there are none) as in-process. An in-process `get text` SHALL read the page's `innerText`, in chunks for a large page, when the native text is empty, as the CLI command does.

The two paths are not guaranteed to produce the same results outside what this requirement specifies. The daemon path calls the bridge directly for six commands; the subprocess path runs the CLI command, which parses more arguments and adds behaviour of its own. **Known differences** (a record of what was found, not a promise about anything else: any other difference is a defect to fix or to add here with its reason): (1) a failing step: the daemon path reports the typed code and message, a child's failure is reported as `appleScriptFailed` with the child's stderr, and a step the dispatcher refuses for its arguments is reported as `unsupportedArguments`; (2) the multi-match warning of the base requirement 'Exec emits a structured result array' is not written by the daemon path; (3) the tab-ownership marker (`--mark-tab`) wraps the whole run on the daemon path, so a `get title` step reads the wrapped title, while the subprocess path does not forward it at all: the flag has no effect there, and a script that has a step outside the closed list of shapes above is therefore run without the marker; (4) whitespace at the ends of a result: the daemon path trims leading and trailing whitespace and newlines from every AppleScript result, as does a child that rides the daemon; a child that does not ride the daemon loses leading and trailing newlines only (found by reading the code, not measured against Safari). One consequence is inside a value: the innerText fallback of an in-process `get text` reads a large page in 256 KB chunks that are each trimmed before they are joined, so whitespace at a chunk boundary is lost; and a page whose native text is only whitespace counts as empty in-process and not in a stateless `get text`; (5) `js` in-process passes the code to `do JavaScript` unwrapped, while the CLI wraps it with an error channel and a chunked read above 1 MB, so an uncaught error or a large result may differ (not measured against Safari; see the requirement on `js` step results below). What this requirement specifies about target resolution is: a URL-pattern target is resolved at the first step that needs it on the daemon path and reused after a check, while every other target form is resolved every step on both paths, and each subprocess step resolves the exec-level target in its own command. When the set of tabs the exec-level target matches changes mid-run, the paths can therefore differ in this way: when more than one tab matches a URL target at a later step and the resolved position (window and tab index) still shows a matching URL, the daemon path dispatches against that position, which can by then hold a different tab than the one first resolved (a `js` step included: it runs on whatever tab holds that position, and its in-script check compares only the URL), while a subprocess step reports what a fresh resolution reports (the ambiguous match, or for a command that honours `--first-match` the first match). A resolved position that stops matching is resolved afresh on both paths.

#### Scenario: a step the in-process dispatcher would misread

- **WHEN** a script has a step `get text` with the argument `#selector`, or `js` with `--file script.js`, or `get url` with a stray argument
- **THEN** the client SHALL NOT send the script to the daemon; every step runs as its own command, where the selector, the option or the rejection of the stray argument is the CLI command's own

#### Scenario: a step that references a variable

- **WHEN** a script has `{"cmd":"js","args":["$n * 2"]}` after a step that binds `n` to `-4`
- **THEN** the client SHALL NOT send the script to the daemon, so the step is run by a child with the substituted arguments

#### Scenario: a step-level first-match without a target flag

- **WHEN** a step has `--first-match` and no target flag of its own
- **THEN** it is not run in-process, so the child honours the flag

#### Scenario: documents returns the same rows on both paths

- **WHEN** a script has a `documents` step and Safari has no tabs
- **THEN** the result is `[]` whether the step ran in-process or as a child

#### Scenario: an empty native text falls back to innerText in-process

- **WHEN** a `get text` step runs in-process and the page's native text is empty
- **THEN** the step returns the page's `innerText`, as `safari-browser get text` does

#### Scenario: daemon path shares one connection

- **WHEN** command pacing is disabled, daemon mode is active and a 10-step script runs in which every step is an in-process command
- **THEN** only one socket connection SHALL be opened for the lifetime of the `exec` invocation
- **AND** no per-step connection overhead SHALL appear in telemetry

#### Scenario: daemon unavailable triggers the subprocess fallback

- **WHEN** the daemon opt-in signals indicate a daemon mode but the socket is missing
- **THEN** a `[daemon fallback: <reason>]` warning SHALL appear on stderr
- **AND** the script SHALL execute through the subprocess path
- **AND** each step's own command SHALL resolve the exec-level target

#### Scenario: a second matching tab appears mid-run

- **WHEN** an exec run with `--url plaud` has dispatched step 1 against the only matching tab, and a second tab starts matching `plaud` before step 2 while the first still matches
- **THEN** the daemon path SHALL dispatch step 2 against the resolved position, without a further enumeration
- **AND** a subprocess step SHALL resolve afresh and report the ambiguous match, or with `--first-match` on a command that honours it take the first match

When command pacing is enabled, the client SHALL choose the existing subprocess-per-step interpreter before transmitting any batch request. Each eligible child command SHALL perform its own pacing and SHALL retain the existing per-command daemon routing. The client SHALL NOT send `exec.runScript` in this mode, SHALL NOT add an outer batch wait, and SHALL NOT select this path as a retry after a transmitted request. Disabled pacing SHALL preserve the existing batch optimization.

#### Scenario: Pacing selects the step boundary before dispatch
- **WHEN** command pacing is enabled and every script step would otherwise qualify for daemon batching
- **THEN** the client SHALL send zero `exec.runScript` requests and execute through the subprocess step dispatcher
- **AND** each eligible step SHALL complete its own pacing before the next step starts
- **AND** ordinary daemon routing SHALL remain available to each child command

#### Scenario: Explicit off restores batching
- **WHEN** `SAFARI_BROWSER_PACING=off` and the script qualifies for the existing daemon batch route
- **THEN** the client SHALL use the original single-request batch route without pacing waits

### Requirement: `js` step result semantics match the CLI

A `js` step SHALL produce the same result as the CLI `js` command given the
same code, for the cases the scenarios below name. Both hand the script to
Safari's `do JavaScript`, which evaluates it as a *function body* — so a
multi-statement snippet SHALL require an explicit `return` to yield a value on
either surface, and a bare trailing expression SHALL yield `undefined` on both.

The two reach this by different routes: on the subprocess path a step is the
CLI command itself, while on the daemon path a step passes the code through
unwrapped (the CLI wraps it, #76, to carry results, errors and >1MB payloads
across an AppleScript boundary that only returns strings). Because the routes
differ, the agreement is not structural and is pinned by the scenarios below
only for the cases they name — a future change to either surface's wrapping
could silently reintroduce the divergence #80 was filed about. Other cases (the error channel and results above 1MB) are not promised to agree on the daemon path; they are difference (5) in the requirement 'Daemon-routed execution when available'. The CLI-only options `--file`, `--large` and `--output` are not run in-process at all (#220): a `js` step that has them is run by a child, where the CLI honours them.

#### Scenario: multi-statement snippet needs `return` on both surfaces

- **WHEN** a step is `{"cmd": "js", "args": ["var a = 2; a + 3"], "var": "sum"}`
- **THEN** `$sum` SHALL be `undefined`
- **AND** `safari-browser js "var a = 2; a + 3"` SHALL also yield `undefined`

#### Scenario: explicit return yields the value on both surfaces

- **WHEN** a step is `{"cmd": "js", "args": ["var a = 2; return a + 3"], "var": "sum"}`
- **THEN** `$sum` SHALL be `5`
- **AND** `safari-browser js "var a = 2; return a + 3"` SHALL also yield `5`

## ADDED Requirements

### Requirement: `--profile` on the daemon path applies to target resolution and to `documents`

On the daemon path, an exec-level or step-level `--profile` SHALL restrict target resolution to windows of that profile, so that a target that exists only in another profile is not found, SHALL restrict the result of a `documents` step to that profile, as `documents --profile` does, and SHALL restrict the tab-ownership marker's own resolution likewise. Before this requirement the flag was parsed on the daemon path and not applied.

#### Scenario: the profile restricts the shared target

- **WHEN** a daemon exec run has `--url plaud --profile Work` and the only tab matching `plaud` is in a window of another profile
- **THEN** the step SHALL fail with the not-found error of that resolution

#### Scenario: a step's own profile restricts that step

- **WHEN** a step of a daemon exec run carries `--url plaud --profile Work` and the only tab matching `plaud` is in a window of another profile
- **THEN** that step SHALL fail with the not-found error of its resolution

#### Scenario: the tab marker stays within the profile

- **WHEN** a daemon exec run has `--url plaud --profile Work --mark-tab` and no window of the `Work` profile shows `plaud`
- **THEN** the run SHALL fail with the not-found error before any tab title is read or written

#### Scenario: the profile restricts `documents`

- **WHEN** a daemon exec run has `--profile Work` and contains a `documents` step, and Safari has windows of profiles `Work` and `Home`
- **THEN** the step result SHALL list only the tabs of the `Work` profile
