## Why

Phase 1 of `persistent-daemon` landed on 2026-04-25 (archive: `2026-04-25-persistent-daemon`) with 6 security requirements written into the spec but deliberately **not** implemented — the original change had already exceeded its scope (16 tasks completed, 6 deferred as "Batch 1 spec gaps from #32 verify"). Leaving them unimplemented turns the `persistent-daemon` capability into a security liability: the socket is world-writable by default, AppleScript source hits the log file, dirty builds can silently reuse stale pre-compiled script caches, and the main-request actor cannot be cancelled mid-AppleScript during shutdown. This change closes all 6 gaps before the daemon sees wider use.

## What Changes

Implement the 6 requirements already present in the main `persistent-daemon` spec:

- **Socket and pid file permissions** — `umask(0077)` before bind or `fchmod(fd, 0600)`, reject `$TMPDIR` unset without `--socket-dir`, reject world-writable parent dir without `--allow-unsafe-socket-dir`, write pid file via `open(2)` with mode `0600`
- **IPC trust model — filesystem permissions only** — reject `--listen-tcp`, `--socket-path @...` (Linux abstract namespace), or any network-accessible transport at CLI parse time
- **Daemon log redaction** — redact `applescript.execute.source` / `Safari.js.code` params to `<redacted N bytes>`, truncate read-method results to 256 bytes with `…(truncated)`, honor `SAFARI_BROWSER_DAEMON_LOG_FULL=1` opt-out with startup warning
- **Stale-pid file liveness detection** — extend pid file to `(pid, executable_path, boot_timestamp)` triple, 3-check liveness via `kill -0` + `proc_pidpath` + `proc_pidinfo` start-time (tolerate ±2s drift)
- **Version handshake treats dirty builds as always-mismatched** — extend `DaemonProtocol.currentVersion` to include `dirty` boolean + `vendor:<tag>` (tarball / homebrew / source); mismatch on any dirty side or differing vendor tag
- **Lifecycle commands bypass the main-request actor** — route `daemon.status` + `daemon.shutdown` through a second dispatch path or socket-accept-layer method inspection; on `daemon.shutdown`, `SIGTERM` any in-flight AppleScript subprocess and surface `{error:{code:"cancelled"}}`; full shutdown within 5s

Each gets accompanying unit tests (`DaemonSocketPermissionsTests`, `DaemonLogRedactionTests`, `StalePidLivenessTests`, `DaemonHandshakeEdgeCaseTests`, `DaemonLifecycleCancellationTests`, plus parse-time rejection test for trust model).

## Non-Goals

- **No new user-facing CLI surface** beyond the `--socket-dir` and `--allow-unsafe-socket-dir` escape hatches already mentioned in the spec. Everything else is internal hardening.
- **No Phase 2 daemon features** (process warming beyond pre-compilation, state caching, multi-Safari support, etc.) — those stay out of scope.
- **No retroactive spec changes** — all 6 requirements are already in the spec verbatim. This change only implements them.

## Capabilities

### New Capabilities

_(none)_

### Modified Capabilities

_(none — this change is pure implementation with no spec-level additions or modifications; all 6 requirements being implemented are already authoritative in the main spec as of the 2026-04-25 archive)_

## Impact

**Affected code:**
- `Sources/SafariBrowser/Daemon/DaemonServer.swift` — socket bind flow, log formatter, lifecycle-command routing
- `Sources/SafariBrowser/Daemon/DaemonServeLoop.swift` — pid file format, liveness check, `daemon.shutdown` cancellation
- `Sources/SafariBrowser/Daemon/DaemonClient.swift` — transport parse-time rejection (CLI parse only, not runtime)
- `Sources/SafariBrowser/Daemon/DaemonProtocol.swift` — handshake schema extension (`dirty`, `vendor`)

**Affected tests (all new):**
- `Tests/SafariBrowserTests/DaemonSocketPermissionsTests.swift`
- `Tests/SafariBrowserTests/DaemonTrustModelTests.swift`
- `Tests/SafariBrowserTests/DaemonLogRedactionTests.swift`
- `Tests/SafariBrowserTests/StalePidLivenessTests.swift`
- `Tests/SafariBrowserTests/DaemonHandshakeEdgeCaseTests.swift`
- `Tests/SafariBrowserTests/DaemonLifecycleCancellationTests.swift`

**Dependencies:** none new. Uses existing Darwin APIs (`umask`, `fchmod`, `open(2)`, `proc_pidpath`, `proc_pidinfo`, `SIGTERM`). Build identifier source (git dirty flag, vendor tag) plumbed from build script; no runtime config.

**Breaking:** None for end users. One subtle operational change: pid file format extends from `"pid\n"` to a triple. Old pid files from pre-hardening daemons are treated as stale on upgrade (safe — the liveness check will fail-open by treating them as not-alive and letting `daemon start` replace them).

**Cross-reference:** archive `openspec/changes/archive/2026-04-25-persistent-daemon/` — the 6 tasks `11.1`–`11.6` in its `tasks.md` map 1:1 to this proposal.
