## MODIFIED Requirements

### Requirement: Shared target resolution

The `exec` command SHALL accept the standard TargetOptions flags. Nine of them are *target flags*, a closed list: `--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window`, `--tab-in-window`, `--document`, `--tab` and `--profile`. `--first-match` and `--mark-tab` are not target flags and do not replace the exec-level target. When a step's `args` include any target flag (`--profile` included, e.g., `["--window", "2"]`), that step SHALL resolve using only its own target flags, which replace the exec-level ones for that step on both paths, and that resolution SHALL NOT replace the exec-level one. The replacement is whole: an exec-level `--profile` does not restrict a step that names a target flag of its own. A step that carries `--first-match` and no target flag keeps the exec-level target; the subprocess path passes its `--first-match` to the step's command, while the daemon path ignores it and lets the exec-level `--first-match` decide. A multi-match `--url` at `exec` level SHALL fail closed on an ambiguous match unless `--first-match` is supplied, as the ambiguous-window-match rules say for other commands (the warning those rules write to stderr is not written on the daemon path, #220); ambiguity and `--first-match` SHALL be decided at each resolution of the exec-level target.

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

When command pacing is disabled and a daemon is detected per the standard daemon opt-in rules (see `persistent-daemon` capability), the `exec` command SHALL open one daemon connection, send a single `exec.runScript` request containing the full step array plus the exec-level target arguments, and receive the result array. When the daemon is unavailable, or a step's command cannot run in-process, the command SHALL execute through the subprocess path: every step runs as its own command, which resolves the exec-level target itself and rides the daemon when the daemon opt-in is active.

The two paths are not guaranteed to produce the same results. The daemon path calls the bridge directly for six commands; the subprocess path runs the CLI command, which parses more arguments and adds behaviour of its own (output format, fallbacks, error channels, argument handling, diagnostics on stderr). The differences known today are tracked in #220; this requirement does not list them, and it is not to be read as saying that results outside them agree. What it specifies about the two paths is target resolution: a URL-pattern target is resolved at the first step that needs it on the daemon path and reused after a check, while every other target form is resolved every step on both paths, and each subprocess step resolves the exec-level target in its own command. When the set of tabs the exec-level target matches changes mid-run, the paths can therefore differ in this way: when more than one tab matches a URL target at a later step and the resolved position (window and tab index) still shows a matching URL, the daemon path dispatches against that position, which can by then hold a different tab than the one first resolved (a `js` step included: it runs on whatever tab holds that position, and its in-script check compares only the URL), while a subprocess step reports what a fresh resolution reports (the ambiguous match, or for a command that honours `--first-match` the first match). A resolved position that stops matching is resolved afresh on both paths. The daemon path does not write the stderr warning that the subprocess path's commands write when they take the first of several matches under `--first-match` (#220).

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
could silently reintroduce the divergence #80 was filed about. Other cases (the
error channel, results above 1MB, the CLI-only options `--file`, `--large` and
`--output`) are not promised to agree on the daemon path and are tracked in #220.

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
