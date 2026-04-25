# persistent-daemon Specification

## Purpose

TBD - created by archiving change 'persistent-daemon'. Update Purpose after archive.

## Requirements

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


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: Daemon uses pre-compiled NSAppleScript handles, not process warmth, for latency reduction

The daemon SHALL pre-compile a fixed set of AppleScript source blocks into `NSAppleScript` objects held in memory for the lifetime of the daemon process, and route all Safari interactions through these pre-compiled handles rather than spawning `osascript` subprocesses per request.

#### Scenario: Repeated commands do not re-compile AppleScript

- **WHEN** the daemon serves two consecutive `snapshot` requests
- **THEN** the AppleScript source is compiled at most once — the second request reuses the cached `NSAppleScript` handle

#### Scenario: Per-command latency stays below 100 ms median

- **WHEN** the daemon has warmed up and a client issues a `documents` command
- **THEN** the round-trip latency from client request send to client response receive is less than or equal to 100 ms at the 50th percentile on a reference Mac (M-series, Safari already running)


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: IPC via Unix domain socket with JSON-lines protocol

The daemon SHALL listen on a Unix domain socket at the path `${TMPDIR:-/tmp}/safari-browser-<NAME>.sock`, where `<NAME>` is the namespace identifier. The wire format SHALL be newline-delimited JSON, one JSON object per line in each direction. Requests SHALL have the shape `{"method": string, "params": object, "requestId": number}`. Successful responses SHALL have `{"requestId": number, "result": object}`. Error responses SHALL have `{"requestId": number, "error": {"code": string, "message": string, "data": object}}`.

#### Scenario: Client can inspect the protocol with nc

- **WHEN** a developer runs `nc -U ${TMPDIR:-/tmp}/safari-browser-default.sock` and types a valid JSON request followed by a newline
- **THEN** the daemon responds with a single JSON line followed by a newline

#### Scenario: Request and response correlate by requestId

- **WHEN** a client sends two concurrent requests with `requestId` 1 and 2
- **THEN** each response carries the matching `requestId` so the client can pair replies without relying on order


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: Namespace isolation via NAME

The daemon MUST namespace its socket, pid file, and log file by a `<NAME>` identifier chosen from the first non-empty of: the `--name` CLI flag, the `SAFARI_BROWSER_NAME` environment variable, or the literal string `default`. Two daemons running with different `<NAME>` values MUST NOT share any runtime state.

#### Scenario: Two agents with different NAMEs do not collide

- **WHEN** one shell runs `SAFARI_BROWSER_NAME=alpha safari-browser daemon start` and another runs `SAFARI_BROWSER_NAME=beta safari-browser daemon start`
- **THEN** two independent daemon processes exist with distinct socket, pid, and log file paths, and commands targeted at one `<NAME>` never reach the other


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: No Safari state cache

The daemon MUST NOT cache any Safari-side state between requests, including but not limited to: window indices, tab indices, tab URLs, tab titles, current-tab-of-window pointers, and front-window index. The only data the daemon is permitted to hold across requests is: pre-compiled `NSAppleScript` object references, the incoming request queue, log buffers, and internal housekeeping counters (request count, last-activity timestamp).

#### Scenario: User closes a tab, daemon observes the new state on next request

- **WHEN** the user manually closes a Safari tab between daemon request N and request N+1
- **THEN** request N+1 re-queries Safari and observes the reduced tab list; the daemon MUST NOT return stale cached data referring to the closed tab

#### Scenario: User moves a tab across windows, daemon reflects new location

- **WHEN** the user drags a tab from window 1 to window 2 between requests
- **THEN** the next `--url` resolution finds the tab in window 2 and does not target its prior location in window 1


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: Silent fallback to stateless path on daemon failure

When the client attempts to route a command through the daemon and the attempt fails for any of the following reasons, the client SHALL transparently fall back to the existing stateless AppleScript path and print a single-line warning to stderr prefixed with `[daemon fallback: <reason>]`: (a) socket file does not exist, (b) connection refused, (c) daemon version handshake mismatch, (d) daemon returns an error that is not a domain error such as `ambiguousWindowMatch`, or (e) 15 seconds elapse without any response.

#### Scenario: Dead daemon does not break CLI

- **WHEN** the daemon process has crashed but its socket file still exists, and the user runs `safari-browser documents --daemon`
- **THEN** the CLI prints `[daemon fallback: connection refused]` to stderr and completes the command via the stateless path with the same exit code and stdout as it would have produced without `--daemon`

#### Scenario: Domain errors are not treated as daemon failures

- **WHEN** the daemon returns `{"error": {"code": "ambiguousWindowMatch", ...}}` for a `--url` query that matches multiple windows
- **THEN** the client surfaces this error directly to the user with the same exit code and stderr as the stateless path — it MUST NOT silently fall back, because fallback would produce identical ambiguity and add no value


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

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


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: Version handshake refuses mismatched client

Upon each new client connection, the daemon SHALL send a handshake message containing its build identifier (git commit hash plus semantic version) and SHALL await a matching identifier from the client. If the client's identifier does not match, the daemon SHALL close the connection and the client SHALL invoke the stateless fallback path with a `[daemon fallback: version mismatch]` stderr warning.

#### Scenario: Upgrading CLI while old daemon runs

- **WHEN** the user upgrades the `safari-browser` binary while a daemon from the prior version is still running
- **THEN** the first command from the new binary gets a version mismatch, falls back to stateless, and the user can run `safari-browser daemon stop` followed by `safari-browser daemon start` to bring the daemon up to date


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

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


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: Phase 1 command coverage

The initial daemon implementation SHALL serve at least the following commands through the daemon path when daemon mode is enabled: `snapshot`, `click`, `fill`, `type`, `press`, `js`, `documents`, `get url`, `get title`, `wait`, `storage`. Commands outside this list MAY bypass the daemon and invoke the stateless path even when daemon mode is enabled.

#### Scenario: Phase 1 command uses the daemon

- **WHEN** daemon mode is enabled and the user runs `safari-browser snapshot --url plaud`
- **THEN** the request is served by the daemon process, not by spawning `osascript` from the CLI invocation

#### Scenario: Non-Phase-1 command still works without daemon coverage

- **WHEN** daemon mode is enabled and the user runs `safari-browser screenshot --url plaud`
- **THEN** the command completes successfully by routing through the stateless path, without requiring daemon coverage


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: Socket and pid file permissions

The daemon SHALL constrain filesystem permissions on its socket file and pid file to prevent cross-UID access. Specifically:

1. The directory containing the socket and pid file SHALL be per-user private. When `$TMPDIR` is set (macOS's `/var/folders/.../T/` default), the daemon SHALL use `${TMPDIR}/safari-browser-<NAME>.sock`. When `$TMPDIR` is unset, the daemon SHALL refuse to start and require `--socket-dir <path>` to be passed explicitly. Silent fallback to the world-writable `/tmp` SHALL NOT occur.
2. After bind, the socket file permissions SHALL be `0600` (owner read/write only), achieved via `umask(0077)` before bind or `fchmod(fd, 0600)` after.
3. The pid file SHALL be written with `O_CREAT | O_WRONLY | O_TRUNC` and mode `0600` using `open(2)` directly, not via `FileManager` (which ignores umask on some paths).
4. On start, the daemon SHALL stat the containing directory and refuse to start if the world-writable bit is set, unless `--allow-unsafe-socket-dir` is explicitly passed to override.

#### Scenario: TMPDIR set binds with 0600 socket

- **WHEN** `$TMPDIR=/var/folders/xx/T/` (a per-user private directory) and the daemon starts
- **THEN** the socket file at `${TMPDIR}/safari-browser-default.sock` exists with mode `0600` and is owned by the invoking user

#### Scenario: TMPDIR unset refuses to start

- **WHEN** `$TMPDIR` is unset and no `--socket-dir` is passed
- **THEN** `safari-browser daemon start` exits non-zero with stderr explaining that `$TMPDIR` must be set OR `--socket-dir <path>` passed; the daemon SHALL NOT bind to `/tmp/` silently

#### Scenario: World-writable socket-dir refused

- **WHEN** the caller passes `--socket-dir /tmp` without `--allow-unsafe-socket-dir`
- **THEN** the daemon refuses to start with stderr explaining the world-writable directory risk

#### Scenario: Other-uid cannot connect to 0600 socket

- **WHEN** user A starts the daemon in `$TMPDIR` and user B (different uid, same host) attempts `nc -U <user-A-socket-path>`
- **THEN** the connect attempt fails with `EACCES`; user B cannot drive user A's Safari via the daemon


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: IPC trust model — filesystem permissions only

The daemon SHALL rely on filesystem permissions as its sole authentication mechanism for incoming requests. Specifically:

1. The daemon SHALL NOT perform any caller-identity check, capability handshake, or secret exchange beyond the OS-enforced filesystem permissions on the socket file defined by the Socket and pid file permissions requirement.
2. The daemon MUST NOT expose its IPC interface over TCP, UDP, WebSocket, HTTP, Unix abstract-namespace sockets, or any transport other than the filesystem-backed Unix domain socket.
3. Any future proposal to add network-accessible transports (SSH forwarding, TLS tunnel, etc.) SHALL first require a separate authentication design approved via `/spectra-propose`; the current spec SHALL treat network exposure as out-of-scope and blocking at the implementation level.

#### Scenario: TCP binding attempt rejected

- **WHEN** an operator tries to start the daemon with a hypothetical `--listen-tcp :9999` option
- **THEN** the CLI rejects the option at parse time; no such option exists in the spec and none SHALL be added without a separate network-auth proposal

#### Scenario: Unix abstract namespace rejected

- **WHEN** an operator attempts to bind on `@safari-browser-default` (Linux abstract namespace) via `--socket-path`
- **THEN** the daemon rejects the path; only filesystem-backed paths are permitted, because abstract sockets bypass the filesystem permission model that this spec relies on


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: Daemon log redaction

The daemon SHALL redact or truncate sensitive payloads in its log file at `${TMPDIR:-${_refuse_per_permissions_requirement}}/safari-browser-<NAME>.log`. Specifically:

1. For `applescript.execute` / `Safari.js` / any method whose params include arbitrary user-provided code or text, the `params.code` / `params.source` field SHALL be replaced with the literal string `<redacted N bytes>` in the log (where N is the original byte length). The raw code SHALL NEVER be written to the log.
2. For methods whose `result` returns DOM content, cookies, storage values, page source, or text extraction, the result SHALL be truncated to at most 256 bytes in the log with a trailing `…(truncated)` marker. Metadata about the result (byte count, content type) MAY be logged in full.
3. Metadata about every request SHALL be preserved in the log: method name, `requestId`, client-visible error codes, wall-clock timestamps, and duration. This metadata SHALL NOT be redacted because it is the primary debugging surface.
4. An operator-controlled environment variable `SAFARI_BROWSER_DAEMON_LOG_FULL=1` MAY disable redaction for local-debugging sessions. When disabled, the daemon SHALL emit a single startup warning line to stderr stating that sensitive content is being logged verbatim.

#### Scenario: js reading cookies does not leak into log

- **WHEN** the daemon serves `safari-browser js "document.cookie" --daemon` and the result is a 512-byte cookie string
- **THEN** the log contains the method, requestId, duration, result-byte-count, and the first 256 bytes of the result with `…(truncated)` appended; it SHALL NOT contain the full 512-byte cookie

#### Scenario: AppleScript compile errors stay visible

- **WHEN** the daemon serves `applescript.execute` with a malformed source and the result is a compile error
- **THEN** the error code and message are logged in full (unredacted) because error metadata aids debugging and SHALL NOT be subject to the payload-redaction rule

#### Scenario: LOG_FULL opt-out emits warning

- **WHEN** the daemon starts with `SAFARI_BROWSER_DAEMON_LOG_FULL=1`
- **THEN** stderr shows a single line warning that redaction is disabled; subsequent log entries contain un-truncated params and results


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: Stale-pid file liveness detection

The `daemon start` command SHALL use more than a `kill(-0, pid)` probe to determine whether a prior daemon is still running before declaring "already running" or overwriting the pid file. Specifically:

1. The pid file SHALL record three fields: `(pid, executable_absolute_path, boot_timestamp_unix_seconds)`. The executable path SHALL be obtained from `_NSGetExecutablePath()` on the writing side. The boot timestamp SHALL be the daemon's own start time in seconds since epoch.
2. The liveness check SHALL:
   a. Read the stored `(pid, executable_path, boot_timestamp)` triple.
   b. Send `kill(pid, 0)` — if it returns `ESRCH` the stored pid has no live process, treat as stale.
   c. Query the target process's executable path via `proc_pidpath(pid, …)` on Darwin; if it does not match `executable_path`, treat as stale (pid was recycled to an unrelated process).
   d. Query the target process's start time via `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)` on Darwin; if it does not match `boot_timestamp` within ±2 seconds, treat as stale.
3. Stale detection SHALL cause the pid file to be overwritten with the new daemon's details; no error SHALL be raised. Non-stale detection (all three checks match) SHALL cause `start` to exit 0 as a no-op (idempotent per the lifecycle requirement).

#### Scenario: Recycled pid not treated as live

- **WHEN** the daemon crashed at pid 12345 leaving a stale pid file, and the OS has since recycled pid 12345 to an unrelated `ruby` process
- **THEN** `daemon start` reads the pid file, observes `proc_pidpath(12345) == /usr/bin/ruby` (not matching the recorded `safari-browser` executable), treats the pid file as stale, overwrites it, and starts a fresh daemon

#### Scenario: Live daemon from same binary is detected

- **WHEN** a daemon is genuinely running at pid 12345 from the same binary path and boot timestamp recorded in the pid file
- **THEN** `daemon start` confirms all three liveness fields and exits 0 as a no-op; only one daemon runs

#### Scenario: Start-time mismatch treated as stale

- **WHEN** the pid file records `(12345, /path/to/safari-browser, 1700000000)` but `proc_pidinfo(12345)` reports start time `1700100000` (later reboot recycled pid + binary path coincidence)
- **THEN** the start-time delta exceeds the ±2s tolerance, pid file is treated as stale, overwritten, and a fresh daemon starts


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: Version handshake treats dirty builds as always-mismatched

The build identifier compared during client/daemon handshake (see Requirement: Version handshake refuses mismatched client) SHALL include a `dirty` boolean flag that is `true` when the binary was built from a git working tree with uncommitted changes and `false` otherwise. The handshake SHALL compare as **mismatched** whenever either side has `dirty=true`, even if the commit hashes are byte-identical, so developer-local rebuilds always trigger a restart rather than reusing a potentially-stale pre-compiled script cache.

When a binary is built without git metadata (tarball install, Homebrew bottle, `swift build` from an untracked source tree, Nix build), the identifier SHALL include a `vendor:<vendor-id>` tag (e.g., `vendor:homebrew`, `vendor:tarball`, `vendor:unknown`). Vendor-built binaries with identical `(version, vendor, commit_or_nil)` SHALL compare as matched. Client and daemon with differing vendor tags SHALL compare as mismatched.

#### Scenario: Dirty client always mismatches clean daemon

- **WHEN** the daemon was built from a clean git tree at commit `abc1234` and the client was just rebuilt with uncommitted changes (same commit `abc1234`, dirty flag true)
- **THEN** the handshake reports mismatch; the client triggers `[daemon fallback: version mismatch]`; the user can `daemon stop` + restart to pick up the rebuilt pre-compiled cache

#### Scenario: Homebrew bottle and source build mismatch

- **WHEN** the user upgrades `safari-browser` via Homebrew (vendor:homebrew, commit `def5678`) while a source-built daemon is still running (vendor:source, commit `def5678`)
- **THEN** vendor tag mismatch triggers fallback, same as a commit mismatch

#### Scenario: Two Homebrew bottles of same version compare equal

- **WHEN** both daemon and client are Homebrew bottles of `safari-browser` 2.7.0 (same commit, same vendor, same bottle rebuild count)
- **THEN** the handshake reports matched and the client uses the daemon path


<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->

---
### Requirement: Lifecycle commands bypass the main-request actor

The daemon SHALL serve `daemon.status` and `daemon.shutdown` method requests on a path that is NOT serialized behind the main Safari-request actor. A long-running Safari request (e.g., a `wait --for-url ... --timeout 300` issued through the daemon) SHALL NOT block concurrent `daemon.status` queries or `daemon.shutdown` commands. Specifically:

1. The daemon SHALL maintain a second task / dispatch queue dedicated to lifecycle methods, OR it SHALL inspect each incoming request's `method` at the socket-accept layer and route any method in the allowlist `{daemon.status, daemon.shutdown}` to a lifecycle-only handler that does not contend for the main actor's lock.
2. `daemon.status` SHALL always return within 100 ms of arrival regardless of main-request contention, because its fields (pid, uptime, request count, etc.) are read-only counters that do not touch Safari.
3. `daemon.shutdown` SHALL cooperatively cancel any in-flight Safari request — the main-actor's current AppleScript subprocess SHALL receive `SIGTERM`, the request SHALL return `{error: {code: "cancelled", ...}}` to its original client, and the daemon SHALL proceed with the orderly shutdown sequence (remove socket, remove pid file, exit 0) within 5 seconds of the `daemon.shutdown` request's arrival.

#### Scenario: Long-running wait does not block daemon stop

- **WHEN** the daemon is serving a `wait --for-url /dashboard --timeout 300` request that has been in-flight for 90 seconds, and the user runs `safari-browser daemon stop`
- **THEN** the `daemon.shutdown` request is accepted within 100 ms, the in-flight `wait` receives `SIGTERM` and its client receives a `cancelled` error, and the daemon process exits within 5 seconds (not 210 seconds)

#### Scenario: daemon status never blocks on Safari

- **WHEN** three concurrent `daemon.status` requests arrive while the main actor is mid-AppleScript
- **THEN** each status response returns within 100 ms; no status request waits for the Safari subprocess to complete

#### Scenario: Cancelled client receives domain-level signal

- **WHEN** a client's long-running `wait` is cancelled by a concurrent `daemon.shutdown`
- **THEN** the client surfaces `{"error": {"code": "cancelled", "message": "cancelled by daemon shutdown"}}` — this is a domain error (not a transport error) per Requirement: Silent fallback to stateless path, so the client SHALL NOT retry via fallback; it surfaces the cancellation to the caller

<!-- @trace
source: persistent-daemon
updated: 2026-04-25
code:
-->
