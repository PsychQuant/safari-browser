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

    /// Sendable carrier for the in-flight pair so the actor's
    /// `snapshotInFlight()` method can return cleanly across the actor
    /// boundary. `requestIdJSON` is the already-encoded JSON snippet
    /// for the requestId field (e.g. `42` or `"abc"`); writing it
    /// verbatim into the cancelled envelope avoids re-serialization
    /// and dodges the non-Sendable `Any` problem.
    struct InFlightSlot: Sendable {
        let fd: Int32
        let requestIdJSON: Data
    }

    /// Error codes surfaced in JSON-lines responses.
    enum ErrorCode: String {
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
        private var socketPath: String?
        private var connectionTasks: [Task<Void, Never>] = []

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

        /// Section 6 of `daemon-security-hardening`. In-flight request
        /// tracking lets `daemon.shutdown` send a `cancelled` error to
        /// every active client connection before the daemon dies, so
        /// callers don't sit blocked on a forever-pending response.
        /// Map: client fd → JSON-encoded requestId snippet so the
        /// cancelled envelope correlates with the request the client
        /// is awaiting. Storing the requestId as `Data` keeps the
        /// actor fully Sendable (raw `Any?` would not be).
        private var inFlightRequestIds: [Int32: Data] = [:]

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
        /// invokes this from a detached Task so the response to the
        /// shutdown caller lands first.
        private var shutdownHook: (@Sendable () async -> Void)?

        private let shutdownWatchdog: (@Sendable () -> Void)?

        init(shutdownWatchdog: (@Sendable () -> Void)? = nil) {
            self.shutdownWatchdog = shutdownWatchdog
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
        }

        /// Install the shutdown hook invoked by the lifecycle bypass on
        /// `daemon.shutdown`. Production wiring sets this to
        /// `Server.stop()` so the wrapper actor's pid-file cleanup
        /// runs. Pass nil to clear.
        func setShutdownHook(_ hook: (@Sendable () async -> Void)?) {
            shutdownHook = hook
        }

        fileprivate func currentShutdownHook() -> (@Sendable () async -> Void)? { shutdownHook }

        /// Mark a client connection as having an in-flight request whose
        /// requestId is `requestIdJSON` (already JSON-encoded). Called
        /// from the dispatch path before invoking the handler.
        func markInFlight(fd: Int32, requestIdJSON: Data) {
            inFlightRequestIds[fd] = requestIdJSON
        }

        /// Clear the in-flight slot for `fd`. Called from the dispatch
        /// path after handler completes (success or error).
        func clearInFlight(fd: Int32) {
            inFlightRequestIds.removeValue(forKey: fd)
        }

        /// Snapshot of in-flight (fd, requestIdJSON) pairs. Consumed by
        /// `daemon.shutdown` to send a `cancelled` envelope to every
        /// active client before tearing down the socket.
        func snapshotInFlight() -> [InFlightSlot] {
            inFlightRequestIds.map { InFlightSlot(fd: $0.key, requestIdJSON: $0.value) }
        }

        /// Snapshot of the last-activity timestamp as seconds since epoch,
        /// for status reporting.
        var currentLastActivityEpoch: TimeInterval { lastActivity.timeIntervalSince1970 }

        /// Bind the Unix socket, start listening, and kick off the accept loop.
        /// Throws `DaemonError` on bind/listen failure.
        func start(socketPath: String) async throws {
            try await start(socketPath: socketPath, environment: DaemonServer.AcceptEnvironment())
        }

        /// `environment` is a test seam: it drives the real loop behind a real
        /// listener with scripted accept results.
        func start(socketPath: String, environment: DaemonServer.AcceptEnvironment) async throws {
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

            self.wakeWriteFd = wake[1]
            self.socketPath = socketPath

            // Snapshot handlers once per connection accepts; registrations
            // after start() land on future connections via latest snapshot
            // fetched at dispatch time.
            let instance = self
            let wakeRead = wake[0]
            self.acceptTask = Task.detached(priority: .userInitiated) {
                await Self.acceptLoop(listenerFd: fd, wakeFd: wakeRead, instance: instance, environment: environment)
            }
        }

        /// Stop accepting new connections, close existing connections,
        /// and remove the socket file. Returns without waiting for the accept
        /// loop, which closes the listener itself once it observes the wake.
        func stop() async {
            acceptTask?.cancel()
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
            for task in connectionTasks {
                task.cancel()
            }
            connectionTasks.removeAll()
            if let path = socketPath {
                unlink(path)
                socketPath = nil
            }
        }

        // MARK: - Internal dispatch (actor-isolated)

        fileprivate func lookupHandler(_ method: String) -> MethodHandler? {
            handlers[method]
        }

        fileprivate func trackConnection(_ task: Task<Void, Never>) {
            connectionTasks.append(task)
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
            defer {
                close(listenerFd)
                close(wakeFd)
            }
            var incident = DaemonServer.AcceptIncident()
            var setupFailures = DaemonServer.SetupFailureStreak()
            while !Task.isCancelled {
                let waited = env.wait(listenerFd, wakeFd)
                let (clientFd, code): (Int32, Int32)
                switch waited {
                case .wake: return
                case .idle: continue   // re-checks cancellation
                case .failed(let e): (clientFd, code) = (-1, e)
                case .ready: (clientFd, code) = env.accept(listenerFd)
                }
                guard clientFd >= 0 else {
                    let step = incident.recordFailure(errno: code, at: env.now())
                    if step.log {
                        await logEvent(instance, waited == .ready ? "accept_error" : "accept_wait_error",
                                       errno: code, disposition: step.disposition.rawValue, count: incident.streak)
                    }
                    switch step.disposition {
                    case .stop: return
                    case .retry: continue
                    case .backoff:
                        do { try await env.sleep(step.delay ?? .zero) } catch { return }   // stop() must not wait it out
                        continue
                    }
                }
                if let ended = incident.recordSuccess() {
                    await logEvent(instance, "accept_recovered", errno: ended.errno,
                                   disposition: "recovered", count: ended.streak)
                }
                await admit(clientFd, instance: instance, at: env.now(), setupFailures: &setupFailures)
            }
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
                    await logEvent(instance, "connection_setup_failed", errno: setupErrno,
                                   disposition: "closed", count: step.count)
                }
                return
            }
            if let ended = setupFailures.recordSuccess() {
                await logEvent(instance, "connection_setup_recovered", errno: 0,
                               disposition: "recovered", count: ended)
            }
            let handlerTask = Task.detached(priority: .userInitiated) {
                await Self.serveConnection(clientFd: clientFd, instance: instance)
            }
            await instance.trackConnection(handlerTask)
        }

        /// One redacted-by-construction event line: event name, errno,
        /// disposition and count only — no paths, no client data.
        private static func logEvent(
            _ instance: Instance, _ event: String, errno code: Int32,
            disposition: String, count: Int
        ) async {
            guard let writer = await instance.currentLogWriter() else { return }
            writer(DaemonLog.formatEvent(timestamp: Date(), event: event, errno: code,
                                         disposition: disposition, count: count))
        }

        private static func serveConnection(clientFd: Int32, instance: Instance) async {
            defer { close(clientFd) }
            // Send the handshake first line per the `Version handshake refuses
            // mismatched client` spec. The client reads one line before
            // sending any request and aborts if the version does not match.
            if !writeLine(fd: clientFd, line: DaemonProtocol.encodeHandshake()) { return }
            while !Task.isCancelled {
                guard let line = readLine(fd: clientFd) else { return }
                // Section 6 — lifecycle bypass. Peek at the method
                // before entering the regular dispatch path. Lifecycle
                // commands (`daemon.status`, `daemon.shutdown`) take a
                // separate fast path that does NOT touch the cache
                // actor, so a long-running AppleScript request cannot
                // block them.
                let response: Data
                if let lifecycle = peekLifecycleMethod(line: line) {
                    response = await dispatchLifecycle(lifecycle: lifecycle, line: line, instance: instance, fd: clientFd)
                } else {
                    response = await dispatchLine(line: line, fd: clientFd, instance: instance)
                }
                if !writeLine(fd: clientFd, line: response) { return }
            }
        }

        // MARK: - Section 6: lifecycle bypass

        /// Lifecycle method routing. Recognized values bypass the regular
        /// handler dispatch and read directly from `Instance`'s snapshot
        /// fields, never the cache actor.
        enum LifecycleMethod: String {
            case status = "daemon.status"
            case shutdown = "daemon.shutdown"
        }

        /// Cheap pre-dispatch parse: extract just the `method` field from
        /// a JSON-line if it matches a `LifecycleMethod` case. Returns nil
        /// for non-lifecycle requests so the caller routes through the
        /// regular dispatch path.
        static func peekLifecycleMethod(line: Data) -> LifecycleMethod? {
            guard let obj = try? JSONSerialization.jsonObject(with: line, options: []) as? [String: Any],
                  let method = obj["method"] as? String,
                  let lifecycle = LifecycleMethod(rawValue: method) else {
                return nil
            }
            return lifecycle
        }

        /// Dispatch a lifecycle command without touching the cache actor.
        /// `daemon.status` reads from Instance's snapshot fields and
        /// returns immediately. `daemon.shutdown` sends a `cancelled`
        /// envelope to every in-flight client, replies `{}` to its own
        /// caller, and schedules an asynchronous teardown + 5s
        /// watchdog so the process exits within the spec deadline even
        /// if `Server.stop()` stalls.
        private static func dispatchLifecycle(
            lifecycle: LifecycleMethod,
            line: Data,
            instance: Instance,
            fd: Int32
        ) async -> Data {
            await instance.recordActivity()
            let started = Date()
            let obj = (try? JSONSerialization.jsonObject(with: line, options: []) as? [String: Any]) ?? [:]
            let requestId = obj["requestId"]

            let response: Data
            switch lifecycle {
            case .status:
                let pid = Int(getpid())
                let uptime = await instance.currentUptimeSeconds
                let requestCount = await instance.currentRequestCount
                let preCount = await instance.currentPreCompiledCountSnapshot
                let lastActivity = await instance.currentLastActivityEpoch
                let payload: [String: Any] = [
                    "pid": pid,
                    "uptimeSeconds": uptime,
                    "requestCount": requestCount,
                    "preCompiledCount": preCount,
                    "lastActivityEpoch": lastActivity,
                ]
                let resultData = (try? JSONSerialization.data(withJSONObject: payload, options: []))
                    ?? Data("{}".utf8)
                response = encodeResult(requestId: requestId, resultData: resultData)
                await emitLog(instance: instance, started: started, method: lifecycle.rawValue, requestId: requestId, paramsData: Data("{}".utf8), resultData: resultData, errorMessage: nil)
            case .shutdown:
                // Snapshot in-flight clients BEFORE replying so the
                // teardown can cancel them deterministically.
                let inFlight = await instance.snapshotInFlight()
                response = encodeResult(requestId: requestId, resultData: Data("{}".utf8))
                await emitLog(instance: instance, started: started, method: lifecycle.rawValue, requestId: requestId, paramsData: Data("{}".utf8), resultData: Data("{}".utf8), errorMessage: nil)

                // Async teardown — runs after we return so the shutdown
                // caller's `{}` reply lands on the wire. Cancellation
                // envelopes go to each in-flight fd; the daemon then
                // closes them and stops the listener. 5s watchdog
                // guarantees the process exits even if graceful path
                // stalls (e.g., NSAppleScript still running).
                let hook = await instance.currentShutdownHook()
                Task.detached {
                    for slot in inFlight where slot.fd != fd {
                        let envelope = encodeErrorRaw(
                            requestIdJSON: slot.requestIdJSON,
                            code: .cancelled,
                            message: "cancelled by daemon shutdown"
                        )
                        _ = writeLine(fd: slot.fd, line: envelope)
                    }
                    if let hook = hook {
                        await hook()
                    } else {
                        await instance.stop()
                    }
                }
                // The production entry owns process termination. Tests and
                // other embedded users keep normal teardown without _exit.
                let watchdog = await instance.shutdownWatchdog
                watchdog?()
            }
            return response
        }

        private static func dispatchLine(line: Data, fd: Int32, instance: Instance) async -> Data {
            // Record activity at the top of dispatch so an actively-used
            // daemon never gets idle-killed between consecutive requests.
            await instance.recordActivity()
            let started = Date()

            // Parse the incoming request envelope.
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: line, options: [])
            } catch {
                let resp = encodeError(requestId: nil, code: .parseError, message: "invalid JSON: \(error)")
                await emitLog(instance: instance, started: started, method: "<parse-error>", requestId: nil, paramsData: line, resultData: nil, errorMessage: "parseError")
                return resp
            }
            guard let obj = parsed as? [String: Any] else {
                let resp = encodeError(requestId: nil, code: .parseError, message: "request must be JSON object")
                await emitLog(instance: instance, started: started, method: "<parse-error>", requestId: nil, paramsData: line, resultData: nil, errorMessage: "parseError")
                return resp
            }
            let requestId = obj["requestId"]
            guard let method = obj["method"] as? String else {
                let resp = encodeError(requestId: requestId, code: .parseError, message: "missing 'method'")
                await emitLog(instance: instance, started: started, method: "<missing>", requestId: requestId, paramsData: Data("{}".utf8), resultData: nil, errorMessage: "parseError")
                return resp
            }
            let paramsValue: Any = obj["params"] ?? [:]
            let paramsData: Data
            do {
                paramsData = try JSONSerialization.data(withJSONObject: paramsValue, options: [])
            } catch {
                let resp = encodeError(requestId: requestId, code: .parseError, message: "unserialisable params")
                await emitLog(instance: instance, started: started, method: method, requestId: requestId, paramsData: Data("{}".utf8), resultData: nil, errorMessage: "parseError")
                return resp
            }

            guard let handler = await instance.lookupHandler(method) else {
                let resp = encodeError(requestId: requestId, code: .methodNotFound, message: "no handler: \(method)")
                await emitLog(instance: instance, started: started, method: method, requestId: requestId, paramsData: paramsData, resultData: nil, errorMessage: "methodNotFound")
                return resp
            }

            // Section 6: register the in-flight request so a concurrent
            // `daemon.shutdown` can find this connection and emit a
            // `cancelled` envelope to it. The slot is cleared after the
            // handler completes (success OR error). Encode requestId
            // here so the actor never holds a non-Sendable `Any`.
            let requestIdJSON = encodeRequestId(requestId)
            await instance.markInFlight(fd: fd, requestIdJSON: requestIdJSON)
            let context = DaemonRequestContext()
            do {
                let resultData = try await DaemonRequestContext.$current.withValue(context) {
                    try await PerformanceTrace.$daemonErrorTimingSink.withValue({ context.recordErrorTiming($0) }) {
                        try await handler(paramsData)
                    }
                }
                await instance.clearInFlight(fd: fd)
                let resp = encodeResult(requestId: requestId, resultData: resultData, diagnostics: context.diagnostics)
                await emitLog(instance: instance, started: started, method: method, requestId: requestId, paramsData: paramsData, resultData: resultData, errorMessage: nil)
                return resp
            } catch {
                await instance.clearInFlight(fd: fd)
                let resp = encodeError(requestId: requestId, code: .handlerError, message: "\(error)", diagnostics: context.diagnostics, timing: context.errorTiming)
                await emitLog(instance: instance, started: started, method: method, requestId: requestId, paramsData: paramsData, resultData: nil, errorMessage: "\(error)")
                return resp
            }
        }

        /// Emit a single redacted/truncated log entry for the dispatched
        /// request via the instance's installed `logWriter`. No-op when no
        /// writer is configured. All payload routing through `DaemonLog`
        /// honors the `logFull` flag so the contract is centralized.
        private static func emitLog(
            instance: Instance,
            started: Date,
            method: String,
            requestId: Any?,
            paramsData: Data,
            resultData: Data?,
            errorMessage: String?
        ) async {
            guard let writer = await instance.currentLogWriter() else { return }
            let logFull = await instance.currentLogFull()
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            let paramsLog = String(
                data: DaemonLog.redactParams(method: method, paramsJSON: paramsData, logFull: logFull),
                encoding: .utf8
            ) ?? "{}"
            let resultLog: String? = resultData.flatMap { rd in
                String(data: DaemonLog.truncateResult(resultJSON: rd, logFull: logFull), encoding: .utf8)
            }
            let entry = DaemonLog.formatEntry(
                timestamp: started,
                method: method,
                requestId: requestId,
                durationMs: durationMs,
                paramsLog: paramsLog,
                resultLog: resultLog,
                errorLog: errorMessage
            )
            writer(entry)
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

        private static func readLine(fd: Int32) -> Data? {
            var bytes: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 1)
            while true {
                let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                    read(fd, ptr.baseAddress, 1)
                }
                if n <= 0 {
                    if bytes.isEmpty { return nil }
                    break
                }
                if buf[0] == 0x0A { break }
                bytes.append(buf[0])
            }
            return Data(bytes)
        }

        private static func writeLine(fd: Int32, line: Data) -> Bool {
            var payload = Data(line)
            payload.append(0x0A)
            return payload.withUnsafeBytes { rawBuf -> Bool in
                guard let base = rawBuf.baseAddress else { return false }
                var written = 0
                while written < rawBuf.count {
                    let n = write(fd, base.advanced(by: written), rawBuf.count - written)
                    if n <= 0 { return false }
                    written += n
                }
                return true
            }
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
