# tab-ownership-marker

## Purpose

Provide an opt-in, content-locked, zero-width Unicode marker on Safari tab titles that lets one `safari-browser` invocation publish "I'm working on this tab" so a sibling invocation (different process, potentially a different agent) can detect ongoing automation before issuing a destructive operation. The marker is **not** a user-visible indicator — that goal was deliberately rejected during the principle-alignment discussion (see Non-Goals in proposal). The marker's only consumer is `safari-browser tab is-marked` and downstream callers that pipe its exit code.

## ADDED Requirements

### Requirement: Marker is opt-in via `--mark-tab` flag, default OFF

The CLI SHALL NOT mutate any Safari tab title unless the caller explicitly opts in via the `--mark-tab` flag, the `SAFARI_BROWSER_MARK_TAB=1` environment variable, or one of the dedicated `safari-browser tab unmark` / `tab is-marked` subcommands. Default behavior across every existing subcommand SHALL remain byte-identical to pre-change behavior — no observable title mutation.

#### Scenario: default invocation does not mutate title

- **WHEN** a user runs `safari-browser click button.upload --url plaud` with no `--mark-tab` flag
- **AND** the env variable `SAFARI_BROWSER_MARK_TAB` is unset or `0`
- **THEN** the target tab's title before and after the operation SHALL be byte-identical
- **AND** no AppleScript `set name of tab` SHALL be issued

#### Scenario: --mark-tab flag opts into title mutation

- **WHEN** a user runs `safari-browser click button.upload --url plaud --mark-tab`
- **THEN** the tab title SHALL be wrapped with the marker before the click runs
- **AND** SHALL be unwrapped after the click completes (per Requirement: Ephemeral marker default)

#### Scenario: env var equivalent to flag

- **WHEN** a user sets `SAFARI_BROWSER_MARK_TAB=1` and runs any command without explicit `--mark-tab`
- **THEN** the command SHALL behave as if `--mark-tab` was passed

### Requirement: Marker content is hardcoded, no caller input

The marker SHALL consist of exactly two zero-width-space code points (`U+200B`) — one prefix, one suffix — bracketing the original tab title. The marker content SHALL NOT be configurable via flag, env variable, config file, or any other runtime input. The implementation SHALL define the marker as a single Swift constant in `Sources/SafariBrowser/Marker/MarkerConstants.swift` and reference it from every wrap / unwrap / detection site.

#### Scenario: marker constant is the same everywhere

- **WHEN** any code path constructs, detects, or removes a marker
- **THEN** it SHALL reference the constant from `MarkerConstants` (e.g., `MarkerConstants.prefix`, `MarkerConstants.suffix`)
- **AND** SHALL NOT use a literal `\u{200B}` or any other zero-width character inline

#### Scenario: no flag accepts caller-supplied marker content

- **WHEN** a future contributor proposes a `--mark-tab "[my-agent]"` API or any variant accepting caller content
- **THEN** the proposal SHALL be rejected without a corresponding spec amendment to this requirement
- **AND** any code path that reads marker content from caller input SHALL fail spec review

### Requirement: Ephemeral marker default

When `--mark-tab` is opted in (without `--mark-tab-persist`), the system SHALL apply the marker to the target tab's title before the operation begins and SHALL remove the marker after the operation completes (success, failure, or partial failure). The two flags SHALL be mutually exclusive: `--mark-tab` selects ephemeral mode (the default opt-in), `--mark-tab-persist` selects persist mode. In persist mode, the marker SHALL remain on the title after the invocation exits and SHALL be removed only by an explicit `safari-browser tab unmark` invocation or by Safari closing the tab.

#### Scenario: ephemeral mode wraps then restores

- **WHEN** `--mark-tab` is invoked (ephemeral implicit)
- **AND** the operation succeeds
- **THEN** the title SHALL be byte-identical before and after the invocation

#### Scenario: ephemeral cleanup runs even on operation failure

- **WHEN** `--mark-tab` is invoked
- **AND** the operation throws (e.g., `elementNotFound`)
- **THEN** the marker SHALL still be removed before the CLI exits
- **AND** the original error SHALL still be surfaced to the caller

#### Scenario: persist mode survives invocation boundary

- **WHEN** `safari-browser click button --url plaud --mark-tab persist` runs and exits 0
- **THEN** the tab title SHALL still contain the marker after exit
- **AND** a subsequent `safari-browser tab is-marked --url plaud` SHALL exit 0

#### Scenario: tab unmark removes a stuck marker

- **WHEN** a previous `--mark-tab-persist` invocation crashed before its restore step ran
- **AND** the user runs `safari-browser tab unmark --url plaud`
- **THEN** the marker SHALL be removed from the title
- **AND** the command SHALL exit 0

### Requirement: Best-effort title-restore on race

If the target tab's title changes during the operation in a way that prevents safe unwrap (page navigation, JS rewriting `document.title`, Safari rebranding), cleanup SHALL detect the divergence by comparing the in-memory expected title against the current Safari title. On detection, cleanup SHALL emit a single warning to stderr — `[mark-tab: title changed during operation; original not restored]` — and exit without further title mutation. Cleanup SHALL NOT attempt to force the original title back, retry, or enter a polling loop.

#### Scenario: navigation mid-operation triggers warning

- **WHEN** `--mark-tab` is invoked against a tab
- **AND** during the operation Safari navigates to a different URL (changing `document.title` as a side effect)
- **THEN** cleanup SHALL emit exactly one stderr line containing `mark-tab: title changed during operation`
- **AND** SHALL NOT issue any further `set name of tab` calls
- **AND** the CLI exit code SHALL reflect the original operation's outcome (success or failure), not the cleanup's race

#### Scenario: idempotent unwrap when title still matches

- **WHEN** the title at cleanup time still contains the marker pair around the same original content
- **THEN** unwrap SHALL succeed
- **AND** SHALL NOT emit a warning

### Requirement: `tab is-marked` query subcommand

The CLI SHALL expose `safari-browser tab is-marked` accepting standard `TargetOptions` and emitting no stdout output. Exit code SHALL be `0` when the resolved target tab's title currently contains the marker pair, `1` when it does not, and `2` on any other error (target not found, AppleScript failure, etc.). This is the **only** machine-readable ownership probe; no JSON output, no side effects, no marker mutation.

#### Scenario: marked tab returns exit 0

- **WHEN** a tab's title is currently wrapped by the marker
- **AND** the user runs `safari-browser tab is-marked --url plaud`
- **THEN** the command SHALL exit 0
- **AND** SHALL emit nothing on stdout

#### Scenario: unmarked tab returns exit 1

- **WHEN** a tab's title does not contain the marker
- **AND** the user runs `safari-browser tab is-marked --url plaud`
- **THEN** the command SHALL exit 1
- **AND** SHALL emit nothing on stdout

#### Scenario: target resolution failure returns exit 2

- **WHEN** `safari-browser tab is-marked --url no-such-pattern` runs
- **AND** no Safari tab matches
- **THEN** the command SHALL exit 2
- **AND** SHALL emit a `documentNotFound` error on stderr (standard error shape)

### Requirement: Daemon-spanning marker for multi-step requests

When a request is routed through `persistent-daemon` and the request carries `markTab: true`, the daemon SHALL own the wrap-and-unwrap pair across the entire request lifetime — including all internal AppleScript calls that a single command issues (e.g., `js --large` chunked reads). The marker SHALL NOT be wrapped per AppleScript call; it SHALL be wrapped once at request start and unwrapped once at request end (or on the request actor's error path).

#### Scenario: daemon marker spans chunked-read sequence

- **WHEN** an exec script issues a `js` step that triggers chunked-read (`doJavaScriptLarge`) under `--mark-tab`
- **AND** the daemon is opt-in active
- **THEN** the marker SHALL be applied exactly once before the first AppleScript call
- **AND** SHALL be removed exactly once after the last AppleScript call
- **AND** SHALL NOT toggle on every internal chunk read

### Requirement: Non-interference classification

The `--mark-tab` opt-in operation is classified as **passively interfering** per `non-interference` capability semantics: it mutates target-tab user-visible state (even if the visible diff is zero-width). The default OFF behavior SHALL remain **non-interfering**. Documentation in `non-interference/spec.md` SHALL be updated to reference this requirement and add `--mark-tab` to the explicit opt-in list alongside `--allow-hid` and `--native`.

#### Scenario: opt-in mutation is logged, default is silent

- **WHEN** any subcommand runs without `--mark-tab` and without `SAFARI_BROWSER_MARK_TAB=1`
- **THEN** no AppleScript `set name of tab` SHALL appear in the daemon log or any stderr trace

#### Scenario: opt-in mutation appears in daemon log

- **WHEN** a daemon-routed request carries `markTab: true`
- **AND** daemon logging is at default verbosity
- **THEN** the daemon log SHALL include a line indicating marker wrap and unwrap timestamps for the request
