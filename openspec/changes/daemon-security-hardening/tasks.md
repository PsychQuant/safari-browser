## 1. Socket and pid file permissions

- [ ] 1.1 Satisfy Requirement: **Socket and pid file permissions** — in `DaemonServer.swift`, call `umask(0077)` before `bind()` (or `fchmod(fd, 0600)` immediately after bind) so the socket inode is owner-only; verify with `stat -f "%Lp"` in a test
- [ ] 1.2 Reject `$TMPDIR` unset scenario when `--socket-dir` is not passed — emit `{"error":{"code":"invalidSocketDir","message":"TMPDIR unset; pass --socket-dir or set TMPDIR"}}` on daemon start
- [ ] 1.3 Stat the containing directory for world-writable bit; reject with `invalidSocketDir` unless `--allow-unsafe-socket-dir` is passed (single stderr warning when the flag is honored)
- [ ] 1.4 Write pid file via `open(2)` with `O_CREAT|O_WRONLY|O_EXCL` + mode `0600` (not `FileManager`) so races don't leave world-readable pid files
- [ ] 1.5 Add `DaemonSocketPermissionsTests.swift` covering: (a) socket mode == 0600, (b) pid file mode == 0600, (c) TMPDIR-unset rejection, (d) world-writable parent rejection, (e) `--allow-unsafe-socket-dir` bypass path

## 2. IPC trust model — filesystem permissions only

- [ ] 2.1 Satisfy Requirement: **IPC trust model — filesystem permissions only** — remove any code path in `DaemonServer.swift` / `DaemonClient.swift` that would accept TCP or abstract-namespace sockets; add parse-time rejection in the CLI for `--listen-tcp` / `--socket-path @...` prefixes
- [ ] 2.2 Add `DaemonTrustModelTests.swift` that asserts the CLI rejects `--listen-tcp 0.0.0.0:9000` and `--socket-path @my-socket` at parse time with a clear error code (`invalidTransport`)

## 3. Daemon log redaction

- [ ] 3.1 Satisfy Requirement: **Daemon log redaction** — in the log-formatting path of `DaemonServer.Instance`, redact `params.source` for `applescript.execute` and `params.code` for `Safari.js.code` to `<redacted N bytes>`; truncate result fields for read-methods (`documents`, `get url`, `get title`, `snapshot`, `storage.get`) to 256 bytes with `…(truncated)` suffix
- [ ] 3.2 Honor `SAFARI_BROWSER_DAEMON_LOG_FULL=1` as an opt-out; emit a single stderr warning on daemon start when the opt-out is active (`[daemon] WARNING: SAFARI_BROWSER_DAEMON_LOG_FULL=1 — logs contain raw AppleScript and JS source`)
- [ ] 3.3 Add `DaemonLogRedactionTests.swift` verifying redaction of both source/code params and truncation of result fields, plus opt-out behavior

## 4. Stale-pid file liveness detection

- [ ] 4.1 Satisfy Requirement: **Stale-pid file liveness detection** — extend pid file format from `"pid\n"` to JSON `{"pid":N,"exec":"/path","boot":ts}` in `DaemonServeLoop.swift`; old single-integer format is treated as stale and overwritten
- [ ] 4.2 Implement 3-check liveness in `DaemonServeLoop.isDaemonAlive`: (a) `kill(pid, 0) == 0`, (b) `proc_pidpath(pid)` matches recorded `exec`, (c) `proc_pidinfo` start-time within ±2s of recorded `boot`; all three must pass for "alive"
- [ ] 4.3 Add `StalePidLivenessTests.swift` covering (a) recycled-pid case (same pid, different binary → stale), (b) binary-path-mismatch case (pid alive but `/tmp/cp` not `safari-browser` → stale), (c) happy path (same binary + start-time → alive)

## 5. Version handshake edge cases

- [ ] 5.1 Satisfy Requirement: **Version handshake treats dirty builds as always-mismatched** — extend `DaemonProtocol.currentVersion` struct to `{"semver":...,"commit":...,"dirty":bool,"vendor":"git|tarball|homebrew|source"}`; update `encodeHandshake` / `decodeHandshakeVersion`; source `dirty` and `vendor` from build-time metadata (inject via Swift build flag or generated file)
- [ ] 5.2 Handshake comparison returns mismatch when (a) either side has `dirty=true`, regardless of commit equality, or (b) `vendor` differs between sides; document both rules in the `DaemonProtocol` docstring
- [ ] 5.3 Add `DaemonHandshakeEdgeCaseTests.swift` covering (a) matching clean commits → match, (b) matching commits but one dirty → mismatch, (c) matching commits but different vendor → mismatch, (d) old single-string version format → mismatch (forward-compat: old daemons get restarted)

## 6. Lifecycle commands bypass main-request actor

- [ ] 6.1 Satisfy Requirement: **Lifecycle commands bypass the main-request actor** — at the socket-accept layer in `DaemonServer.swift`, inspect incoming method before enqueueing; `daemon.status` and `daemon.shutdown` run on a separate dispatch path (direct-invocation Task, not the main actor)
- [ ] 6.2 On `daemon.shutdown`, identify any in-flight AppleScript subprocess via its PID (tracked in the main-request actor) and `SIGTERM` it; the interrupted request surfaces `{error:{code:"cancelled","message":"cancelled by daemon shutdown"}}` to its client; this is a domain error per Requirement: Silent fallback to stateless path, so clients do NOT retry via fallback (they surface cancellation to caller)
- [ ] 6.3 Full shutdown (socket close + pid removal + process exit) MUST complete within 5 seconds of `daemon.shutdown` receipt, even with an AppleScript subprocess mid-execution; add a 5s watchdog that force-kills if graceful path stalls
- [ ] 6.4 Add `DaemonLifecycleCancellationTests.swift` covering (a) `daemon.status` returns during an active long-running AppleScript (proves bypass works), (b) `daemon.shutdown` during AppleScript mid-run produces `cancelled` error on the original client AND completes shutdown within 5s, (c) client receiving `cancelled` does NOT attempt fallback (asserts error code propagates through `DaemonClient.Error.fallbackReason` returning nil)

## 7. Verification

- [ ] 7.1 Run full unit suite (`make test`) — all new test files green, no regressions in existing `DaemonServerIPCTests` / `DaemonClientTests` / `DaemonIdleTimeoutTests` / `DaemonProtocolTests` / `DaemonConcurrencyTests`
- [ ] 7.2 Run `make test-daemon-parity` — parity with stateless mode still holds (security hardening must not break the 5 parity cases)
- [ ] 7.3 Manual smoke: `daemon start` on a machine with world-writable `/tmp` MUST reject without `--allow-unsafe-socket-dir`; pid file in `/tmp/safari-browser-default.pid` MUST be mode 0600; `daemon stop` during a long `js` call MUST exit within 5s with the client receiving `cancelled`
