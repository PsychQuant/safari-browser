## MODIFIED Requirements

### Requirement: Daemon-routed execution when available

When command pacing is disabled and a daemon is detected per the standard daemon opt-in rules (see `persistent-daemon` capability), the `exec` command SHALL open one daemon connection, send a single `exec.runScript` request containing the full step array plus the exec-level target arguments, and receive the result array. When the daemon is unavailable, its handshake does not announce the `sourceForm` capability (requirement "Client requires a capability before sending a request that needs it" of `persistent-daemon`: a daemon that predates the structured window enumeration would run the steps with its old one), or a step cannot run in-process, the command SHALL execute through the subprocess path: every step runs as its own command, which resolves the exec-level target itself and rides the daemon when the daemon opt-in is active.

A step can run in-process only when its command is in the in-process set and, once its target flags are removed, its arguments have one of the following shapes (a closed list of shapes; no other shape is run in-process on the ground that it resembles one): for `js`, exactly one argument, the code, which does not start with `-`; for `documents`, no argument or only `--json`; for `get url`, `get title`, `get text` and `get source`, no argument; for `click`, `storage local get`, `storage local remove`, `storage session get` and `storage session remove`, exactly one argument that does not start with `-`; for `press`, the same, and the key SHALL have a name, that is some character of it is not `+` (an empty key or one made only of `+` is reported by the CLI command's own error, so a child process runs it); for `fill`, `type`, `storage local set` and `storage session set`, exactly two arguments, neither starting with `-`; for `storage local clear` and `storage session clear`, no argument. `wait` and `snapshot` are never run in-process, whatever their arguments: a script that has one runs as one child process per step. A target flag needs a value that does not start with `-`: a child's parser reads `--url --first-match` as a flag with no value, while the in-process dispatcher would take `--first-match` for the value. A step with a step-level `--first-match` and no target flag of its own is not run in-process either, because the in-process dispatcher would drop it. The client SHALL send a script to the daemon only when every step can run in-process, judged on the arguments as written in the script: a step with an argument that begins with a variable reference (`$name`) has no shape until it runs (`$code` may become `-1`, `$flag` may become `--first-match`), so it is not sent to the daemon; a reference after the first character of an argument cannot change its shape and does not count, except in the key of a `press`, whose shape (whether it has a name) depends on every character: a `press` step with a reference anywhere in its key is not sent to the daemon either (`+$k` becomes nameless when `$k` is empty). The in-process dispatcher SHALL refuse a step whose command it supports but whose arguments are not one of these shapes — a `js` step with no code included — with `unsupportedArguments`, before it resolves anything; a step whose command is outside the in-process set keeps `unsupportedInExec`. A `js` step whose code starts with `-` is run by a child, where the CLI parser reads it as an option (`safari-browser js -1` fails as an unknown option; other text that is a real option is taken as that option); in-process it used to run. A `documents` step run by a child process SHALL be run with `--json`, so that it returns the same JSON rows (`[]` when there are none) as in-process. An in-process `get text` SHALL read the page's `innerText`, in chunks for a large page, when the native text is empty, as the CLI command does.

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

#### Scenario: a daemon that does not announce the source form capability

- **WHEN** pacing is off, every step can run in-process, and the daemon's handshake has no `capabilities` entry `"sourceForm"`
- **THEN** no `exec.runScript` request is sent, and the steps run through the subprocess path
- **AND** a `[daemon fallback: …]` line naming `safari-browser daemon stop` and `safari-browser daemon start` is printed for the withheld `exec.runScript`, one more for each step that enumerates windows (each step is its own command and checks the capability again), plus one when `exec --window N --profile P` resolves the window in the parent before routing (`pinWindowAtStart`)
