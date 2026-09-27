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
/// The actor `Server` scopes startup, resource cleanup and stop waiters to a
/// single Run. Existing connection read cancellation is a separate concern.
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

    enum StopReason: Sendable, Equatable {
        case requested
        case idleTimeout
        case startupFailed
        case listenerFailed(DaemonServer.ListenerFailure)

        /// The process host uses the same typed completion as in-process
        /// callers; only a permanently failed listener changes its exit status.
        func throwIfListenerFailed() throws {
            if case .listenerFailed(let failure) = self { throw failure }
        }
    }

    enum LifecycleEvent: Sendable {
        case joinedStartup, waitingForTeardown, joinedStop, registeredStopWaiter, handledListenerFailure
        case beganStop(StopReason)
    }

    /// Scheduling seams for lifecycle interleavings. Production defaults do
    /// not delay startup/teardown and poll idle state every ten seconds.
    struct LifecycleEnvironment: Sendable {
        var beforeListenerStart: @Sendable () async throws -> Void = {}
        var afterListenerStart: @Sendable () async throws -> Void = {}
        var beforeTeardown: @Sendable () async -> Void = {}
        var observe: @Sendable (LifecycleEvent) -> Void = { _ in }
        var now: @Sendable () -> Date = { Date() }
        var watchdogSleep: @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(10))
        }
        var didInstallShutdownHook: @Sendable (@escaping @Sendable () async -> Void) -> Void = { _ in }
    }

    /// All mutable Run state stays on this actor. Startup and teardown tasks
    /// retain only the run ID across calls; a newer run cannot bind until the
    /// previous teardown has released its resources and completed its waiters.
    actor Server {
        private let underlying: DaemonServer.Instance
        private let cache = PreCompiledScripts.CompileCache()

        private final class Run {
            enum Phase { case starting, running, stopping, stopped }
            let id = UUID()
            let socketPath: String
            let pidPath: String
            let startedAt = Date()
            let lifecycle: LifecycleEnvironment
            var phase: Phase = .starting
            var pidIdentity: DaemonPaths.EntryIdentity?
            var logHandle: FileHandle?
            var startupTask: Task<Void, Error>?
            var teardownTask: Task<Void, Never>?
            var watchdogTask: Task<Void, Never>?
            var reason: StopReason?
            var waiters: [CheckedContinuation<StopReason, Never>] = []

            init(socketPath: String, pidPath: String, lifecycle: LifecycleEnvironment) {
                self.socketPath = socketPath
                self.pidPath = pidPath
                self.lifecycle = lifecycle
            }
        }

        private var current: Run?
        private var lastReason: StopReason = .requested
        private var startedAt: Date?

        init(shutdownWatchdog: (@Sendable () -> Void)? = nil) {
            underlying = DaemonServer.Instance(shutdownWatchdog: shutdownWatchdog)
        }

        /// Concurrent starts join the same operation. A start during teardown
        /// waits before creating a new run. Cancelling a starting caller asks
        /// that same run to stop, including when other callers joined it.
        func start(
            socketPath: String,
            pidPath: String,
            idleTimeout: TimeInterval,
            logPath: String? = nil,
            env: [String: String] = ProcessInfo.processInfo.environment,
            stderrWriter: @escaping @Sendable (String) -> Void = { msg in
                FileHandle.standardError.write(Data(msg.utf8))
            },
            acceptEnvironment: DaemonServer.AcceptEnvironment = .init(),
            lifecycle: LifecycleEnvironment = .init()
        ) async throws {
            try Task.checkCancellation()
            while let old = current, old.phase == .stopping {
                old.lifecycle.observe(.waitingForTeardown)
                await old.teardownTask?.value
                try Task.checkCancellation()
            }
            if let run = current {
                if run.phase == .running { return }
                run.lifecycle.observe(.joinedStartup)
                try await awaitStartup(runID: run.id)
                return
            }
            let run = Run(socketPath: socketPath, pidPath: pidPath, lifecycle: lifecycle)
            current = run
            startedAt = run.startedAt
            let id = run.id
            run.startupTask = Task {
                try await self.startRun(id: id, idleTimeout: idleTimeout, logPath: logPath,
                                        env: env, stderrWriter: stderrWriter, acceptEnvironment: acceptEnvironment)
            }
            try await awaitStartup(runID: id)
        }

        private func awaitStartup(runID: UUID) async throws {
            guard let run = current, run.id == runID, let task = run.startupTask else {
                throw CancellationError()
            }
            do {
                try await withTaskCancellationHandler {
                    try await task.value
                    try Task.checkCancellation()
                } onCancel: {
                    Task { await self.stop(runID: runID, reason: .requested) }
                }
                guard current === run, run.phase == .running else {
                    throw CancellationError()
                }
            } catch {
                let reason: StopReason = error is CancellationError ? .requested : .startupFailed
                await stop(runID: runID, reason: reason)
                try run.reason?.throwIfListenerFailed()
                throw error
            }
        }

        private func requireStarting(_ id: UUID) throws {
            try Task.checkCancellation()
            guard let run = current, run.id == id, run.phase == .starting else {
                throw CancellationError()
            }
        }

        /// This task never waits for teardown: teardown waits for this task
        /// before stopping the shared underlying instance, preventing late bind.
        private func startRun(
            id: UUID, idleTimeout: TimeInterval, logPath: String?, env: [String: String],
            stderrWriter: @escaping @Sendable (String) -> Void,
            acceptEnvironment: DaemonServer.AcceptEnvironment
        ) async throws {
            try requireStarting(id)
            guard let run = current else { throw CancellationError() }
            // The process-level liveness gate still decides whether an old
            // entry is stale. The identity below scopes this run's later cleanup.
            unlink(run.pidPath)
            guard let record = DaemonPaths.currentPidRecord() else {
                throw LoopError.pidWriteFailed("could not capture self pid record")
            }
            do {
                run.pidIdentity = try DaemonPaths.writePidFile(record: record, at: run.pidPath)
            } catch {
                throw LoopError.pidWriteFailed("\(error)")
            }

            let logFull = DaemonLog.isFullLoggingEnabled(env: env)
            DaemonLog.emitFullLogWarningIfNeeded(env: env, writer: stderrWriter)
            if let logPath {
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                    _ = try? handle.seekToEnd()
                    run.logHandle = handle
                    await underlying.setLogWriter({ entry in
                        try? handle.write(contentsOf: Data(entry.utf8))
                    }, logFull: logFull)
                    try requireStarting(id)
                }
            }
            await DaemonDispatch.registerPhase1Handlers(on: underlying, cache: cache)
            try requireStarting(id)
            let hook: @Sendable () async -> Void = { await self.stop(runID: id, reason: .requested) }
            await underlying.setShutdownHook(hook)
            try requireStarting(id)
            run.lifecycle.didInstallShutdownHook(hook)
            await underlying.configureIdleTimeout(idleTimeout)
            try requireStarting(id)
            await underlying.recordStartTimestamp()
            try requireStarting(id)
            try await run.lifecycle.beforeListenerStart()
            try requireStarting(id)
            let observe = run.lifecycle.observe
            try await underlying.start(socketPath: run.socketPath, environment: acceptEnvironment) { failure in
                await self.stop(runID: id, reason: .listenerFailed(failure))
                observe(.handledListenerFailure)
            }
            try requireStarting(id)
            try await run.lifecycle.afterListenerStart()
            try requireStarting(id)
            run.phase = .running
            let sleep = run.lifecycle.watchdogSleep
            run.watchdogTask = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    do { try await sleep() } catch { return }
                    guard !Task.isCancelled else { return }
                    if await self.checkIdleAndStop(runID: id) { return }
                }
            }
        }

        /// First accepted reason wins. Every stop caller joins one teardown;
        /// no caller waits for the accept loop or a diagnostic writer.
        func stop() async {
            guard let id = current?.id else { return }
            await stop(runID: id, reason: .requested)
        }

        private func stop(runID: UUID, reason: StopReason) async {
            guard let run = current, run.id == runID else { return }
            if run.phase != .stopping {
                run.phase = .stopping
                run.reason = reason
                run.startupTask?.cancel()
                run.watchdogTask?.cancel()
                run.teardownTask = Task { await self.teardown(runID: runID) }
                run.lifecycle.observe(.beganStop(reason))
            } else {
                run.lifecycle.observe(.joinedStop)
            }
            await run.teardownTask?.value
        }

        private func teardown(runID: UUID) async {
            guard let run = current, run.id == runID else { return }
            _ = await run.startupTask?.result
            await run.lifecycle.beforeTeardown()
            // current cannot change while this run is stopping: starts await
            // this task. Only the inner instance owns socket removal.
            await underlying.stop()
            await underlying.setLogWriter(nil)
            run.pidIdentity?.removeIfMatches(at: run.pidPath)
            run.pidIdentity = nil
            try? run.logHandle?.close()
            run.logHandle = nil
            run.watchdogTask = nil
            run.startupTask = nil
            run.phase = .stopped
            let reason = run.reason ?? .requested
            lastReason = reason
            current = nil
            let waiters = run.waiters
            run.waiters.removeAll()
            waiters.forEach { $0.resume(returning: reason) }
        }

        /// Each waiter belongs to the run observed on entry and resumes only
        /// after its cleanup, even if another run starts before it is scheduled.
        @discardableResult
        func waitUntilStopped() async -> StopReason {
            guard let run = current else { return lastReason }
            return await withCheckedContinuation {
                run.waiters.append($0)
                run.lifecycle.observe(.registeredStopWaiter)
            }
        }

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

        private func checkIdleAndStop(runID: UUID) async -> Bool {
            guard let run = current, run.id == runID, run.phase == .running else { return true }
            let idle = await underlying.isIdle(now: run.lifecycle.now())
            guard current === run, run.phase == .running, !Task.isCancelled else { return true }
            if idle { await stop(runID: runID, reason: .idleTimeout) }
            return idle
        }
    }
}
