import Foundation
import Darwin

/// Task 6.2 — full daemon serve lifecycle encapsulated so the CLI
/// subcommands (`daemon start / stop / status / logs`) can stay thin and
/// the core logic is testable in-process without forking.
///
/// `DaemonServeLoop.Server` wraps: pid-file management, `DaemonServer.Instance`
/// + `PreCompiledScripts.CompileCache`, the `daemon.shutdown` / `daemon.status`
/// built-in method handlers, and an idle-watchdog task that consumes
/// `DaemonServer.Instance.isIdle(now:)` and triggers `stop()` when the
/// configured timeout elapses.
///
/// The actor `Server` owns an atomic `startedAt` timestamp, a request counter,
/// and a `shutdownContinuation` so the outer `run()` caller can await a
/// single point that signals "daemon has drained and released its socket".
enum DaemonServeLoop {

    enum LoopError: Swift.Error, CustomStringConvertible {
        case pidWriteFailed(String)
        case alreadyRunning(pid: Int)

        var description: String {
            switch self {
            case .pidWriteFailed(let r): return "pid write failed: \(r)"
            case .alreadyRunning(let pid): return "daemon already running (pid \(pid))"
            }
        }
    }

    /// Process-level check consumed by `daemon start` to short-circuit the
    /// fork when a daemon is already running under the same NAME. Returns
    /// true iff ALL of:
    ///
    /// 1. The socket file exists.
    /// 2. The pid file contains a JSON `PidRecord` (legacy single-integer
    ///    format → stale, overwritten on next start).
    /// 3. `DaemonPaths.isProcessAlive` passes the 3-check probe (kill +
    ///    binary path + boot time within ±2s).
    ///
    /// A failure on any check means "stale" — the caller can clean up
    /// and spawn a new daemon. Per Requirement: Stale-pid file liveness
    /// detection (security-hardening Section 4): a recycled pid running
    /// an unrelated binary is correctly identified as stale, eliminating
    /// the prior false-positive that blocked `daemon start` against
    /// CI runners or unrelated tools that happened to land at the
    /// recorded pid.
    static func isDaemonAlive(socketPath: String, pidPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        switch DaemonPaths.readPidFile(at: pidPath) {
        case .ok(let record):
            return DaemonPaths.isProcessAlive(record: record, probe: .real)
        case .stale, .absent:
            return false
        }
    }

    /// In-process daemon serve loop. Own lifecycle via `start(...)` / `stop()`.
    /// The idle watchdog task automatically triggers `stop()` when
    /// `DaemonServer.Instance.isIdle(now:)` becomes true.
    actor Server {
        private let underlying = DaemonServer.Instance()
        private let cache = PreCompiledScripts.CompileCache()
        private var socketPath: String?
        private var pidPath: String?
        private var logPath: String?
        private var logFileHandle: FileHandle?
        private var startedAt: Date?
        private var requestCount: Int = 0
        private var watchdogTask: Task<Void, Never>?
        private var isRunning = false

        init() {}

        /// Idempotent start. If already running, returns without error.
        /// Writes `pidPath`, binds `socketPath`, registers built-in methods,
        /// kicks off the idle watchdog. Optionally opens the redacted log
        /// at `logPath`; if `logPath` is nil, no log is written. The
        /// `env` dict is consulted for `SAFARI_BROWSER_DAEMON_LOG_FULL=1`
        /// so callers can drive the redaction toggle from CI / shell.
        func start(
            socketPath: String,
            pidPath: String,
            idleTimeout: TimeInterval,
            logPath: String? = nil,
            env: [String: String] = ProcessInfo.processInfo.environment,
            stderrWriter: @escaping @Sendable (String) -> Void = { msg in
                FileHandle.standardError.write(Data(msg.utf8))
            }
        ) async throws {
            if isRunning { return }

            // Write pid file before binding socket so a racing observer never
            // sees a socket without a corresponding pid. The format is now
            // a JSON `PidRecord` carrying `(pid, binary path, boot time)`
            // so the 3-check liveness probe in `isDaemonAlive` can rule
            // out recycled-pid false positives (security-hardening Section
            // 4). `open(2)` with `O_CREAT|O_WRONLY|O_EXCL` + mode 0o600
            // still applies. `unlink` first so a stale pid file from a
            // crashed prior run doesn't fail O_EXCL — `isDaemonAlive`
            // already gated this path so any pre-existing file is
            // known-stale.
            unlink(pidPath)
            guard let record = DaemonPaths.currentPidRecord() else {
                throw LoopError.pidWriteFailed("could not capture self pid record")
            }
            do {
                try DaemonPaths.writePidFile(record: record, at: pidPath)
            } catch {
                throw LoopError.pidWriteFailed("\(error)")
            }

            self.socketPath = socketPath
            self.pidPath = pidPath
            self.startedAt = Date()

            // Section 3: open the redacted log file (append-mode) and
            // install the writer on the underlying instance. When
            // `SAFARI_BROWSER_DAEMON_LOG_FULL=1`, emit a single stderr
            // warning so the operator knows raw payloads are landing in
            // the log. The warning is inert when the env var is unset.
            let logFull = DaemonLog.isFullLoggingEnabled(env: env)
            DaemonLog.emitFullLogWarningIfNeeded(env: env, writer: stderrWriter)
            if let logPath = logPath {
                self.logPath = logPath
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                    try? handle.seekToEnd()
                    self.logFileHandle = handle
                    let writer: @Sendable (String) -> Void = { entry in
                        try? handle.write(contentsOf: Data(entry.utf8))
                    }
                    await underlying.setLogWriter(writer, logFull: logFull)
                }
            }

            // Built-in methods — Phase 1 production handlers (task 7.1)
            // plus the built-in lifecycle methods registered below.
            await DaemonDispatch.registerPhase1Handlers(on: underlying, cache: cache)
            let myself = self
            await underlying.register("daemon.shutdown") { [myself] _ in
                // Schedule actual teardown after we return the response so
                // the client sees a clean `{"result":{}}` before the socket
                // dies.
                Task.detached { await myself.stop() }
                return Data("{}".utf8)
            }
            await underlying.register("daemon.status") { [myself] _ in
                try await myself.statusPayload()
            }

            await underlying.configureIdleTimeout(idleTimeout)
            try await underlying.start(socketPath: socketPath)

            isRunning = true
            let watchRef = self
            self.watchdogTask = Task.detached(priority: .utility) {
                await Self.watchdogLoop(server: watchRef)
            }
        }

        /// Idempotent stop. Cancels watchdog, stops the underlying server,
        /// removes pid + socket files, and signals any `waitUntilStopped`
        /// awaiter so the hosting `__serve` process can exit cleanly.
        func stop() async {
            guard isRunning else { return }
            isRunning = false
            watchdogTask?.cancel()
            watchdogTask = nil
            await underlying.stop()
            if let p = pidPath { unlink(p) }
            if let s = socketPath { unlink(s) }
            try? logFileHandle?.close()
            logFileHandle = nil
            logPath = nil
            pidPath = nil
            socketPath = nil
            if let cont = stopContinuation {
                stopContinuation = nil
                cont.resume()
            }
        }

        /// Block until `stop()` is called (or is already called). Used by
        /// the hosting `daemon __serve` process to stay alive until either
        /// the idle watchdog or an explicit `daemon.shutdown` method fires.
        func waitUntilStopped() async {
            if !isRunning { return }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                stopContinuation = cont
            }
        }

        private var stopContinuation: CheckedContinuation<Void, Never>?

        /// Status snapshot, serialized as JSON bytes for the `daemon.status`
        /// method handler. Includes exactly the fields the spec mandates
        /// (pid, uptime, request count, pre-compiled count, last activity).
        func statusPayload() async throws -> Data {
            let uptime = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            let preCount = await cache.cacheCount
            let servedCount = await underlying.currentRequestCount
            let lastActivityEpoch = await underlying.currentLastActivityEpoch
            let status: [String: Any] = [
                "pid": Int(getpid()),
                "uptimeSeconds": uptime,
                "requestCount": servedCount,
                "preCompiledCount": preCount,
                "lastActivityEpoch": lastActivityEpoch,
            ]
            return try JSONSerialization.data(withJSONObject: status, options: [])
        }

        fileprivate func bumpRequestCount() {
            requestCount += 1
        }

        fileprivate func isActive() -> Bool { isRunning }

        // MARK: - Watchdog

        private static func watchdogLoop(server: Server) async {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                let active = await server.isActive()
                if !active { return }
                let idle = await server.shouldIdleShutdown()
                if idle {
                    await server.stop()
                    return
                }
            }
        }

        fileprivate func shouldIdleShutdown() async -> Bool {
            await underlying.isIdle(now: Date())
        }
    }
}
