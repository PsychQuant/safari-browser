## ADDED Requirements

### Requirement: Exec request context
Daemon exec SHALL use its request-local cached AppleScript runner directly without opening a nested daemon connection. Dialog warning flags and cached probe results MUST NOT carry across requests.

#### Scenario: Two scripts encounter the same dialog
- **WHEN** two consecutive exec requests each read a title behind a dialog
- **THEN** both requests return a diagnostic warning and retain successful title results.

### Requirement: Exec subprocess stderr delivery
The subprocess dispatcher SHALL drain stdout and stderr concurrently. It SHALL forward stderr for successful and failed steps without inserting diagnostics into stdout JSON values.

#### Scenario: Both pipes exceed capacity
- **WHEN** a subprocess writes more than 128 KiB to both stdout and stderr before exiting
- **THEN** dispatch completes and preserves all output without waiting for an undrained pipe.

### Requirement: Exec unknown outcomes are not replayed
Exec SHALL NOT rerun a transmitted script after losing its response or receiving an invalid result payload.

#### Scenario: Missing result after transmission
- **WHEN** the daemon response lacks the expected results payload
- **THEN** exec reports an unknown outcome instead of rerunning steps locally.
