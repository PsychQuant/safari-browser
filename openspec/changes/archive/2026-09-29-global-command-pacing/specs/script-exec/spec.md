## MODIFIED Requirements

### Requirement: Daemon-routed execution when available

When command pacing is disabled and a daemon is detected per the standard daemon opt-in rules (see `persistent-daemon` capability), the `exec` command SHALL open one daemon connection, send a single `exec.runScript` request containing the full step array plus the pre-resolved target descriptor, and receive the result array. When the daemon is unavailable, the command SHALL fall back to stateless execution: every step runs via direct `SafariBridge` calls with the shared resolved target. The stateless path SHALL produce a byte-identical result array to the daemon path for the same script + Safari state.

#### Scenario: daemon path shares one connection

- **WHEN** command pacing is disabled, daemon mode is active and a 10-step script runs
- **THEN** only one socket connection SHALL be opened for the lifetime of the `exec` invocation
- **AND** no per-step connection overhead SHALL appear in telemetry

#### Scenario: daemon unavailable triggers stateless fallback

- **WHEN** the daemon opt-in signals indicate a daemon mode but the socket is missing
- **THEN** a single `[daemon fallback: <reason>]` warning SHALL appear on stderr
- **AND** the script SHALL execute through the stateless path
- **AND** the result array SHALL be byte-identical to what the daemon path would produce

When command pacing is enabled, the client SHALL choose the existing subprocess-per-step interpreter before transmitting any batch request. Each eligible child command SHALL perform its own pacing and SHALL retain the existing per-command daemon routing. The client SHALL NOT send `exec.runScript` in this mode, SHALL NOT add an outer batch wait, and SHALL NOT select this path as a retry after a transmitted request. Disabled pacing SHALL preserve the existing batch optimization.

#### Scenario: Pacing selects the step boundary before dispatch
- **WHEN** command pacing is enabled and every script step would otherwise qualify for daemon batching
- **THEN** the client SHALL send zero `exec.runScript` requests and execute through the subprocess step dispatcher
- **AND** each eligible step SHALL complete its own pacing before the next step starts
- **AND** ordinary daemon routing SHALL remain available to each child command

#### Scenario: Explicit off restores batching
- **WHEN** `SAFARI_BROWSER_PACING=off` and the script qualifies for the existing daemon batch route
- **THEN** the client SHALL use the original single-request batch route without pacing waits
