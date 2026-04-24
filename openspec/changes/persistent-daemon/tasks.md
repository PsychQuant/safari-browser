## 1. Scaffold

- [x] 1.1 Add `Sources/SafariBrowser/Daemon/` directory with `DaemonServer.swift`, `DaemonClient.swift`, `PreCompiledScripts.swift` stub files, and register the `Daemon subcommand group for lifecycle management` placeholder in `SafariBrowser.swift` with no-op handlers so the rest of the tasks can fill them in

## 2. IPC layer

- [x] 2.1 Implement IPC：Unix domain socket + JSON lines + per-NAME namespace in `DaemonServer.swift` — socket binds to `${TMPDIR:-/tmp}/safari-browser-<NAME>.sock`, JSON-lines reader/writer, request/response framing satisfying the `IPC via Unix domain socket with JSON-lines protocol` requirement
- [x] 2.2 [P] Implement `DaemonClient.swift` connect + NAME resolution satisfying `Namespace isolation via NAME` — precedence `--name` > `SAFARI_BROWSER_NAME` > `"default"`

## 3. NSAppleScript handle pre-compilation

- [x] 3.1 Implement 主 win 來自 NSAppleScript handle pre-compilation，不是 process warm-ness：rewrite 7-10 frequently-used AppleScript source blocks from `SafariBridge.swift` into `NSAppleScript` objects held in `PreCompiledScripts.swift`, satisfying `Daemon uses pre-compiled NSAppleScript handles, not process warmth, for latency reduction` — scaffold + 3 seed templates (activateWindow, enumerateWindows, runJSInCurrentTab); remaining 4-7 templates land in task 7.1 routing

## 4. Request dispatch (Path A)

- [x] 4.1 Wire daemon request dispatch via a Swift actor that serializes all Safari AppleScript invocations; satisfy `No Safari state cache（Path A，不快取 window / tab / URL 映射）` — re-query Safari per request, no window/tab/URL/index caching ever, satisfying the `No Safari state cache` requirement — `DaemonDispatch.registerDemoHandlers` wires CompileCache into DaemonServer; Safari-free `cache.arithmetic` proves the end-to-end wiring; Safari-bound handlers defer to task 7.1

## 5. Opt-in detection and fallback

- [x] 5.1 Implement `Daemon 為 opt-in，不改變 CLI 預設行為` in `SafariBridge.swift` — three-signal detection (`--daemon` flag / `SAFARI_BROWSER_DAEMON=1` env / live socket present), default still routes stateless, satisfying the `Daemon mode is opt-in` requirement — exposed as `SafariBridge.shouldUseDaemon(flag:env:socketExists:)` in new `DaemonRouter.swift`; wired into commands by task 7.1
- [x] 5.2 Implement 失敗時 silently fallback 到 stateless — handle the five defined failure modes (socket missing / connection refused / version mismatch / non-domain error / 15s timeout) with a single `[daemon fallback: <reason>]` stderr warning, satisfying `Silent fallback to stateless path on daemon failure` — `SafariBridge.runViaRouter` + `DaemonClient.Error.fallbackReason` classification; domain error allowlist in `DaemonClient.Error.domainErrorCodes`; `SO_RCVTIMEO`/`SO_SNDTIMEO` on client socket yields `ioError("timeout")` at the 15s default; handshake mismatch (case c) still routes through the same fallbackReason classifier once task 6.3 emits the code string

## 6. Lifecycle

- [x] 6.1 Implement Idle auto-shutdown 預設 10 分鐘 — default 600s, read `SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT` env and clamp to `[60, 3600]`, reset timer on request arrival, exit cleanly (remove socket + pid) on timeout; satisfies `Idle auto-shutdown` requirement — `resolveIdleTimeout(env:)` static parser + `configureIdleTimeout` / `recordActivity` / `isIdle(now:)` actor-isolated API; dispatch path calls `recordActivity()` on every request; watchdog task that consumes `isIdle(now:)` to trigger shutdown lives with task 6.2 lifecycle wiring
- [x] 6.2 Implement Daemon subcommand group：`safari-browser daemon {start, stop, status, logs}` — `start` fork-detached and wait for socket, `stop` sends shutdown request and waits for exit, `status` prints pid/uptime/request-count/precompiled-count/last-activity, `logs` tails log file; all idempotent; pid + socket cleanup on abnormal exit — `DaemonServeLoop.Server` actor encapsulates in-process testable lifecycle; `daemon __serve` hidden subcommand hosts the real process; `_NSGetExecutablePath` for correct child binary resolution; `setsid()` + `SIGHUP SIG_IGN` detach from terminal; `DaemonClient.{pidPath,logPath}` path helpers
- [x] 6.3 Implement 版本相容：Daemon 和 CLI 必須同一 build，不同版 daemon startup 檢查拒絕啟動 — daemon sends build identifier (git commit + semver) on connection accept; client verifies match; mismatch closes connection and triggers fallback per the `Version handshake refuses mismatched client` requirement — new `DaemonProtocol` module with `currentVersion`, `encodeHandshake`, `decodeHandshakeVersion`; server emits handshake as first line on accept; client reads and validates before sending first request; mismatch → `remoteError("versionMismatch")` which `fallbackReason` classifies as fallback-worthy; test-socket helpers consume handshake transparently so existing raw-socket tests keep passing

## 7. Phase 1 coverage and parity

- [ ] 7.1 Route 第一版 command coverage 限制 through the daemon — `snapshot`, `click`, `fill`, `type`, `press`, `js`, `documents`, `get url`, `get title`, `wait`, `storage`; commands outside this list MUST still work by falling through to the stateless path, satisfying `Phase 1 command coverage`
- [ ] 7.2 Verify `Daemon mode behavioural parity with stateless mode` and `Daemon mode does not lower the default non-interference guarantees` — Layer 1 noop preserved when targeting front tab of front window, `ambiguousWindowMatch` shape identical, spatial gradient layer selection identical, cross-Space handling identical

## 8. Non-Interference integration

- [ ] 8.1 Satisfy `Daemon process is passively interfering and user-terminable` — no focus stealing on `daemon start` (Terminal retains focus, no window raises), `daemon stop` exits daemon within 5 seconds with socket + pid cleanup, idle timeout restores non-interference default state automatically

## 9. Docs and cross-repo coordination

- [ ] 9.1 [P] Update `CLAUDE.md` with a daemon section (how to enable / disable / principle interactions) and `README.md` Quickstart mention; in both, call out 與 `save-image-subcommand` 的順序 (that change lands first) and enumerate the commands NOT covered in Phase 1 (screenshot, pdf, upload --native, upload --allow-hid)

## 10. Tests

- [ ] 10.1 Unit tests covering IPC serialize/deserialize, NAME resolution precedence, idle timer clamp at min/max/default, handshake mismatch path, and actor serialization of concurrent requests
- [ ] 10.2 Integration test asserting daemon mode and stateless mode produce identical stdout + exit code for `documents`, `get url`, and a `--url` query that matches multiple windows (simulated `ambiguousWindowMatch`); run both modes in same test suite

## 11. Security hardening (#37 Batch 1 — spec gaps from #32 verify)

- [ ] 11.1 Satisfy Requirement: `Socket and pid file permissions` — implement `umask(0077)` before bind OR `fchmod(fd, 0600)` after bind in `DaemonServer.swift`; reject `$TMPDIR` unset without `--socket-dir` override; stat containing directory for world-writable bit and reject unless `--allow-unsafe-socket-dir`; write pid file via `open(2)` with mode `0600` (not `FileManager`). Add `DaemonSocketPermissionsTests`.
- [ ] 11.2 Satisfy Requirement: `IPC trust model — filesystem permissions only` — remove (or block at CLI parse) any path that would accept `--listen-tcp`, `--socket-path @...` (Linux abstract), or similar network-accessible transports; promote design.md Non-Goal into a parse-time rejection test.
- [ ] 11.3 Satisfy Requirement: `Daemon log redaction` — in `DaemonServer.Instance`'s logging code, redact `applescript.execute.source` / `Safari.js.code` params to `<redacted N bytes>`; truncate result fields for read-methods to 256 bytes with `…(truncated)`; honor `SAFARI_BROWSER_DAEMON_LOG_FULL=1` opt-out with startup stderr warning. Add `DaemonLogRedactionTests`.
- [ ] 11.4 Satisfy Requirement: `Stale-pid file liveness detection` — extend pid file format to include `(pid, executable_path, boot_timestamp)` triple; implement 3-check liveness (`kill -0` + `proc_pidpath` + `proc_pidinfo` start-time) in `DaemonServeLoop.isDaemonAlive`; tolerate ±2s drift on start-time. Add `StalePidLivenessTests` covering recycled-pid and binary-path-mismatch cases.
- [ ] 11.5 Satisfy Requirement: `Version handshake treats dirty builds as always-mismatched` — extend `DaemonProtocol.currentVersion` / `encodeHandshake` / `decodeHandshakeVersion` to include `dirty` flag (from git working-tree state detected at build) and `vendor:<tag>` (for tarball / homebrew / source builds without git). Handshake comparison returns mismatch on any dirty side or differing vendor tags. Add `DaemonHandshakeEdgeCaseTests`.
- [ ] 11.6 Satisfy Requirement: `Lifecycle commands bypass the main-request actor` — route `daemon.status` + `daemon.shutdown` through a second dispatch queue OR inspect `method` at socket-accept layer and run those methods outside the main request actor; on `daemon.shutdown`, `SIGTERM` any in-flight AppleScript subprocess and surface `{error:{code:"cancelled"}}` to the original client; ensure full shutdown within 5s. Add `DaemonLifecycleCancellationTests`.
