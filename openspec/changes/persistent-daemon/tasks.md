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

- [ ] 5.1 Implement `Daemon 為 opt-in，不改變 CLI 預設行為` in `SafariBridge.swift` — three-signal detection (`--daemon` flag / `SAFARI_BROWSER_DAEMON=1` env / live socket present), default still routes stateless, satisfying the `Daemon mode is opt-in` requirement
- [ ] 5.2 Implement 失敗時 silently fallback 到 stateless — handle the five defined failure modes (socket missing / connection refused / version mismatch / non-domain error / 15s timeout) with a single `[daemon fallback: <reason>]` stderr warning, satisfying `Silent fallback to stateless path on daemon failure`

## 6. Lifecycle

- [x] 6.1 Implement Idle auto-shutdown 預設 10 分鐘 — default 600s, read `SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT` env and clamp to `[60, 3600]`, reset timer on request arrival, exit cleanly (remove socket + pid) on timeout; satisfies `Idle auto-shutdown` requirement — `resolveIdleTimeout(env:)` static parser + `configureIdleTimeout` / `recordActivity` / `isIdle(now:)` actor-isolated API; dispatch path calls `recordActivity()` on every request; watchdog task that consumes `isIdle(now:)` to trigger shutdown lives with task 6.2 lifecycle wiring
- [ ] 6.2 Implement Daemon subcommand group：`safari-browser daemon {start, stop, status, logs}` — `start` fork-detached and wait for socket, `stop` sends shutdown request and waits for exit, `status` prints pid/uptime/request-count/precompiled-count/last-activity, `logs` tails log file; all idempotent; pid + socket cleanup on abnormal exit
- [ ] 6.3 Implement 版本相容：Daemon 和 CLI 必須同一 build，不同版 daemon startup 檢查拒絕啟動 — daemon sends build identifier (git commit + semver) on connection accept; client verifies match; mismatch closes connection and triggers fallback per the `Version handshake refuses mismatched client` requirement

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
