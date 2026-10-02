## MODIFIED Requirements

### Requirement: Shared target resolution

The `exec` command SHALL accept the standard TargetOptions flags. Nine of them are *target flags*, a closed list: `--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window`, `--tab-in-window`, `--document`, `--tab` and `--profile`. `--first-match` and `--mark-tab` are not target flags and do not replace the exec-level target. When a step's `args` include any target flag (`--profile` included, e.g., `["--window", "2"]`), that step SHALL resolve using only its own target flags, which replace the exec-level ones for that step on both paths, and that resolution SHALL NOT replace the exec-level one. The replacement is whole: an exec-level `--profile` does not restrict a step that names a target flag of its own. A step that carries `--first-match` and no target flag keeps the exec-level target and is not run in-process (see Requirement: Daemon-routed execution when available), so its own `--first-match` is honoured. A multi-match `--url` at `exec` level SHALL fail closed on an ambiguous match unless `--first-match` is supplied, as the ambiguous-window-match rules say for other commands (the warning those rules write to stderr is not written on the daemon path, #220); ambiguity and `--first-match` SHALL be decided at each resolution of the exec-level target.

On the daemon path, the exec-level target SHALL be resolved when the first dispatched step needs it, not before the run (the tab-ownership marker, `--mark-tab`, is the one exception: it reads and rewrites the target's title before the first step and, in ephemeral mode, again when the run ends, and it resolves the target within `--profile` like everything else): a step skipped by `if:`, a `documents` step, and a step whose command cannot run in-process SHALL NOT trigger a resolution, and a step whose command cannot run in-process SHALL fail before any resolution. A successful resolution SHALL be reused by a later step only if the exec-level target is a URL pattern (`--url`, `--url-exact`, `--url-endswith`, or `--url-regex`, with or without `--profile`), and a check made immediately before that step, in one AppleScript, confirms that the resolved window and tab position still shows a URL the pattern accepts; that condition does not oblige reuse: a resolution that carries no window identity (an enumeration without window ids) is never reused and every step resolves afresh. This is a closed list; no other target form SHALL be reused on the grounds that it resembles one. The check establishes that the position currently shows a matching URL, not that it is still the tab that was first resolved (see Requirement: Daemon-routed execution when available). Every other exec-level target form — `--document N`, `--tab N`, `--window N`, `--window N --tab-in-window M`, `--profile` alone, and no target flag — SHALL be resolved afresh for every step. If the check fails or raises any error while the request is not cancelled, the system SHALL discard the resolution and resolve afresh; when the request is cancelled, whatever error the check raised, the system SHALL propagate the cancellation without resolving. A failed resolution SHALL leave nothing to reuse.

A cancelled request SHALL start no further step. The daemon cancels an in-flight request when it shuts down or its listener fails; it does not yet cancel one whose client has disconnected (#242). The interpreter SHALL check for cancellation before each step, on both paths. A step run in-process SHALL check before it starts and again after its target was resolved and before its command runs, whichever way it names its target (the shared one, target flags of its own, or a `documents` step that resolves nothing), so that a resolver which finishes after the cancellation is not followed by the command; the tab-ownership marker SHALL check before it wraps the title. A child process of the subprocess path that has already been started is not interrupted. A cancellation raised by a step SHALL end the run and SHALL NOT be recorded as a step error, and `onError: continue` SHALL NOT continue past it. A command that is already running is not interrupted by this requirement.

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

#### Scenario: resolved position no longer matches

- **WHEN** a daemon exec run has resolved `--url plaud` and, before the next step, the resolved position stops showing a URL that contains `plaud`: the tab navigates away, the tab closes and nothing that matches takes its place, or its window closes
- **THEN** the next step SHALL resolve `--url plaud` afresh
- **AND** SHALL report the not-found error of that resolution, or dispatch against the tab it finds

#### Scenario: a tab that takes over a matching position is not detected

- **WHEN** a daemon exec run has resolved `--url plaud` to the tab at one position, that tab closes, and the tab that moves into the position shows a URL that contains `plaud`
- **THEN** the check SHALL pass and the next step SHALL dispatch against the tab now at the position, without a further enumeration
- **AND** closing or moving a tab is not itself detected: only the URL shown at the position is checked

#### Scenario: check fails with an unrecognised error

- **WHEN** the check before reuse raises an AppleScript error whose message carries no numeric code
- **THEN** the system SHALL treat the check as failed and resolve afresh rather than fail the step

#### Scenario: a failed resolution is not reused

- **WHEN** a daemon exec run resolved `--url target` to one tab, a later step found no matching tab, and before the step after that the tab matches again while a second tab also matches
- **THEN** that step SHALL resolve afresh and report the ambiguous match
- **AND** SHALL NOT dispatch against the tab resolved before the failure

#### Scenario: a cancelled request runs nothing more

- **WHEN** a daemon exec run of five steps, every one with `onError: continue`, is cancelled while its first step is resolving the exec-level target, and the steps after it are a `documents` step, a step with a `--url` of its own, a step with a `--document` of its own, and a step that uses the exec-level target
- **THEN** the run SHALL end by propagating the cancellation, not with a result array in which a step failed
- **AND** no step after the cancellation SHALL resolve a target or issue its command
- **AND** a step whose own target was resolved by a resolver that finished after the cancellation SHALL NOT issue its command

#### Scenario: a skipped or non-resolving step triggers no resolution

- **WHEN** a daemon exec run has `--url plaud`, one step is skipped by `if:`, and another is a `documents` step
- **THEN** neither step SHALL resolve the exec-level target, whether or not `plaud` is shown by any tab

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

A step can run in-process only when its command is in the in-process set and, once its target flags are removed, its arguments have one of the following shapes (a closed list of shapes; no other shape is run in-process on the ground that it resembles one): for `js`, exactly one argument, the code, which does not start with `-`; for `documents`, no argument or only `--json`; for `get url`, `get title`, `get text` and `get source`, no argument; for `click`, `press`, `storage local get`, `storage local remove`, `storage session get` and `storage session remove`, exactly one argument that does not start with `-`; for `fill`, `type`, `storage local set` and `storage session set`, exactly two arguments, neither starting with `-`; for `storage local clear` and `storage session clear`, no argument. `wait` and `snapshot` are never run in-process, whatever their arguments: a script that has one runs as one child process per step. A target flag needs a value that does not start with `-`: a child's parser reads `--url --first-match` as a flag with no value, while the in-process dispatcher would take `--first-match` for the value. A step with a step-level `--first-match` and no target flag of its own is not run in-process either, because the in-process dispatcher would drop it. The client SHALL send a script to the daemon only when every step can run in-process, judged on the arguments as written in the script: a step with an argument that begins with a variable reference (`$name`) has no shape until it runs (`$code` may become `-1`, `$flag` may become `--first-match`), so it is not sent to the daemon; a reference after the first character of an argument cannot change its shape and does not count. The in-process dispatcher SHALL refuse a step whose command it supports but whose arguments are not one of these shapes — a `js` step with no code included — with `unsupportedArguments`, before it resolves anything; a step whose command is outside the in-process set keeps `unsupportedInExec`. A `js` step whose code starts with `-` is run by a child, where the CLI parser reads it as an option (`safari-browser js -1` fails as an unknown option; other text that is a real option is taken as that option); in-process it used to run. A `documents` step run by a child process SHALL be run with `--json`, so that it returns the same JSON rows (`[]` when there are none) as in-process. An in-process `get text` SHALL read the page's `innerText`, in chunks for a large page, when the native text is empty, as the CLI command does.

The two paths are not guaranteed to produce the same results outside what this requirement specifies. The daemon path calls the bridge directly for the commands in the in-process set; `click`, `fill`, `type`, `press` and the `storage` subcommands do it through the same function or script builder as the CLI command (`perform`, `StorageScripts`), so what they send Safari to run is the same; the subprocess path runs the CLI command, which parses more arguments and adds behaviour of its own. **Known differences** (a record of what was found; this requirement makes no promise about anything else): (1) a failing step: the daemon path reports the typed code and message, a child's failure is reported as `appleScriptFailed` with the child's stderr, and a step the dispatcher refuses for its arguments is reported as `unsupportedArguments`; (2) the daemon path does not write the stderr warning that the subprocess path's commands write when they take the first of several matches under `--first-match`; (3) the tab-ownership marker (`--mark-tab`, `--mark-tab-persist`, or `SAFARI_BROWSER_MARK_TAB`) wraps the whole run on the daemon path, so a `get title` step reads the wrapped title, while a script that runs step by step has no marker around the run: the flags are not forwarded to a step's command, and the environment variable is inherited by each step's own process, so a step that marks the tab marks it for its own duration (`exec` says on stderr that no marker is applied around the run, when the script parses and a marker was asked for); (4) whitespace at the ends of a result: the daemon path trims leading and trailing whitespace and newlines from every AppleScript result, as does a child that rides the daemon; a child that does not ride the daemon loses leading and trailing newlines only (found by reading the code, not measured against Safari). One consequence is inside a value: the innerText fallback of an in-process `get text` reads a large page in 256 KB chunks that are each trimmed before they are joined, so whitespace at a chunk boundary is lost; and a page whose native text is only whitespace counts as empty in-process and not in a stateless `get text`; (5) the same for the interaction and storage steps (`click`, `fill`, `type`, `press`, `storage`): they share the CLI command's JavaScript but are one raw `doJavaScript` through the exec-level target, and the value of a `storage ... get` is trimmed of leading and trailing whitespace on the daemon path; (6) timing: the steps of a script run back to back inside one request, where a child process per step used to leave about 0.4 s between a `click` and the next step, so a step that needs the page to have rendered after the previous one can find its element missing; and the request has one 60 s limit, after which the client reports an unknown outcome while the daemon, which does not notice a client that has gone (#242), runs the remaining steps; (7) the reuse check of the exec-level target compares the URL at the resolved position, not the tab (#241), and with these steps that reaches commands that change the page; (8) `js` in-process passes the code to `do JavaScript` unwrapped, while the CLI wraps it with an error channel and a chunked read above 1 MB, so an uncaught error or a large result may differ (not measured against Safari; see the requirement on `js` step results below). What this requirement specifies about target resolution is: a URL-pattern target is resolved at the first step that needs it on the daemon path and reused after a check, while every other target form is resolved every step on both paths, and each subprocess step resolves the exec-level target in its own command. When the set of tabs the exec-level target matches changes mid-run, the paths can therefore differ in this way: when more than one tab matches a URL target at a later step and the resolved position (window and tab index) still shows a matching URL, the daemon path dispatches against that position, which can by then hold a different tab than the one first resolved (a `js` step included: it runs on whatever tab holds that position, and its in-script check compares only the URL), while a subprocess step reports what a fresh resolution reports (the ambiguous match, or for a command that honours `--first-match` the first match). A resolved position that stops matching is resolved afresh on both paths.

#### Scenario: a step the in-process dispatcher would misread

- **WHEN** a script has a step `get text` with the argument `#selector`, or `js` with `--file script.js`, or `get url` with a stray argument
- **THEN** the client SHALL NOT send the script to the daemon; every step runs as its own command, where the selector, the option or the rejection of the stray argument is the CLI command's own

#### Scenario: the interaction and storage steps run in-process

- **WHEN** a script is made of `click`, `fill`, `type`, `press`, `storage` subcommands and the read steps, each with a runnable shape and none with an argument that begins with a `$variable`, command pacing is off, and the daemon is available
- **THEN** the client SHALL send it to the daemon in one request
- **AND** each such step SHALL send Safari the JavaScript the CLI command sends, return the value the CLI command prints (the stored value for `storage ... get`, an empty string for the others), and fail with `elementNotFound` for a missing element, as the CLI command does
- **AND** the exec-level target SHALL be resolved and checked as for the read steps

#### Scenario: a script with a `wait` or a `snapshot`

- **WHEN** a script has a `wait` step or a `snapshot` step
- **THEN** the client SHALL NOT send it to the daemon; every step runs as its own command

#### Scenario: a step that begins with a variable

- **WHEN** a script has `{"cmd":"js","args":["$n * 2"]}` after a step that binds `n` to `-4`, or `{"cmd":"get url","args":["--url","$target"]}`
- **THEN** the client SHALL NOT send the script to the daemon, so the step is run by a child with the substituted arguments

#### Scenario: a variable after the first character

- **WHEN** a script has `{"cmd":"js","args":["document.title + '$u'"]}` and every other step can run in-process
- **THEN** the script is eligible for the daemon, because a reference that does not begin the argument cannot change its shape

#### Scenario: a target flag whose value is an option

- **WHEN** a step has the arguments `--url --first-match`
- **THEN** the client SHALL NOT send the script to the daemon

#### Scenario: a marker that cannot be applied

- **WHEN** `exec --mark-tab` runs a script that is not sent to the daemon
- **THEN** a note on stderr SHALL say that no marker is applied around the run

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

- **WHEN** command pacing is disabled, daemon mode is active and a 10-step script runs in which every step can run in-process
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

### Requirement: Variable capture and substitution

When a step declares `"var": "<name>"`, the command SHALL store the step's result string under that name in a per-invocation variable store. In subsequent steps, a reference `$name` inside any string element of `args` — a `$` followed by a letter or `_` and then letters, digits or `_` — SHALL be looked up in the store and substituted before dispatch. A `$` followed by anything else (`$1`, `$%`) is not a reference and passes through unchanged. Unresolved references SHALL produce error code `undefinedVariable`. The literal string `\$` SHALL pass through as `$` without lookup. Variable scope SHALL be limited to one `exec` invocation.

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

#### Scenario: a dollar that is not a reference

- **WHEN** a step arg is `"a $1 b $% c"`
- **THEN** the arg SHALL be dispatched unchanged

## ADDED Requirements

### Requirement: `--profile` on the daemon path applies to target resolution and to `documents`

On the daemon path, an exec-level `--profile` SHALL restrict the resolution of the exec-level target to windows of that profile, so that a target that exists only in another profile is not found, SHALL restrict the result of a `documents` step to that profile, as `documents --profile` does, and SHALL restrict the tab-ownership marker's own resolution likewise (the marker takes only the exec-level profile; a step's flags never reach it). A step-level `--profile` SHALL restrict that step's own resolution; a step that names a target flag of its own is resolved by those flags alone, so an exec-level `--profile` does not restrict it (see Requirement: Shared target resolution). Before this requirement the flag was parsed on the daemon path and not applied.

#### Scenario: the profile restricts the shared target

- **WHEN** a daemon exec run has `--url plaud --profile Work` and the only tab matching `plaud` is in a window of another profile
- **THEN** the step SHALL fail with the not-found error of that resolution

#### Scenario: a step's own profile restricts that step

- **WHEN** a step of a daemon exec run carries `--url plaud --profile Work` and the only tab matching `plaud` is in a window of another profile
- **THEN** that step SHALL fail with the not-found error of its resolution

#### Scenario: an exec-level profile does not reach a step that names its own target

- **WHEN** a daemon exec run has `--profile Work` and a step carries `--url plaud` of its own, and the only tab matching `plaud` is in a window of another profile
- **THEN** that step SHALL resolve by its own `--url` alone and SHALL find that tab
- **AND** the same holds on the subprocess path

#### Scenario: the tab marker stays within the profile

- **WHEN** a daemon exec run has `--url plaud --profile Work --mark-tab` and no window of the `Work` profile shows `plaud`
- **THEN** the run SHALL fail with the not-found error before any tab title is read or written

#### Scenario: the profile restricts `documents`

- **WHEN** a daemon exec run has `--profile Work` and contains a `documents` step, and Safari has windows of profiles `Work` and `Home`
- **THEN** the step result SHALL list only the tabs of the `Work` profile
