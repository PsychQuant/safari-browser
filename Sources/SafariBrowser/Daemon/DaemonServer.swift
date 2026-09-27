import Foundation
import Darwin

/// Long-running per-user daemon that serves `safari-browser` requests over a
/// Unix domain socket, holding pre-compiled `NSAppleScript` handles warm.
///
/// Task 2.1 implements the IPC core: Unix socket binding, JSON-lines framing,
/// method dispatch, and graceful shutdown. Handlers are registered by method
/// name and receive params as a `Data` blob (the JSON subtree under the
/// incoming request's `"params"` key) and return `Data` (the JSON subtree to
/// place under the response's `"result"` key).
///
/// Method handlers that speak to Safari arrive in later tasks (3.1 / 4.1 / 7.1).
enum DaemonServer {
    /// Only the process-owning __serve command installs this callback.
    /// Embedded instances must never terminate the process that hosts them.
    static func scheduleProcessExit() {
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .seconds(5))
            Darwin._exit(0)
        }
    }

    /// Stable identities for a cancellation candidate. No descriptor survives
    /// here across suspension; the owning connection is resolved again later.
    struct InFlightSlot: Sendable {
        let connectionID: UUID
        let requestID: UUID
        let requestIdJSON: Data
    }

    /// Error codes surfaced in JSON-lines responses.
    enum ErrorCode: String, Sendable {
        case parseError
        case methodNotFound
        case handlerError
        /// Section 6 of daemon-security-hardening: emitted to in-flight
        /// connections when `daemon.shutdown` cancels their request.
        /// Domain-classified by `DaemonClient.Error.fallbackReason`
        /// (returns nil) so clients propagate the cancellation rather
        /// than silently retry via the stateless path against a daemon
        /// that is in the process of dying.
        case cancelled
    }

    /// Complete request JSON line, excluding LF. Applies to every method.
    static let maxRequestLineBytes = 128 * 1024 * 1024

    struct RequestLineReader: Sendable {
        enum ReadError: Error, Equatable { case lineTooLong, readFailed(Int32) }
        let maxBytes: Int
        private(set) var pending = Data()
        private var scanned = 0

        init(maxBytes: Int = DaemonServer.maxRequestLineBytes) {
            precondition(maxBytes > 0 && maxBytes < Int.max)
            self.maxBytes = maxBytes
        }

        /// Both adapters use this framing core; only their I/O scheduling differs.
        private mutating func bufferedLine() throws -> Data? {
            let unscanned = pending.index(pending.startIndex, offsetBy: scanned)
            if let newline = pending[unscanned...].firstIndex(of: 10) {
                let length = pending.distance(from: pending.startIndex, to: newline)
                guard length <= maxBytes else { throw ReadError.lineTooLong }
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                scanned = 0
                return line
            }
            scanned = pending.count
            guard pending.count <= maxBytes else { throw ReadError.lineTooLong }
            return nil
        }

        private var readAllowance: Int { min(8192, maxBytes + 1 - pending.count) }

        private mutating func finishEOF() -> Data? {
            guard !pending.isEmpty else { return nil }
            let line = pending
            pending = Data()
            scanned = 0
            return line
        }

        mutating func readLine(
            connection: DaemonConnection,
            yieldAfterProgress: @Sendable () async -> Void = { await Task.yield() }
        ) async throws -> Data? {
            var chunks = 0
            while true {
                try Task.checkCancellation()
                guard !connection.isRevoked else { throw DaemonConnection.Failure.revoked }
                if let line = try bufferedLine() { return line }
                let next = try await connection.readChunk(maxBytes: readAllowance)
                try Task.checkCancellation()
                guard !connection.isRevoked else { throw DaemonConnection.Failure.revoked }
                guard let next else { return finishEOF() }
                pending.append(next)
                chunks += 1
                if chunks == 16 {
                    chunks = 0
                    await yieldAfterProgress()
                }
            }
        }

        /// Synchronous adapter retained for the existing framing/syscall tests.
        mutating func readLine(
            fd: Int32,
            readOperation: (Int32, UnsafeMutableRawPointer, Int) -> Int = { Darwin.read($0, $1, $2) }
        ) throws -> Data? {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                if let line = try bufferedLine() { return line }
                // Exactly maxBytes may still be followed by LF. Read at most
                // that one excess byte, never an unbounded unfinished frame.
                let allowance = readAllowance
                let count = buffer.withUnsafeMutableBytes { readOperation(fd, $0.baseAddress!, allowance) }
                if count > 0 {
                    pending.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    return finishEOF()
                } else {
                    let code = errno
                    if code == EINTR { continue }
                    throw ReadError.readFailed(code)
                }
            }
        }
    }

    /// A permanent listener failure contains no request or filesystem data.
    struct ListenerFailure: Error, Sendable, Equatable, CustomStringConvertible {
        enum Operation: String, Sendable { case accept, poll }
        let operation: Operation
        let errno: Int32
        var description: String { "listener \(operation.rawValue) failed: errno=\(errno)" }
    }

    // MARK: - Accept-loop recovery (#178)

    /// `accept(2)` as a value, so the loop can be driven by a scripted errno
    /// sequence in tests. Returns the client fd, or -1 with the errno.
    typealias AcceptFunction = @Sendable (Int32) -> (fd: Int32, errno: Int32)

    static let systemAccept: AcceptFunction = { listenerFd in
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let fd = withUnsafeMutablePointer(to: &clientAddr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.accept(listenerFd, sa, &clientLen)
            }
        }
        return (fd, fd < 0 ? errno : 0)
    }

    /// What the loop's readiness wait saw.
    enum AcceptWait: Equatable, Sendable {
        /// The listener is readable: a pending connection, or an error that
        /// `accept()` will report.
        case ready
        /// `stop()` closed the wake pipe's write end.
        case wake
        /// `poll()` itself failed with this errno.
        case failed(Int32)
        /// Nothing happened within one wait slice.
        case idle
    }

    /// The longest single `poll()`. The wake pipe normally ends a wait at
    /// once; the slice is the fallback that lets a cancelled loop notice even
    /// if the pipe never wakes it (a write end inherited by a child keeps it
    /// open after `stop()` closes ours).
    static let acceptWaitSliceMilliseconds: Int32 = 1000

    /// Blocks until the listener or the wake pipe is readable.
    typealias WaitFunction = @Sendable (_ listenerFd: Int32, _ wakeFd: Int32) -> AcceptWait

    static let systemWait: WaitFunction = { listenerFd, wakeFd in
        var fds = [pollfd(fd: listenerFd, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wakeFd, events: Int16(POLLIN), revents: 0)]
        let ready = poll(&fds, 2, DaemonServer.acceptWaitSliceMilliseconds)
        guard ready >= 0 else { return .failed(errno) }
        if ready == 0 { return .idle }
        // A stop request wins over queued connections.
        return fds[1].revents != 0 ? .wake : .ready
    }

    /// Everything the accept loop touches besides its own state, injectable
    /// so tests can script errnos, record backoff delays, and move the clock.
    struct AcceptEnvironment: Sendable {
        var accept: AcceptFunction = DaemonServer.systemAccept
        var wait: WaitFunction = DaemonServer.systemWait
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
        /// Runs after this generation has released all listener resources.
        var beforeFailureNotification: @Sendable () async -> Void = {}
    }

    /// Makes an accepted descriptor safe to serve: no SIGPIPE (#175), and
    /// blocking I/O — BSD `accept()` copies the listener's O_NONBLOCK onto
    /// the new socket. Returns 0, or the errno of the step that failed.
    static func prepareAcceptedClient(_ fd: Int32) -> Int32 {
        var enable: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return errno
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return errno }
        return 0
    }

    /// What the accept loop does after `accept()` fails.
    enum AcceptDisposition: String, Equatable, Sendable {
        /// The call was interrupted or one pending connection aborted; the
        /// listener itself is fine.
        case retry
        /// A process or kernel resource is exhausted for now; wait, then retry.
        case backoff
        /// The listener is gone or invalid, so retrying can never succeed.
        case stop
        var diagnosticDisposition: DaemonDiagnosticBudget.Disposition {
            switch self {
            case .retry: return .retry
            case .backoff: return .backoff
            case .stop: return .stop
            }
        }
    }

    /// Only an errno that proves the listener unusable ends the loop. Anything
    /// unlisted backs off (bounded, cancellable): stopping on an errno that
    /// does not prove it recreated #178's alive-but-deaf daemon (verify R2).
    static func acceptDisposition(errno code: Int32) -> AcceptDisposition {
        switch code {
        case EINTR, ECONNABORTED, EAGAIN, EPROTO:
            return .retry
        case EBADF, ENOTSOCK, EINVAL, EOPNOTSUPP, EFAULT:
            return .stop
        default:
            return .backoff
        }
    }

    /// 10 ms doubling to a 1 s cap. Clamped before shifting, so any attempt
    /// count is safe.
    static func acceptBackoff(attempt: Int) -> Duration {
        let exponent = min(max(attempt, 0), 7)
        return min(.milliseconds(10 * (1 << exponent)), .seconds(1))
    }

    /// Consecutive immediate retries before the loop starts backing off, so a
    /// storm of retry-class errors cannot spin a core.
    static let maxImmediateAcceptRetries = 16

    /// First occurrence of a streak, then every 64th — a persistent error is
    /// visible without flooding the log.
    static func shouldLogAcceptEvent(occurrence: Int) -> Bool {
        occurrence == 1 || (occurrence > 0 && occurrence % 64 == 0)
    }

    /// Bookkeeping for one accept-failure incident: a run of failures with no
    /// successful accept between them and no quiet gap of `quietGap`. Every
    /// errno counts toward the same streak — keying it on the exact errno let
    /// an alternating pair log every failure (verify R1).
    struct AcceptIncident {
        /// A failure after this much quiet starts a new incident, so one early
        /// storm cannot push every later isolated error into backoff unlogged.
        static let quietGap: Duration = .seconds(5)

        struct Step: Equatable {
            let disposition: AcceptDisposition
            let log: Bool
            /// Set when `disposition == .backoff`.
            let delay: Duration?
        }

        private(set) var streak = 0
        private(set) var lastErrno: Int32 = 0
        private var immediateRetries = 0
        private var backoffAttempt = 0
        private var lastFailure: ContinuousClock.Instant?

        mutating func recordFailure(errno code: Int32, at now: ContinuousClock.Instant) -> Step {
            if let last = lastFailure, last.duration(to: now) >= Self.quietGap {
                self = AcceptIncident()
            }
            lastFailure = now
            streak += 1
            lastErrno = code
            var disposition = DaemonServer.acceptDisposition(errno: code)
            if disposition == .retry {
                immediateRetries += 1
                if immediateRetries > DaemonServer.maxImmediateAcceptRetries { disposition = .backoff }
            }
            var delay: Duration?
            if disposition == .backoff {
                delay = DaemonServer.acceptBackoff(attempt: backoffAttempt)
                backoffAttempt += 1
            }
            let log = disposition == .stop || DaemonServer.shouldLogAcceptEvent(occurrence: streak)
            return Step(disposition: disposition, log: log, delay: delay)
        }

        /// Ends the incident; returns its length and last errno if there was one.
        mutating func recordSuccess() -> (streak: Int, errno: Int32)? {
            defer { self = AcceptIncident() }
            return streak > 0 ? (streak, lastErrno) : nil
        }
    }

    /// Connection-setup failures (#175's SO_NOSIGPIPE branch), counted like
    /// accept failures: consecutive, and a quiet gap starts a new streak.
    struct SetupFailureStreak {
        private(set) var count = 0
        private var lastFailure: ContinuousClock.Instant?

        mutating func recordFailure(at now: ContinuousClock.Instant) -> (count: Int, log: Bool) {
            if let last = lastFailure, last.duration(to: now) >= AcceptIncident.quietGap { count = 0 }
            lastFailure = now
            count += 1
            return (count, DaemonServer.shouldLogAcceptEvent(occurrence: count))
        }

        /// Ends the streak; returns its length if there was one.
        mutating func recordSuccess() -> Int? {
            defer { self = SetupFailureStreak() }
            return count > 0 ? count : nil
        }
    }

    /// Internal observations for deterministic connection lifecycle fixtures.
    struct ConnectionObservation: Sendable {
        var beforeRead: @Sendable () -> Void = {}
        var beforeDispatch: @Sendable () async -> Void = {}
        var didFinish: @Sendable () -> Void = {}
    }

    /// Running daemon instance. Construct with `init()`, register handlers
    /// with `register(_:handler:)`, start with `start(socketPath:)`, and
    /// stop with `stop()`.
    actor Instance {
        typealias MethodHandler = @Sendable (Data) async throws -> Data

        private var handlers: [String: MethodHandler] = [:]
        /// Write end of the pipe that wakes the accept loop. The loop owns the
        /// listener and the read end (#178).
        private var wakeWriteFd: Int32 = -1
        private var acceptTask: Task<Void, Never>?
        private var listenerGeneration: UUID?
        private var shutdownGeneration = UUID()
        private var socketPath: String?
        private final class ConnectionRecord {
            let connection: DaemonConnection
            let shutdown: ShutdownContext
            var task: Task<Void, Never>?
            var request: RequestWork?
            init(connection: DaemonConnection, shutdown: ShutdownContext) {
                self.connection = connection
                self.shutdown = shutdown
            }
        }
        private var connections: [UUID: ConnectionRecord] = [:]
        // These tasks can outlive a revoked transport only while the admitted
        // handler or logger is genuinely unfinished. Completion removes them.
        private var operations: [UUID: Task<Void, Never>] = [:]

        /// Section 3 of `daemon-security-hardening` — optional log writer
        /// fed one redacted/truncated JSON-line per request. When `nil`
        /// (default) the daemon emits no log; production wiring sets this
        /// at start-up via `setLogWriter(_:)`. The `logFull` flag flips
        /// off redaction entirely for `SAFARI_BROWSER_DAEMON_LOG_FULL=1`
        /// local-debugging sessions.
        private var logWriter: (@Sendable (String) -> Void)?
        private var logFull: Bool = false

        /// Idle auto-shutdown state (task 6.1). `idleTimeoutSeconds` is the
        /// clamped value from `resolveIdleTimeout(env:)`; `lastActivity`
        /// advances on every request dispatch. `isIdle(now:)` is the pure
        /// decision consumed by the production watchdog.
        private var idleTimeoutSeconds: TimeInterval = 600
        private var lastActivity: Date = Date()

        /// Served-request counter exposed for `daemon status`. Bumped by
        /// `recordActivity(at:)` on every dispatch — including malformed
        /// lines and method-not-found cases, because "line received" is
        /// the activity signal that matters for the idle watchdog.
        private var requestCount: Int = 0

        /// Section 6 of `daemon-security-hardening`. When the lifecycle
        /// snapshot fields below are read by the bypass path, they must
        /// not require the cache actor — otherwise `daemon.status`
        /// queues behind a long-running AppleScript and the bypass is
        /// defeated. We capture `startedAt` directly on Instance and
        /// expose it via a synchronous actor property; pre-compiled
        /// count in the bypass path is read from a separate snapshot
        /// updated by handlers AFTER they return from cache.execute.
        private var startedAt: Date = Date()
        private var preCompiledCountSnapshot: Int = 0

        /// Section 6 of `daemon-security-hardening`. Optional callback
        /// fired by the lifecycle bypass when `daemon.shutdown` arrives.
        /// Wraps `Server.stop()` (or equivalent teardown) so the
        /// outer wrapper actor — which owns the pid file path and the
        /// idle-watchdog task — can clean up properly. The bypass path
        /// invokes this after attempting the shutdown caller's acknowledgement;
        /// local write completion is not a peer-delivery guarantee.
        private var shutdownHook: (@Sendable () async -> Void)?

        private let shutdownWatchdog: (@Sendable () -> Void)?
        private nonisolated let requestLineLimit: Int
        private nonisolated let connectionObservation: ConnectionObservation
        private let connectionEnvironment: DaemonConnection.Environment
        var trackedConnectionCount: Int { connections.count }
        var activeOperationCount: Int { operations.count }
        private let diagnosticClock: @Sendable () -> ContinuousClock.Instant
        private let diagnosticSleep: @Sendable () async throws -> Void
        private var diagnosticBudget: DaemonDiagnosticBudget
        private var diagnosticEnabled = false
        private var diagnosticGeneration = UUID()
        private var diagnosticFlushToken: UUID?
        private var diagnosticFlushTask: Task<Void, Never>?

        init(shutdownWatchdog: (@Sendable () -> Void)? = nil,
             requestLineLimit: Int = DaemonServer.maxRequestLineBytes,
             diagnosticClock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
             diagnosticSleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) },
             connectionObservation: ConnectionObservation = .init(),
             connectionEnvironment: DaemonConnection.Environment = .init()) {
            precondition(requestLineLimit > 0 && requestLineLimit < Int.max)
            self.shutdownWatchdog = shutdownWatchdog
            self.requestLineLimit = requestLineLimit
            self.connectionObservation = connectionObservation
            self.connectionEnvironment = connectionEnvironment
            self.diagnosticClock = diagnosticClock
            self.diagnosticSleep = diagnosticSleep
            self.diagnosticBudget = DaemonDiagnosticBudget(now: diagnosticClock())
        }


        /// Register a method handler. Overwrites any previous handler for the same method.
        func register(_ method: String, handler: @escaping MethodHandler) {
            handlers[method] = handler
        }

        /// Install a log writer that receives one redacted JSON-line per
        /// dispatched request. Pass `nil` to disable. The `logFull` flag
        /// disables redaction for `SAFARI_BROWSER_DAEMON_LOG_FULL=1`
        /// local-debugging sessions; default is `false` so no contributor
        /// can accidentally turn on raw logging without setting the env.
        func setLogWriter(_ writer: (@Sendable (String) -> Void)?, logFull: Bool = false) {
            self.logWriter = writer
            self.logFull = logFull
            diagnosticGeneration = UUID()
            diagnosticFlushTask?.cancel()
            diagnosticEnabled = writer != nil
            diagnosticBudget = DaemonDiagnosticBudget(now: diagnosticClock())
        }

        struct DiagnosticEmission: Sendable {
            let writer: @Sendable (String) -> Void
            let value: DaemonDiagnosticBudget.Emission
            func write() { writer(DaemonLog.formatDiagnostic(timestamp: Date(), emission: value)) }
        }

        nonisolated func recordDiagnostic(_ event: DaemonDiagnosticBudget.Event) async {
            guard let emission = await prepareDiagnostic(event) else { return }
            emission.write()
        }

        private func prepareDiagnostic(_ event: DaemonDiagnosticBudget.Event) -> DiagnosticEmission? {
            guard diagnosticEnabled, let writer = logWriter, !Task.isCancelled else { return nil }
            let value = diagnosticBudget.record(event, at: diagnosticClock())
            scheduleDiagnosticFlush()
            return value.map { DiagnosticEmission(writer: writer, value: $0) }
        }

        private func scheduleDiagnosticFlush() {
            guard diagnosticEnabled, logWriter != nil, diagnosticBudget.hasPending,
                  diagnosticFlushTask == nil else { return }
            let token = UUID(), generation = diagnosticGeneration
            let sleep = diagnosticSleep
            diagnosticFlushToken = token
            diagnosticFlushTask = Task.detached { [weak self] in
                var schedulingFailed = false
                do {
                    while !Task.isCancelled {
                        try await sleep()
                        guard !Task.isCancelled, let owner = self else { break }
                        if let emission = await owner.prepareDiagnosticFlush(token: token, generation: generation) {
                            emission.write()
                        }
                        guard await owner.keepDiagnosticFlush(token: token, generation: generation) else { break }
                    }
                } catch { schedulingFailed = true }
                await self?.finishDiagnosticFlush(token: token, failedGeneration: schedulingFailed ? generation : nil)
            }
        }

        private func prepareDiagnosticFlush(token: UUID, generation: UUID) -> DiagnosticEmission? {
            guard diagnosticFlushToken == token, diagnosticGeneration == generation,
                  diagnosticEnabled, let writer = logWriter, !Task.isCancelled else { return nil }
            return diagnosticBudget.drain(at: diagnosticClock()).map { DiagnosticEmission(writer: writer, value: $0) }
        }

        private func keepDiagnosticFlush(token: UUID, generation: UUID) -> Bool {
            diagnosticFlushToken == token && diagnosticGeneration == generation
                && diagnosticEnabled && diagnosticBudget.hasPending && !Task.isCancelled
        }

        private func finishDiagnosticFlush(token: UUID, failedGeneration: UUID?) {
            guard diagnosticFlushToken == token else { return }
            diagnosticFlushTask = nil
            diagnosticFlushToken = nil
            // A broken scheduling source must not busy-loop on the same
            // pending state. A later candidate can attempt scheduling again.
            if failedGeneration == diagnosticGeneration { return }
            // A replacement writer can accumulate new state while the old
            // writer is blocked. Start its worker only after this one ends.
            scheduleDiagnosticFlush()
        }

        fileprivate func currentLogWriter() -> (@Sendable (String) -> Void)? { logWriter }
        fileprivate func currentLogFull() -> Bool { logFull }

        // MARK: - Idle auto-shutdown (task 6.1)

        /// Parse `SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT` from an environment
        /// dict and clamp to the spec-mandated `[60, 3600]` range. Invalid,
        /// empty, or missing values all fall back to the 600-second default.
        static func resolveIdleTimeout(env: [String: String]) -> TimeInterval {
            guard let raw = env["SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT"], !raw.isEmpty,
                  let seconds = TimeInterval(raw) else {
                return 600
            }
            return min(max(seconds, 60), 3600)
        }

        /// Override the current idle timeout. Clamps the input to
        /// `[60, 3600]` so callers can't accidentally bypass the spec bounds.
        func configureIdleTimeout(_ seconds: TimeInterval) {
            idleTimeoutSeconds = min(max(seconds, 60), 3600)
        }

        /// Mark activity at `at` (default now). Called from the dispatch
        /// path on every incoming request so the idle watchdog sees a
        /// fresh timestamp between consecutive automation steps.
        /// Also increments the served-request counter so `daemon status`
        /// can surface a meaningful number.
        func recordActivity(at: Date = Date()) {
            lastActivity = at
            requestCount += 1
        }

        /// Idle decision for the watchdog. Pure: given a `now` timestamp,
        /// returns whether the idle timeout has elapsed since the last
        /// recorded activity.
        func isIdle(now: Date = Date()) -> Bool {
            now.timeIntervalSince(lastActivity) >= idleTimeoutSeconds
        }

        /// Snapshot of served-request count for status reporting.
        var currentRequestCount: Int { requestCount }

        // MARK: - Section 6: lifecycle bypass + in-flight tracking

        /// Snapshot uptime — read by the bypass status path. No cache
        /// awaits because we deliberately store `startedAt` here rather
        /// than on the Server wrapper actor.
        var currentUptimeSeconds: TimeInterval { Date().timeIntervalSince(startedAt) }

        /// Snapshot of pre-compiled cache size, refreshed by handlers
        /// after they complete `cache.execute(...)`. May lag the real
        /// cache count by one update; that staleness is acceptable for
        /// a status read because the cache count is informational only.
        var currentPreCompiledCountSnapshot: Int { preCompiledCountSnapshot }

        /// Update the pre-compiled count snapshot. Handlers SHOULD call
        /// this with the latest value from the cache after each
        /// successful execute, so the bypass status path can answer
        /// without entering the cache actor.
        func recordPreCompiledCountSnapshot(_ n: Int) {
            preCompiledCountSnapshot = n
        }

        /// Set the recorded daemon-start timestamp. Called once at
        /// `start(socketPath:)` by `Server` so uptime is measured from
        /// listener bind, not actor allocation.
        func recordStartTimestamp(_ at: Date = Date()) {
            startedAt = at
            lastActivity = at
        }

        /// Install the shutdown hook invoked by the lifecycle bypass on
        /// `daemon.shutdown`. Production wiring sets this to
        /// `Server.stop()` so the wrapper actor's pid-file cleanup
        /// runs. Pass nil to clear.
        func setShutdownHook(_ hook: (@Sendable () async -> Void)?) {
            shutdownHook = hook
        }

        /// Admission captures a capability, never a lookup of a later run's hook.
        private struct ShutdownContext: Sendable {
            let generation: UUID
            let hook: (@Sendable () async -> Void)?
        }

        private func prepareShutdown(_ context: ShutdownContext) -> [InFlightSlot]? {
            guard !Task.isCancelled, context.generation == shutdownGeneration else { return nil }
            // The process-level watchdog is scheduled only for a still-current
            // request, in the same actor turn as the generation check.
            shutdownWatchdog?()
            return snapshotInFlight()
        }

        private func ownsShutdown(_ context: ShutdownContext) -> Bool {
            context.generation == shutdownGeneration
        }

        /// Read-only fixture seam for the final handoff after a valid shutdown
        /// plan was captured. It invokes the same guarded completion as the RPC.
        func capturedShutdownCompletionForTesting() -> @Sendable () async -> Void {
            let context = ShutdownContext(generation: shutdownGeneration, hook: shutdownHook)
            return { await self.completeShutdown(context) }
        }

        private func completeShutdown(_ context: ShutdownContext) async {
            guard context.generation == shutdownGeneration else { return }
            if let hook = context.hook {
                await hook()
            } else {
                cleanListener(cancelAcceptTask: true)
            }
        }

        /// A snapshot carries identities, never a raw fd for a delayed write.
        func snapshotInFlight() -> [InFlightSlot] {
            connections.values.compactMap { record in
                guard record.shutdown.generation == shutdownGeneration,
                      !record.connection.isRevoked, let work = record.request else { return nil }
                return InFlightSlot(connectionID: record.connection.id, requestID: work.id,
                                    requestIdJSON: work.request.requestIdJSON)
            }
        }

        /// Snapshot of the last-activity timestamp as seconds since epoch,
        /// for status reporting.
        var currentLastActivityEpoch: TimeInterval { lastActivity.timeIntervalSince1970 }

        /// Bind the Unix socket, start listening, and kick off the accept loop.
        /// Throws `DaemonError` on bind/listen failure.
        func start(socketPath: String,
                   onListenerFailure: (@Sendable (ListenerFailure) async -> Void)? = nil) async throws {
            try await start(socketPath: socketPath, environment: DaemonServer.AcceptEnvironment(),
                            onListenerFailure: onListenerFailure)
        }

        /// `environment` is a test seam: it drives the real loop behind a real
        /// listener with scripted accept results.
        func start(socketPath: String, environment: DaemonServer.AcceptEnvironment,
                   onListenerFailure: (@Sendable (ListenerFailure) async -> Void)? = nil) async throws {
            guard acceptTask == nil else { return } // idempotent — already started

            // Remove any stale socket left from a crashed prior run.
            unlink(socketPath)

            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw DaemonError.bindFailed("socket() failed: errno=\(errno)")
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathMaxBytes = MemoryLayout.size(ofValue: addr.sun_path) - 1
            let pathBytes = Array(socketPath.utf8)
            if pathBytes.count > pathMaxBytes {
                close(fd)
                throw DaemonError.bindFailed("socket path too long: \(socketPath.count) > \(pathMaxBytes)")
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                for (i, b) in pathBytes.enumerated() {
                    buf[i] = b
                }
                buf[pathBytes.count] = 0
            }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            // Restrict the inode mode of the socket file to 0o600 so only
            // this UID can connect via filesystem permissions per
            // Requirement: Socket and pid file permissions. macOS honors
            // the process umask when creating Unix-domain socket inodes
            // — saving + restoring around bind isolates the daemon's
            // permission policy from whatever shell/launchd umask we
            // inherited.
            let savedUmask = umask(0o077)
            defer { umask(savedUmask) }

            let bindRC = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, addrLen)
                }
            }
            if bindRC != 0 {
                close(fd)
                throw DaemonError.bindFailed("bind() failed: errno=\(errno)")
            }

            // Belt-and-suspenders: explicitly chmod the socket inode after
            // bind. Some macOS versions ignore umask for AF_UNIX sockets;
            // calling chmod(2) on the path makes the 0o600 contract
            // explicit and verifiable via stat(2).
            chmod(socketPath, 0o600)
            if listen(fd, 16) != 0 {
                close(fd)
                unlink(socketPath)
                throw DaemonError.bindFailed("listen() failed: errno=\(errno)")
            }

            // #178: the loop waits in poll() on the listener and a wake pipe,
            // so accept() must never block — a connection aborted between
            // poll() and accept() would otherwise park the loop where stop()
            // cannot reach it. Close-on-exec keeps the write end from leaking
            // into a child, which would stop its close() from waking the loop.
            var wake: [Int32] = [-1, -1]
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0, pipe(&wake) == 0 else {
                let code = errno
                close(fd)
                unlink(socketPath)
                throw DaemonError.bindFailed("listener setup failed: errno=\(code)")
            }
            guard wake.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else {
                let code = errno
                wake.forEach { close($0) }
                close(fd)
                unlink(socketPath)
                throw DaemonError.bindFailed("wake pipe setup failed: errno=\(code)")
            }

            diagnosticEnabled = logWriter != nil
            self.wakeWriteFd = wake[1]
            self.socketPath = socketPath

            // Snapshot handlers once per connection accepts; registrations
            // after start() land on future connections via latest snapshot
            // fetched at dispatch time.
            let instance = self
            let wakeRead = wake[0]
            let generation = UUID()
            listenerGeneration = generation
            shutdownGeneration = generation
            self.acceptTask = Task.detached(priority: .userInitiated) {
                guard let termination = await Self.acceptLoopResult(
                    listenerFd: fd, wakeFd: wakeRead, instance: instance, environment: environment
                ), let completion = await instance.finishListenerFailure(termination, generation: generation) else { return }
                // A synchronous writer can block indefinitely. Its captured,
                // budgeted emission must not hold up cleanup or notification.
                if let emission = completion.emission {
                    Task.detached { emission.write() }
                }
                await environment.beforeFailureNotification()
                await onListenerFailure?(termination.failure)
            }
        }

        /// Stop accepting new connections, cancel existing connection tasks,
        /// and remove the socket file. Returns without waiting for the accept
        /// loop, which closes the listener itself once it observes the wake.
        func stop() async {
            cleanListener(cancelAcceptTask: true)
        }

        private struct ListenerCompletion: Sendable {
            let emission: DiagnosticEmission?
        }

        /// This actor turn owns cleanup; no suspension can let a later start
        /// replace resources between the generation check and their release.
        private func finishListenerFailure(_ termination: ListenerTermination, generation: UUID) -> ListenerCompletion? {
            guard listenerGeneration == generation else { return nil }
            let emission = prepareDiagnostic(termination.event)
            cleanListener(cancelAcceptTask: false)
            return ListenerCompletion(emission: emission)
        }

        private func cleanListener(cancelAcceptTask: Bool) {
            listenerGeneration = nil
            shutdownGeneration = UUID()
            diagnosticEnabled = false
            diagnosticGeneration = UUID()
            diagnosticBudget.discardPending()
            diagnosticFlushTask?.cancel()
            if cancelAcceptTask { acceptTask?.cancel() }
            acceptTask = nil
            // #178: wake the loop rather than close its listener. The loop is
            // the only caller of accept() and closes the listener after its
            // last call, so no retry can reach a closed or reused descriptor.
            // Closing — not writing to — the write end stays safe if the loop
            // has already exited and closed the read end. Not awaiting the loop
            // keeps stop() independent of cooperative-pool scheduling (verify
            // R2 measured shutdown stalls when it waited).
            if wakeWriteFd >= 0 {
                close(wakeWriteFd)
                wakeWriteFd = -1
            }
            for record in connections.values {
                record.connection.revoke()
                record.request?.result.cancel()
                record.request?.replyFinished.cancel()
                record.task?.cancel()
            }
            connections.removeAll()
            // Do not discard genuinely unfinished operation tracking or await
            // a handler that cannot cooperate with cancellation.
            for task in operations.values { task.cancel() }
            if let path = socketPath {
                unlink(path)
                socketPath = nil
            }
        }

        // MARK: - Connection and request ownership (actor-isolated)

        fileprivate func admitConnection(_ clientFd: Int32) {
            guard !Task.isCancelled else { close(clientFd); return }
            let connection: DaemonConnection
            do { connection = try DaemonConnection(adopting: clientFd, environment: connectionEnvironment) }
            catch {
                // The adopter owns and closes even its failed setup descriptor.
                let code: Int32
                if case DaemonConnection.Failure.system(_, let value) = error { code = value }
                else { code = EIO }
                Task.detached { await self.recordDiagnostic(.init(kind: .setupFailed, errno: code,
                                                                  disposition: .closed, count: 1)) }
                return
            }
            let shutdown = ShutdownContext(generation: shutdownGeneration, hook: shutdownHook)
            let record = ConnectionRecord(connection: connection, shutdown: shutdown)
            connections[connection.id] = record
            let observation = connectionObservation
            record.task = Task.detached(priority: .userInitiated) {
                let diagnostic = await Self.serveConnection(connection: connection, instance: self)
                await self.finishConnection(connection.id)
                observation.didFinish()
                // Logging is a separate best-effort activity after transport
                // ownership and its registry entry have ended.
                if let diagnostic {
                    Task.detached { await self.recordDiagnostic(diagnostic) }
                }
            }
        }

        private func finishConnection(_ id: UUID) {
            guard let record = connections.removeValue(forKey: id) else { return }
            record.connection.revoke()
            if let work = record.request {
                work.result.cancel()
                work.replyFinished.cancel()
                operations[work.id]?.cancel()
            }
        }

        private func beginRequest(_ request: ParsedRequest, connectionID: UUID) -> RequestWork? {
            guard !Task.isCancelled, let record = connections[connectionID],
                  record.shutdown.generation == shutdownGeneration,
                  !record.connection.isRevoked, record.request == nil else { return nil }
            // The authority check, activity change, handler selection and work
            // admission are one actor turn. Stop cannot interleave between them.
            recordActivity()
            let work = RequestWork(connectionID: connectionID, request: request,
                                   log: LogSnapshot(writer: logWriter, full: logFull))
            record.request = work
            let handler = handlers[request.method]
            let shutdown = record.shutdown
            operations[work.id] = Task.detached(priority: .userInitiated) {
                if Task.isCancelled {
                    work.result.cancel()
                } else {
                    let reply = await Self.executeRequest(work, handler: handler,
                                                          instance: self, shutdown: shutdown)
                    work.result.complete(reply)
                }
                await self.finishOperation(work.id)
            }
            return work
        }

        private func finishOperation(_ id: UUID) { operations.removeValue(forKey: id) }

        private func finishReply(_ work: RequestWork) {
            guard let record = connections[work.connectionID], record.request === work else { return }
            record.request = nil
        }

        private func isCurrent(_ work: RequestWork) -> Bool {
            guard let record = connections[work.connectionID] else { return false }
            return record.shutdown.generation == shutdownGeneration
                && record.request === work && !record.connection.isRevoked
        }

        private func cancellationTarget(_ slot: InFlightSlot, context: ShutdownContext) -> RequestWork? {
            guard context.generation == shutdownGeneration,
                  let record = connections[slot.connectionID],
                  let work = record.request, work.id == slot.requestID,
                  isCurrent(work) else { return nil }
            return work
        }

        private func offerCancellation(_ reply: Reply, to work: RequestWork, context: ShutdownContext) -> Bool {
            guard context.generation == shutdownGeneration, isCurrent(work),
                  work.result.complete(reply) else { return false }
            operations[work.id]?.cancel()
            return true
        }

        private func statusResponse(for work: RequestWork) -> Data? {
            guard !Task.isCancelled, isCurrent(work) else { return nil }
            let payload: [String: Any] = [
                "pid": Int(getpid()), "uptimeSeconds": currentUptimeSeconds,
                "requestCount": currentRequestCount, "preCompiledCount": currentPreCompiledCountSnapshot,
                "lastActivityEpoch": currentLastActivityEpoch,
            ]
            return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        }

        // MARK: - Accept loop

        /// Accepts clients until `stop()` wakes it, the task is cancelled, or
        /// the listener turns out closed or invalid. #178: a failed `accept()`
        /// used to end the loop whatever the errno, leaving a daemon that was
        /// alive, owned its socket file, and never accepted again. Failures
        /// are now classified (`AcceptIncident`): transient ones retry,
        /// resource exhaustion backs off (cancellable, capped at 1 s), and
        /// only a closed or invalid listener ends the loop.
        ///
        /// The loop owns `listenerFd` and `wakeFd` and closes both on exit;
        /// `stop()` only cancels the task and closes the wake pipe's write end.
        /// Cancelling first and then closing the listener from `stop()`
        /// narrowed, but did not close, the window in which a retry could reach
        /// a closed or reused descriptor (verify R1).
        static func acceptLoop(
            listenerFd: Int32, wakeFd: Int32, instance: Instance,
            environment env: DaemonServer.AcceptEnvironment = .init()
        ) async {
            if let termination = await acceptLoopResult(listenerFd: listenerFd, wakeFd: wakeFd,
                                                        instance: instance, environment: env) {
                // Direct loop callers retain synchronous diagnostic observation.
                await instance.recordDiagnostic(termination.event)
            }
        }

        private struct ListenerTermination: Sendable {
            let failure: ListenerFailure
            let event: DaemonDiagnosticBudget.Event
        }

        private static func acceptLoopResult(
            listenerFd: Int32, wakeFd: Int32, instance: Instance,
            environment env: DaemonServer.AcceptEnvironment
        ) async -> ListenerTermination? {
            defer {
                close(listenerFd)
                close(wakeFd)
            }
            var incident = DaemonServer.AcceptIncident()
            var setupFailures = DaemonServer.SetupFailureStreak()
            while !Task.isCancelled {
                let waited = env.wait(listenerFd, wakeFd)
                guard !Task.isCancelled else { return nil }
                let (clientFd, code): (Int32, Int32)
                switch waited {
                case .wake: return nil
                case .idle: continue   // re-checks cancellation
                case .failed(let e): (clientFd, code) = (-1, e)
                case .ready: (clientFd, code) = env.accept(listenerFd)
                }
                guard clientFd >= 0 else {
                    let step = incident.recordFailure(errno: code, at: env.now())
                    if step.disposition == .stop {
                        return ListenerTermination(
                            failure: ListenerFailure(operation: waited == .ready ? .accept : .poll, errno: code),
                            event: .init(kind: waited == .ready ? .acceptError : .acceptWaitError,
                                         errno: code, disposition: .stop, count: incident.streak))
                    }
                    if step.log {
                        await logEvent(instance, waited == .ready ? .acceptError : .acceptWaitError,
                                       errno: code, disposition: step.disposition.diagnosticDisposition, count: incident.streak)
                    }
                    switch step.disposition {
                    case .stop: return nil // handled above before diagnostic writing
                    case .retry: continue
                    case .backoff:
                        do { try await env.sleep(step.delay ?? .zero) } catch { return nil }   // stop() must not wait it out
                        continue
                    }
                }
                if let ended = incident.recordSuccess() {
                    await logEvent(instance, .acceptRecovered, errno: ended.errno,
                                   disposition: .recovered, count: ended.streak)
                }
                await admit(clientFd, instance: instance, at: env.now(), setupFailures: &setupFailures)
            }
            return nil
        }

        /// Serves an accepted client, or closes it if it cannot be made safe.
        /// A peer that closed before accept can make setup fail: never write a
        /// handshake on an unprotected socket (#175), and record it (#178) so a
        /// persistent failure is diagnosable. The next good connection ends
        /// the setup-failure streak.
        private static func admit(
            _ clientFd: Int32, instance: Instance, at now: ContinuousClock.Instant,
            setupFailures: inout DaemonServer.SetupFailureStreak
        ) async {
            let setupErrno = DaemonServer.prepareAcceptedClient(clientFd)
            guard setupErrno == 0 else {
                close(clientFd)
                let step = setupFailures.recordFailure(at: now)
                if step.log {
                    await logEvent(instance, .setupFailed, errno: setupErrno,
                                   disposition: .closed, count: step.count)
                }
                return
            }
            if let ended = setupFailures.recordSuccess() {
                await logEvent(instance, .setupRecovered, errno: 0,
                               disposition: .recovered, count: ended)
            }
            // Ownership transfers to the actor, which either closes a revoked
            // client or creates and tracks its handler without an await gap.
            await instance.admitConnection(clientFd)
        }

        /// One redacted-by-construction event line: event name, errno,
        /// disposition and count only — no paths, no client data.
        private static func logEvent(
            _ instance: Instance, _ event: DaemonDiagnosticBudget.Kind, errno code: Int32,
            disposition: DaemonDiagnosticBudget.Disposition, count: Int
        ) async {
            await instance.recordDiagnostic(.init(kind: event, errno: code, disposition: disposition, count: count))
        }

        // MARK: - Transport / operation separation

        private struct ParsedRequest: Sendable {
            let method: String
            let params: Data
            let requestIdJSON: Data
            let started: Date
            let rejection: Rejection?
            struct Rejection: Sendable { let code: ErrorCode; let message: String }

            static func decode(_ line: Data) -> Self {
                let started = Date()
                let parsed: Any
                do { parsed = try JSONSerialization.jsonObject(with: line) }
                catch {
                    return Self(method: "<parse-error>", params: Data("{}".utf8),
                                requestIdJSON: Data("null".utf8), started: started,
                                rejection: .init(code: .parseError, message: "invalid JSON: \(error)"))
                }
                guard let object = parsed as? [String: Any] else {
                    return Self(method: "<parse-error>", params: Data("{}".utf8),
                                requestIdJSON: Data("null".utf8), started: started,
                                rejection: .init(code: .parseError, message: "request must be JSON object"))
                }
                let id = encodeRequestId(object["requestId"])
                guard let method = object["method"] as? String else {
                    return Self(method: "<missing>", params: Data("{}".utf8), requestIdJSON: id,
                                started: started, rejection: .init(code: .parseError, message: "missing 'method'"))
                }
                if LifecycleMethod(rawValue: method) != nil {
                    // Lifecycle parameters have always been ignored, including
                    // logging. Preserve that shape and privacy boundary.
                    return Self(method: method, params: Data("{}".utf8), requestIdJSON: id,
                                started: started, rejection: nil)
                }
                let paramsValue = object["params"] ?? [:]
                guard JSONSerialization.isValidJSONObject(paramsValue) else {
                    return Self(method: method, params: Data("{}".utf8), requestIdJSON: id,
                                started: started, rejection: .init(code: .parseError, message: "unserialisable params"))
                }
                do {
                    let params = try JSONSerialization.data(withJSONObject: paramsValue)
                    return Self(method: method, params: params, requestIdJSON: id, started: started, rejection: nil)
                } catch {
                    return Self(method: method, params: Data("{}".utf8), requestIdJSON: id,
                                started: started, rejection: .init(code: .parseError, message: "unserialisable params"))
                }
            }
        }

        private struct LogSnapshot: Sendable {
            let writer: (@Sendable (String) -> Void)?
            let full: Bool
        }

        private struct ShutdownPlan: Sendable {
            let context: ShutdownContext
            let candidates: [InFlightSlot]
            let caller: UUID
        }

        private struct Reply: Sendable {
            let bytes: Data
            var deadline: ContinuousClock.Instant? = nil
            var shutdown: ShutdownPlan? = nil
            var closesConnection = false
        }

        private final class RequestWork: Sendable {
            let id = UUID()
            let connectionID: UUID
            let request: ParsedRequest
            let log: LogSnapshot
            let result = DaemonRequestCompletion<Reply>()
            let replyFinished = DaemonRequestCompletion<Bool>()
            init(connectionID: UUID, request: ParsedRequest, log: LogSnapshot) {
                self.connectionID = connectionID
                self.request = request
                self.log = log
            }
        }

        private static func serveConnection(
            connection: DaemonConnection, instance: Instance
        ) async -> DaemonDiagnosticBudget.Event? {
            defer { connection.revoke() }
            guard await writeLine(connection: connection, line: DaemonProtocol.encodeHandshake()) else { return nil }
            var reader = RequestLineReader(maxBytes: instance.requestLineLimit)
            while !Task.isCancelled && !connection.isRevoked {
                let line: Data
                do {
                    instance.connectionObservation.beforeRead()
                    guard let next = try await reader.readLine(connection: connection) else { return nil }
                    line = next
                } catch let failure as RequestLineReader.ReadError {
                    let cancelled = connection.isRevoked || Task.isCancelled
                    connection.revoke()
                    reader = RequestLineReader(maxBytes: instance.requestLineLimit)
                    guard !cancelled else { return nil }
                    switch failure {
                    case .lineTooLong:
                        return .init(kind: .requestTooLong, errno: EMSGSIZE, disposition: .closed)
                    case .readFailed(let code):
                        return .init(kind: .requestReadFailed, errno: code, disposition: .closed)
                    }
                } catch let failure as DaemonConnection.Failure {
                    let cancelled = connection.isRevoked || Task.isCancelled
                    connection.revoke()
                    reader = RequestLineReader(maxBytes: instance.requestLineLimit)
                    guard !cancelled else { return nil }
                    if case .system(_, let code) = failure {
                        return .init(kind: .requestReadFailed, errno: code, disposition: .closed)
                    }
                    return nil
                } catch { return nil }

                let parsed = ParsedRequest.decode(line)
                await instance.connectionObservation.beforeDispatch()
                guard let work = await instance.beginRequest(parsed, connectionID: connection.id) else { return nil }
                // Always consume this single-consumer gate, even if cancellation
                // arrived while beginRequest returned, to release a winning value.
                guard let reply = await work.result.wait() else {
                    work.replyFinished.cancel()
                    return nil
                }
                let sent = await writeLine(connection: connection, line: reply.bytes, deadline: reply.deadline)
                work.replyFinished.complete(sent)
                await instance.finishReply(work)
                if let plan = reply.shutdown {
                    // An authorized shutdown continues even if its ACK could not
                    // be delivered. The plan has independent generation checks.
                    await performShutdown(plan, instance: instance)
                    return nil
                }
                if !sent || reply.closesConnection { return nil }
            }
            return nil
        }

        // MARK: - Lifecycle bypass and response selection

        enum LifecycleMethod: String, Sendable { case status = "daemon.status", shutdown = "daemon.shutdown" }

        static func peekLifecycleMethod(line: Data) -> LifecycleMethod? {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let method = object["method"] as? String else { return nil }
            return LifecycleMethod(rawValue: method)
        }

        private static func cancelledReply(_ work: RequestWork) -> Reply {
            Reply(bytes: encodeErrorRaw(requestIdJSON: work.request.requestIdJSON, code: .cancelled,
                                        message: "daemon run stopped before request completion"), closesConnection: true)
        }

        private static func executeRequest(
            _ work: RequestWork, handler: MethodHandler?, instance: Instance, shutdown: ShutdownContext
        ) async -> Reply {
            let request = work.request
            let requestId = try? JSONSerialization.jsonObject(with: request.requestIdJSON, options: [.fragmentsAllowed])
            if let rejection = request.rejection {
                emitLog(work, result: nil, error: "parseError")
                return Reply(bytes: encodeError(requestId: requestId, code: rejection.code, message: rejection.message))
            }
            if let lifecycle = LifecycleMethod(rawValue: request.method) {
                switch lifecycle {
                case .status:
                    guard let data = await instance.statusResponse(for: work) else { return cancelledReply(work) }
                    emitLog(work, result: data, error: nil)
                    return Reply(bytes: encodeResult(requestId: requestId, resultData: data))
                case .shutdown:
                    emitLog(work, result: Data("{}".utf8), error: nil)
                    guard let candidates = await instance.prepareShutdown(shutdown) else { return cancelledReply(work) }
                    return Reply(bytes: encodeResult(requestId: requestId, resultData: Data("{}".utf8)),
                                 deadline: ContinuousClock.now.advanced(by: .milliseconds(250)),
                                 shutdown: ShutdownPlan(context: shutdown, candidates: candidates, caller: work.connectionID))
                }
            }
            guard let handler else {
                emitLog(work, result: nil, error: "methodNotFound")
                return Reply(bytes: encodeError(requestId: requestId, code: .methodNotFound,
                                                message: "no handler: \(request.method)"))
            }
            let context = DaemonRequestContext()
            do {
                let result = try await DaemonRequestContext.$current.withValue(context) {
                    try await PerformanceTrace.$daemonErrorTimingSink.withValue({ context.recordErrorTiming($0) }) {
                        try Task.checkCancellation()
                        return try await handler(request.params)
                    }
                }
                let response = encodeResult(requestId: requestId, resultData: result, diagnostics: context.diagnostics)
                emitLog(work, result: result, error: nil)
                return Reply(bytes: response)
            } catch {
                let response = encodeError(requestId: requestId, code: .handlerError, message: "\(error)",
                                           diagnostics: context.diagnostics, timing: context.errorTiming)
                emitLog(work, result: nil, error: "\(error)")
                return Reply(bytes: response)
            }
        }

        private static func performShutdown(_ plan: ShutdownPlan, instance: Instance) async {
            guard await instance.ownsShutdown(plan.context) else { return }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
            for slot in plan.candidates where slot.connectionID != plan.caller {
                guard ContinuousClock.now < deadline else { break }
                guard let work = await instance.cancellationTarget(slot, context: plan.context) else { continue }
                let frame = encodeErrorRaw(requestIdJSON: slot.requestIdJSON, code: .cancelled,
                                           message: "cancelled by daemon shutdown")
                let reply = Reply(bytes: frame, deadline: deadline, closesConnection: true)
                guard await instance.offerCancellation(reply, to: work, context: plan.context) else { continue }
                let timer = Task.detached {
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    guard !Task.isCancelled else { return }
                    work.replyFinished.cancel()
                }
                _ = await work.replyFinished.wait()
                timer.cancel()
            }
            await instance.completeShutdown(plan.context)
        }

        /// The writer and privacy mode belong to the admitted request. A late
        /// operation does not borrow the replacement run's logger.
        private static func emitLog(_ work: RequestWork, result: Data?, error: String?) {
            guard let writer = work.log.writer else { return }
            let request = work.request
            let requestId = try? JSONSerialization.jsonObject(with: request.requestIdJSON, options: [.fragmentsAllowed])
            let params = String(data: DaemonLog.redactParams(method: request.method, paramsJSON: request.params,
                                                            logFull: work.log.full), encoding: .utf8) ?? "{}"
            let resultLog = result.flatMap {
                String(data: DaemonLog.truncateResult(resultJSON: $0, logFull: work.log.full), encoding: .utf8)
            }
            writer(DaemonLog.formatEntry(timestamp: request.started, method: request.method, requestId: requestId,
                                        durationMs: Int(Date().timeIntervalSince(request.started) * 1000),
                                        paramsLog: params, resultLog: resultLog, errorLog: error))
        }

        // MARK: - Response encoding

        private static func encodeResult(requestId: Any?, resultData: Data, diagnostics: [String] = []) -> Data {
            let resultValue: Any = (try? JSONSerialization.jsonObject(with: resultData, options: [.fragmentsAllowed])) ?? NSNull()
            var envelope: [String: Any] = [
                "requestId": requestId ?? NSNull(),
                "result": resultValue,
            ]
            if !diagnostics.isEmpty { envelope["diagnostics"] = diagnostics }
            return (try? JSONSerialization.data(withJSONObject: envelope, options: [])) ?? Data("{}".utf8)
        }

        private static func encodeError(requestId: Any?, code: ErrorCode, message: String, diagnostics: [String] = [], timing: PerformanceTrace.Summary? = nil) -> Data {
            var envelope: [String: Any] = [
                "requestId": requestId ?? NSNull(),
                "error": ["code": code.rawValue, "message": message] as [String: Any],
            ]
            if !diagnostics.isEmpty { envelope["diagnostics"] = diagnostics }
            if let timing, let data = try? JSONEncoder().encode(timing), data.count <= 65536,
               let object = try? JSONSerialization.jsonObject(with: data) {
                envelope["timing"] = object
            }
            return (try? JSONSerialization.data(withJSONObject: envelope, options: [])) ?? Data("{}".utf8)
        }

        /// Section 6: encode a `requestId` value (which may be Int, String,
        /// or NSNull) into its JSON snippet so it can cross actor
        /// boundaries as Sendable `Data`. Used by `markInFlight` to store
        /// the encoded form before handler dispatch.
        static func encodeRequestId(_ requestId: Any?) -> Data {
            let value: Any = requestId ?? NSNull()
            return (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
                ?? Data("null".utf8)
        }

        /// Section 6: build a cancelled-error envelope from a pre-encoded
        /// requestId snippet. Re-decodes the requestId snippet so it can
        /// re-enter the JSON object construction; this keeps shape
        /// fidelity (Int stays Int, String stays String) without
        /// re-implementing JSON escaping.
        static func encodeErrorRaw(requestIdJSON: Data, code: ErrorCode, message: String) -> Data {
            let requestIdValue: Any = (try? JSONSerialization.jsonObject(
                with: requestIdJSON, options: [.fragmentsAllowed]
            )) ?? NSNull()
            let envelope: [String: Any] = [
                "requestId": requestIdValue,
                "error": ["code": code.rawValue, "message": message] as [String: Any],
            ]
            return (try? JSONSerialization.data(withJSONObject: envelope, options: [])) ?? Data("{}".utf8)
        }

        // MARK: - Line I/O (POSIX)

        private static func writeLine(
            connection: DaemonConnection, line: Data, deadline: ContinuousClock.Instant? = nil
        ) async -> Bool {
            var payload = line
            payload.append(0x0A)
            do { try await connection.write(payload, deadline: deadline); return true }
            catch { return false }
        }

    }

    enum DaemonError: Error, CustomStringConvertible {
        case bindFailed(String)

        var description: String {
            switch self {
            case .bindFailed(let reason): return "daemon bind failed: \(reason)"
            }
        }
    }
}
