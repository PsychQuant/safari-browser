## MODIFIED Requirements

### Requirement: Daemon uses pre-compiled NSAppleScript handles, not process warmth, for latency reduction

The daemon SHALL compile AppleScript source blocks into `NSAppleScript` objects held in memory and route all Safari interactions through these cached handles rather than spawning `osascript` subprocesses per request. The cache SHALL hold at most 256 distinct sources, distinct by the UTF-8 bytes of the source (two sources that differ only in Unicode normalisation are two entries); when a new source would exceed that bound, the least recently used handle SHALL be evicted.

#### Scenario: Repeated commands do not re-compile AppleScript

- **WHEN** the daemon serves two consecutive `snapshot` requests
- **THEN** the AppleScript source is compiled at most once — the second request reuses the cached `NSAppleScript` handle

#### Scenario: Per-command latency stays below 100 ms median

- **WHEN** the daemon has warmed up and a client issues a `documents` command
- **THEN** the round-trip latency from client request send to client response receive is less than or equal to 100 ms at the 50th percentile on a reference Mac (M-series, Safari already running)

#### Scenario: Distinct sources beyond the bound

- **WHEN** the daemon has cached 256 distinct sources and compiles another
- **THEN** it SHALL evict the least recently used handle and keep the new one
