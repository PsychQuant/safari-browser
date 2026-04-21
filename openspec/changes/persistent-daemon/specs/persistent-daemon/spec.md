## ADDED Requirements

### Requirement: Daemon mode is opt-in

The system SHALL NOT start a long-running daemon process as part of default CLI invocations. A daemon process SHALL be considered "enabled" for a given CLI invocation if and only if at least one of the following three signals holds: (a) the invocation carries the `--daemon` flag, (b) the environment variable `SAFARI_BROWSER_DAEMON` is set to `1`, or (c) a live daemon socket exists at the resolved namespace path and the owning daemon process is still running. When none of the three signals holds, CLI invocations MUST behave identically to the current stateless AppleScript path.

#### Scenario: Default invocation leaves no residual process

- **WHEN** the user runs `safari-browser documents` with neither flag nor env set, and no daemon socket pre-exists
- **THEN** the CLI process exits after completing the command and no `safari-browser` daemon process remains running

#### Scenario: Explicit flag opts in

- **WHEN** the user runs `safari-browser documents --daemon`
- **THEN** the CLI attempts to connect to the daemon socket, starting one if absent

#### Scenario: Live socket opts in without flag

- **WHEN** the user previously ran `safari-browser daemon start` and then runs `safari-browser documents` without any flag or env
- **THEN** the CLI detects the live daemon socket and routes through the daemon, without requiring the user to pass `--daemon` on every invocation

---

### Requirement: Daemon uses pre-compiled NSAppleScript handles, not process warmth, for latency reduction

The daemon SHALL pre-compile a fixed set of AppleScript source blocks into `NSAppleScript` objects held in memory for the lifetime of the daemon process, and route all Safari interactions through these pre-compiled handles rather than spawning `osascript` subprocesses per request.

#### Scenario: Repeated commands do not re-compile AppleScript

- **WHEN** the daemon serves two consecutive `snapshot` requests
- **THEN** the AppleScript source is compiled at most once — the second request reuses the cached `NSAppleScript` handle

#### Scenario: Per-command latency stays below 100 ms median

- **WHEN** the daemon has warmed up and a client issues a `documents` command
- **THEN** the round-trip latency from client request send to client response receive is less than or equal to 100 ms at the 50th percentile on a reference Mac (M-series, Safari already running)

---

### Requirement: IPC via Unix domain socket with JSON-lines protocol

The daemon SHALL listen on a Unix domain socket at the path `${TMPDIR:-/tmp}/safari-browser-<NAME>.sock`, where `<NAME>` is the namespace identifier. The wire format SHALL be newline-delimited JSON, one JSON object per line in each direction. Requests SHALL have the shape `{"method": string, "params": object, "requestId": number}`. Successful responses SHALL have `{"requestId": number, "result": object}`. Error responses SHALL have `{"requestId": number, "error": {"code": string, "message": string, "data": object}}`.

#### Scenario: Client can inspect the protocol with nc

- **WHEN** a developer runs `nc -U ${TMPDIR:-/tmp}/safari-browser-default.sock` and types a valid JSON request followed by a newline
- **THEN** the daemon responds with a single JSON line followed by a newline

#### Scenario: Request and response correlate by requestId

- **WHEN** a client sends two concurrent requests with `requestId` 1 and 2
- **THEN** each response carries the matching `requestId` so the client can pair replies without relying on order

---

### Requirement: Namespace isolation via NAME

The daemon MUST namespace its socket, pid file, and log file by a `<NAME>` identifier chosen from the first non-empty of: the `--name` CLI flag, the `SAFARI_BROWSER_NAME` environment variable, or the literal string `default`. Two daemons running with different `<NAME>` values MUST NOT share any runtime state.

#### Scenario: Two agents with different NAMEs do not collide

- **WHEN** one shell runs `SAFARI_BROWSER_NAME=alpha safari-browser daemon start` and another runs `SAFARI_BROWSER_NAME=beta safari-browser daemon start`
- **THEN** two independent daemon processes exist with distinct socket, pid, and log file paths, and commands targeted at one `<NAME>` never reach the other

---

### Requirement: No Safari state cache

The daemon MUST NOT cache any Safari-side state between requests, including but not limited to: window indices, tab indices, tab URLs, tab titles, current-tab-of-window pointers, and front-window index. The only data the daemon is permitted to hold across requests is: pre-compiled `NSAppleScript` object references, the incoming request queue, log buffers, and internal housekeeping counters (request count, last-activity timestamp).

#### Scenario: User closes a tab, daemon observes the new state on next request

- **WHEN** the user manually closes a Safari tab between daemon request N and request N+1
- **THEN** request N+1 re-queries Safari and observes the reduced tab list; the daemon MUST NOT return stale cached data referring to the closed tab

#### Scenario: User moves a tab across windows, daemon reflects new location

- **WHEN** the user drags a tab from window 1 to window 2 between requests
- **THEN** the next `--url` resolution finds the tab in window 2 and does not target its prior location in window 1

---

### Requirement: Silent fallback to stateless path on daemon failure

When the client attempts to route a command through the daemon and the attempt fails for any of the following reasons, the client SHALL transparently fall back to the existing stateless AppleScript path and print a single-line warning to stderr prefixed with `[daemon fallback: <reason>]`: (a) socket file does not exist, (b) connection refused, (c) daemon version handshake mismatch, (d) daemon returns an error that is not a domain error such as `ambiguousWindowMatch`, or (e) 15 seconds elapse without any response.

#### Scenario: Dead daemon does not break CLI

- **WHEN** the daemon process has crashed but its socket file still exists, and the user runs `safari-browser documents --daemon`
- **THEN** the CLI prints `[daemon fallback: connection refused]` to stderr and completes the command via the stateless path with the same exit code and stdout as it would have produced without `--daemon`

#### Scenario: Domain errors are not treated as daemon failures

- **WHEN** the daemon returns `{"error": {"code": "ambiguousWindowMatch", ...}}` for a `--url` query that matches multiple windows
- **THEN** the client surfaces this error directly to the user with the same exit code and stderr as the stateless path — it MUST NOT silently fall back, because fallback would produce identical ambiguity and add no value

---

### Requirement: Idle auto-shutdown

The daemon SHALL track the wall-clock timestamp of the most recent request arrival and SHALL exit cleanly (releasing its socket and pid file) when the time since that timestamp equals or exceeds the configured idle timeout. The idle timeout SHALL be configurable via the `SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT` environment variable, interpreted as an integer number of seconds, clamped to the inclusive range `[60, 3600]`. The default timeout SHALL be 600 seconds (10 minutes).

#### Scenario: Unused daemon exits after 10 minutes

- **WHEN** a daemon receives its last request at time T, no further requests arrive, and the default timeout applies
- **THEN** the daemon process exits no later than T + 600 seconds, removes its socket file, and removes its pid file

#### Scenario: Timeout below minimum is clamped

- **WHEN** the daemon starts with `SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT=10`
- **THEN** the effective timeout is 60 seconds, not 10

#### Scenario: Timeout above maximum is clamped

- **WHEN** the daemon starts with `SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT=99999`
- **THEN** the effective timeout is 3600 seconds, not 99999

---

### Requirement: Version handshake refuses mismatched client

Upon each new client connection, the daemon SHALL send a handshake message containing its build identifier (git commit hash plus semantic version) and SHALL await a matching identifier from the client. If the client's identifier does not match, the daemon SHALL close the connection and the client SHALL invoke the stateless fallback path with a `[daemon fallback: version mismatch]` stderr warning.

#### Scenario: Upgrading CLI while old daemon runs

- **WHEN** the user upgrades the `safari-browser` binary while a daemon from the prior version is still running
- **THEN** the first command from the new binary gets a version mismatch, falls back to stateless, and the user can run `safari-browser daemon stop` followed by `safari-browser daemon start` to bring the daemon up to date

---

### Requirement: Daemon subcommand group for lifecycle management

The CLI SHALL expose a `daemon` subcommand group with exactly four operations: `start`, `stop`, `status`, `logs`. `start` SHALL fork a detached daemon process, wait until the socket is accepting connections, and exit with status 0; if a live daemon already exists for the resolved `<NAME>`, `start` SHALL be a no-op that exits 0. `stop` SHALL send a shutdown request to the socket and wait for the daemon process to exit; if no daemon is running, `stop` SHALL be a no-op that exits 0. `status` SHALL print the daemon's pid, uptime, total served request count, count of pre-compiled scripts, and wall-clock timestamp of the last request. `logs` SHALL tail the daemon's log file.

#### Scenario: Start is idempotent

- **WHEN** the user runs `safari-browser daemon start` twice in a row
- **THEN** both invocations exit with status 0, and exactly one daemon process is running

#### Scenario: Stop is idempotent

- **WHEN** the user runs `safari-browser daemon stop` and no daemon is running
- **THEN** the invocation exits with status 0 without printing an error

#### Scenario: Status includes required fields

- **WHEN** the user runs `safari-browser daemon status` against a running daemon
- **THEN** the output includes, at minimum: pid, uptime, served request count, pre-compiled script count, and last request timestamp

---

### Requirement: Phase 1 command coverage

The initial daemon implementation SHALL serve at least the following commands through the daemon path when daemon mode is enabled: `snapshot`, `click`, `fill`, `type`, `press`, `js`, `documents`, `get url`, `get title`, `wait`, `storage`. Commands outside this list MAY bypass the daemon and invoke the stateless path even when daemon mode is enabled.

#### Scenario: Phase 1 command uses the daemon

- **WHEN** daemon mode is enabled and the user runs `safari-browser snapshot --url plaud`
- **THEN** the request is served by the daemon process, not by spawning `osascript` from the CLI invocation

#### Scenario: Non-Phase-1 command still works without daemon coverage

- **WHEN** daemon mode is enabled and the user runs `safari-browser screenshot --url plaud`
- **THEN** the command completes successfully by routing through the stateless path, without requiring daemon coverage
