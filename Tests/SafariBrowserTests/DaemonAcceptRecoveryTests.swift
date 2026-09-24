import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

/// #178: `acceptLoop` returned on every negative `accept()`, so a transient
/// EINTR / ECONNABORTED / EMFILE left a daemon that was alive, still owned its
/// socket file, and never accepted another connection. These tests drive the
/// loop with a scripted environment so each errno class can be exercised
/// without exhausting the process's descriptors.
final class DaemonAcceptRecoveryTests: XCTestCase {

    // MARK: - Scripted environment

    /// Reports the listener ready while scripted outcomes remain, then asks
    /// the loop to wake (the normal `stop()` path). Counts calls.
    final class ScriptedListener: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [(fd: Int32, errno: Int32)]
        private var acceptCalls = 0
        private var sleeps: [Duration] = []
        private let beforeAccept: @Sendable (Int) -> Void
        let clock: FakeClock

        init(_ outcomes: [(fd: Int32, errno: Int32)], clock: FakeClock = FakeClock(),
             beforeAccept: @escaping @Sendable (Int) -> Void = { _ in }) {
            self.outcomes = outcomes
            self.clock = clock
            self.beforeAccept = beforeAccept
        }

        /// `realSleep: false` records backoff delays instead of waiting them
        /// out, so hundreds of iterations run instantly.
        func environment(realSleep: Bool = true) -> DaemonServer.AcceptEnvironment {
            DaemonServer.AcceptEnvironment(
                accept: { [self] _ in
                    let call: Int = lock.withLock { acceptCalls += 1; return acceptCalls }
                    beforeAccept(call)
                    return lock.withLock { outcomes.isEmpty ? (-1, EBADF) : outcomes.removeFirst() }
                },
                wait: { [self] _, _ in lock.withLock { outcomes.isEmpty ? .wake : .ready } },
                sleep: { [self] delay in
                    lock.withLock { sleeps.append(delay) }
                    if realSleep { try await Task.sleep(for: delay) }
                },
                now: { [clock] in clock.now }
            )
        }
        var acceptCount: Int { lock.withLock { acceptCalls } }
        var recordedSleeps: [Duration] { lock.withLock { sleeps } }
    }

    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { instant } }
        func advance(by d: Duration) { lock.withLock { instant = instant.advanced(by: d) } }
    }

    final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
        /// What the production writer puts on disk: the lines concatenated.
        var file: String { all.joined() }
        func events(_ name: String) -> [[String: Any]] {
            file.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }.filter { $0["event"] as? String == name }
        }
    }

    /// Real descriptors for a loop that owns and closes them: a placeholder
    /// listener socket and a wake pipe. The test keeps the wake write end.
    struct LoopFds { let listener: Int32; let wakeRead: Int32; let wakeWrite: Int32 }

    private func makeLoopFds() throws -> LoopFds {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        var wake: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&wake), 0)
        return LoopFds(listener: listener, wakeRead: wake[0], wakeWrite: wake[1])
    }

    private func isOpen(_ fd: Int32) -> Bool { fcntl(fd, F_GETFD) != -1 }

    private func error(_ code: Int32) -> (fd: Int32, errno: Int32) { (-1, code) }

    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    private func runLoop(_ env: DaemonServer.AcceptEnvironment, instance: DaemonServer.Instance = .init()) async throws -> LoopFds {
        let fds = try makeLoopFds()
        await DaemonServer.Instance.acceptLoop(listenerFd: fds.listener, wakeFd: fds.wakeRead,
                                               instance: instance, environment: env)
        close(fds.wakeWrite)
        return fds
    }

    // MARK: - Classification

    func testTransientErrorsRetryResourceErrorsBackOffAndDescriptorErrorsStop() {
        for code in [EINTR, ECONNABORTED, EAGAIN, EPROTO] {
            XCTAssertEqual(DaemonServer.acceptDisposition(errno: code), .retry, "errno \(code)")
        }
        for code in [EMFILE, ENFILE, ENOBUFS, ENOMEM] {
            XCTAssertEqual(DaemonServer.acceptDisposition(errno: code), .backoff, "errno \(code)")
        }
        // A closed or invalid listener must never be retried.
        for code in [EBADF, ENOTSOCK, EINVAL, EOPNOTSUPP, EFAULT] {
            XCTAssertEqual(DaemonServer.acceptDisposition(errno: code), .stop, "errno \(code)")
        }
        // Verify R2: an errno outside both lists does not prove the listener
        // is gone. Stopping on it recreated #178's alive-but-deaf daemon.
        for code in [ECONNRESET, ETIMEDOUT, 0, 9999] {
            XCTAssertEqual(DaemonServer.acceptDisposition(errno: code), .backoff, "errno \(code)")
        }
    }

    func testBackoffGrowsAndIsBounded() {
        let delays = (0..<20).map { DaemonServer.acceptBackoff(attempt: $0) }
        XCTAssertEqual(delays.first, .milliseconds(10))
        for (a, b) in zip(delays, delays.dropFirst()) { XCTAssertLessThanOrEqual(a, b) }
        XCTAssertEqual(delays.last, .seconds(1), "backoff must cap at one second")
        XCTAssertEqual(DaemonServer.acceptBackoff(attempt: Int.max), .seconds(1), "no overflow at huge attempts")
    }

    // MARK: - Incident bookkeeping (pure)

    func testAlternatingErrnosShareOneRateLimitedStreak() {
        // Verify R1: keying the streak on the exact errno let EINTR/ECONNABORTED
        // alternation log every single failure.
        var incident = DaemonServer.AcceptIncident()
        let t = ContinuousClock.now
        let logged = (1...200).filter { i in
            incident.recordFailure(errno: i.isMultiple(of: 2) ? EINTR : ECONNABORTED, at: t).log
        }
        XCTAssertEqual(logged, [1, 64, 128, 192])
    }

    func testImmediateRetriesTurnIntoBackoffAfterTheCap() {
        var incident = DaemonServer.AcceptIncident()
        let t = ContinuousClock.now
        let steps = (1...18).map { _ in incident.recordFailure(errno: EINTR, at: t) }
        XCTAssertTrue(steps.prefix(DaemonServer.maxImmediateAcceptRetries).allSatisfy { $0.disposition == .retry })
        XCTAssertEqual(steps[16].disposition, .backoff)
        XCTAssertEqual(steps[16].delay, .milliseconds(10))
        XCTAssertEqual(steps[17].delay, .milliseconds(20))
    }

    func testAQuietGapStartsANewIncident() {
        // Verify R1: counters reset only on a successful accept, so one early
        // storm sent every later isolated error through backoff, unlogged.
        var incident = DaemonServer.AcceptIncident()
        let t = ContinuousClock.now
        for _ in 1...20 { _ = incident.recordFailure(errno: EINTR, at: t) }
        let soon = incident.recordFailure(errno: EINTR, at: t.advanced(by: .seconds(1)))
        XCTAssertEqual(soon.disposition, .backoff, "a failure inside the gap is still the same incident")
        let later = incident.recordFailure(errno: EINTR, at: t.advanced(by: .seconds(1) + DaemonServer.AcceptIncident.quietGap))
        XCTAssertEqual(later.disposition, .retry, "after a quiet gap the error gets its immediate retry")
        XCTAssertTrue(later.log, "and is logged as the first failure of a new incident")
        XCTAssertEqual(incident.streak, 1)
    }

    func testStopClassFailuresAreAlwaysLogged() {
        var incident = DaemonServer.AcceptIncident()
        let t = ContinuousClock.now
        for _ in 1...3 { _ = incident.recordFailure(errno: ECONNABORTED, at: t) }
        let stop = incident.recordFailure(errno: EBADF, at: t)
        XCTAssertEqual(stop.disposition, .stop)
        XCTAssertTrue(stop.log, "the loop is about to end — that is never rate limited")
    }

    func testSuccessReportsAndClearsTheStreak() {
        var incident = DaemonServer.AcceptIncident()
        XCTAssertNil(incident.recordSuccess(), "no streak, nothing to report")
        let t = ContinuousClock.now
        _ = incident.recordFailure(errno: EINTR, at: t)
        _ = incident.recordFailure(errno: EMFILE, at: t)
        let recovered = incident.recordSuccess()
        XCTAssertEqual(recovered?.streak, 2)
        XCTAssertEqual(recovered?.errno, EMFILE)
        XCTAssertNil(incident.recordSuccess())
        XCTAssertEqual(incident.recordFailure(errno: EINTR, at: t).disposition, .retry)
    }

    // MARK: - The loop keeps serving after transient errors

    func testLoopServesTheNextClientAfterTransientErrors() async throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[1]) }
        let script = ScriptedListener([error(EINTR), error(EMFILE), error(ECONNABORTED), (pair[0], 0)])
        let instance = DaemonServer.Instance()
        let sink = LogSink()
        await instance.setLogWriter({ sink.append($0) })

        let fds = try await runLoop(script.environment(), instance: instance)

        var buffer = [UInt8](repeating: 0, count: 4096)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let n = read(pair[1], &buffer, buffer.count)
        XCTAssertGreaterThan(n, 0, "the client accepted after transient errors must receive the handshake")
        XCTAssertTrue(String(decoding: buffer.prefix(max(n, 0)), as: UTF8.self).contains("protocol"))
        XCTAssertEqual(script.acceptCount, 4, "three failures, one client — the wake ends the loop, not an accept")

        XCTAssertEqual(sink.events("accept_error").first?["errno"] as? Int, Int(EINTR), sink.file)
        XCTAssertEqual(sink.events("accept_recovered").first?["count"] as? Int, 3, sink.file)
        XCTAssertFalse(isOpen(fds.listener), "the loop owns the listener and closes it on the way out")
        XCTAssertFalse(isOpen(fds.wakeRead))
        // The served descriptor belongs to a detached handler: end it and wait
        // for the handler to close it, so nothing outlives the test.
        shutdown(pair[1], SHUT_RDWR)
        XCTAssertTrue(waitUntil { !self.isOpen(pair[0]) }, "the handler must close the served descriptor")
    }

    func testUnknownErrnoBacksOffAndServesTheNextClient() async throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[1]) }
        let script = ScriptedListener([error(ECONNRESET), (pair[0], 0)])
        _ = try await runLoop(script.environment(realSleep: false))
        XCTAssertEqual(script.acceptCount, 2, "an unlisted errno must not end the loop")
        XCTAssertEqual(script.recordedSleeps, [.milliseconds(10)])
    }

    func testClosedListenerStopsWithoutRetryingAndSaysSo() async throws {
        let script = ScriptedListener([error(EBADF)])
        let instance = DaemonServer.Instance()
        let sink = LogSink()
        await instance.setLogWriter({ sink.append($0) })
        _ = try await runLoop(script.environment(), instance: instance)
        XCTAssertEqual(script.acceptCount, 1)
        // stop() no longer closes the listener, so EBADF is never the normal
        // exit — it is always worth a line.
        XCTAssertEqual(sink.events("accept_error").first?["disposition"] as? String, "stop", sink.file)
    }

    func testImmediateRetriesCannotSpin() async throws {
        let counter = ScriptedListener([])
        let env = DaemonServer.AcceptEnvironment(
            accept: { fd in _ = counter.environment().accept(fd); return (-1, EINTR) },
            wait: { _, _ in .ready })
        let fds = try makeLoopFds()
        defer { close(fds.wakeWrite) }
        let task = Task {
            await DaemonServer.Instance.acceptLoop(listenerFd: fds.listener, wakeFd: fds.wakeRead,
                                                   instance: DaemonServer.Instance(), environment: env)
        }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await task.value
        XCTAssertLessThan(counter.acceptCount, 200,
                          "\(counter.acceptCount) accept calls in 300 ms — the loop is spinning instead of backing off")
    }

    func testCancellationDuringBackoffEndsTheLoopPromptly() async throws {
        let env = DaemonServer.AcceptEnvironment(accept: { _ in (-1, ENFILE) }, wait: { _, _ in .ready })
        let fds = try makeLoopFds()
        defer { close(fds.wakeWrite) }
        let task = Task {
            await DaemonServer.Instance.acceptLoop(listenerFd: fds.listener, wakeFd: fds.wakeRead,
                                                   instance: DaemonServer.Instance(), environment: env)
        }
        try? await Task.sleep(for: .milliseconds(1500))   // well into the 1 s cap
        let cancelled = Date()
        task.cancel()
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 0.5, "stop must not wait out a backoff sleep")
        XCTAssertFalse(isOpen(fds.listener))
    }

    func testPersistentAlternatingErrorsLogFirstAnd64thInTheLoop() async throws {
        // Verify R1: the 1-then-every-64th rule was only tested as a pure
        // function; this drives 130 real iterations (backoff recorded, not slept).
        let codes: [Int32] = [ECONNABORTED, EINTR, EMFILE]
        let script = ScriptedListener((0..<130).map { error(codes[$0 % 3]) })
        let instance = DaemonServer.Instance()
        let sink = LogSink()
        await instance.setLogWriter({ sink.append($0) })
        _ = try await runLoop(script.environment(realSleep: false), instance: instance)
        XCTAssertEqual(sink.events("accept_error").compactMap { $0["count"] as? Int }, [1, 64, 128], sink.file)
        XCTAssertFalse(script.recordedSleeps.isEmpty, "the storm must reach the backoff path")
    }

    func testAQuietGapGivesALaterErrorItsImmediateRetryInTheLoop() async throws {
        let clock = FakeClock()
        let storm = DaemonServer.maxImmediateAcceptRetries + 1
        let script = ScriptedListener((0...storm).map { _ in error(EINTR) }, clock: clock) { call in
            if call == storm + 1 { clock.advance(by: DaemonServer.AcceptIncident.quietGap + .seconds(1)) }
        }
        _ = try await runLoop(script.environment(realSleep: false))
        XCTAssertEqual(script.recordedSleeps, [.milliseconds(10)],
                       "only the storm's overflow backs off; the error after the gap retries immediately")
    }

    // MARK: - Connection setup failure is diagnosed (the #175 branch)

    func testConnectionSetupFailureIsClosedLoggedAndRecoveryReported() async throws {
        // A pipe is not a socket: SO_NOSIGPIPE fails with ENOTSOCK, exactly the
        // branch #175 added. The fd must be closed and the failure recorded;
        // the next good connection closes the incident.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[1]) }
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[1]) }
        let script = ScriptedListener([(fds[0], 0), (pair[0], 0)])
        let instance = DaemonServer.Instance()
        let sink = LogSink()
        await instance.setLogWriter({ sink.append($0) })
        _ = try await runLoop(script.environment(), instance: instance)
        XCTAssertFalse(isOpen(fds[0]), "the unprotected descriptor must be closed")
        XCTAssertEqual(sink.events("connection_setup_failed").first?["errno"] as? Int, Int(ENOTSOCK), sink.file)
        XCTAssertEqual(sink.events("connection_setup_recovered").first?["count"] as? Int, 1, sink.file)
    }

    // MARK: - stop() and the listener it no longer closes

    func testTheLoopClosesItsOwnListenerWhenWoken() async throws {
        // The real wait: a listening socket and the wake pipe. Closing the
        // wake write end (what stop() does) must end the loop, and the loop —
        // not stop() — closes the listener. That ownership is what makes a
        // retry on a closed or reused descriptor impossible.
        let path = "\(NSTemporaryDirectory())acc-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let fds = try makeLoopFds()
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in path.utf8.enumerated() { buf[i] = b }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fds.listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fds.listener, 4), 0)
        let task = Task {
            await DaemonServer.Instance.acceptLoop(listenerFd: fds.listener, wakeFd: fds.wakeRead,
                                                   instance: DaemonServer.Instance())
        }
        try await Task.sleep(for: .milliseconds(100))   // parked in poll()
        let woken = Date()
        close(fds.wakeWrite)
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(woken), 0.5)
        XCTAssertFalse(isOpen(fds.listener))
        XCTAssertFalse(isOpen(fds.wakeRead))
    }

    func testStopDuringABackoffStormReturnsAtOnceAndTheLoopEnds() async throws {
        // Verify R2: drive the real Instance.stop() while its loop is backing
        // off. stop() must not wait on the loop, and the loop must neither keep
        // retrying nor keep the listener.
        final class Probe: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            var listener: Int32 = -1
        }
        let probe = Probe()
        let env = DaemonServer.AcceptEnvironment(
            accept: { fd in probe.lock.withLock { probe.calls += 1; probe.listener = fd }; return (-1, ENFILE) },
            wait: { _, _ in .ready })
        let path = "\(NSTemporaryDirectory())acc-\(UUID().uuidString.prefix(8)).sock"
        let server = DaemonServer.Instance()
        try await server.start(socketPath: path, environment: env)
        XCTAssertTrue(waitUntil { probe.lock.withLock { probe.calls } >= 3 }, "the storm must reach backoff")
        let stopping = Date()
        await server.stop()
        XCTAssertLessThan(Date().timeIntervalSince(stopping), 0.2, "stop() must not wait out a backoff or the loop")
        let listener = probe.lock.withLock { probe.listener }
        XCTAssertTrue(waitUntil { !self.isOpen(listener) }, "the loop must close its listener after stop()")
        let settled = probe.lock.withLock { probe.calls }
        usleep(300_000)
        XCTAssertEqual(probe.lock.withLock { probe.calls }, settled, "no accept() after the loop ended")
    }

    func testAWaitThatNeverWakesStillEndsOnceCancelled() async throws {
        // Belt and braces for the wake pipe: if its write end ever leaked to a
        // child, closing ours would not wake poll(). The real wait times out
        // periodically, so a cancelled loop still notices.
        let fds = try makeLoopFds()
        let path = "\(NSTemporaryDirectory())acc-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path); close(fds.wakeWrite) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in path.utf8.enumerated() { buf[i] = b }
        }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fds.listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(Darwin.listen(fds.listener, 4), 0)
        let task = Task.detached {
            await DaemonServer.Instance.acceptLoop(listenerFd: fds.listener, wakeFd: fds.wakeRead,
                                                   instance: DaemonServer.Instance())
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = Date()
        task.cancel()                                   // the wake write end stays open
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), Double(DaemonServer.acceptWaitSliceMilliseconds) / 1000 + 0.5)
        XCTAssertFalse(isOpen(fds.listener))
    }

    func testSetupFailuresAfterAQuietGapStartANewStreak() {
        var streak = DaemonServer.SetupFailureStreak()
        let t = ContinuousClock.now
        XCTAssertEqual(streak.recordFailure(at: t).count, 1)
        XCTAssertEqual(streak.recordFailure(at: t).count, 2)
        let later = streak.recordFailure(at: t.advanced(by: DaemonServer.AcceptIncident.quietGap + .seconds(1)))
        XCTAssertEqual(later.count, 1)
        XCTAssertTrue(later.log)
        XCTAssertEqual(streak.recordSuccess(), 1)
        XCTAssertNil(streak.recordSuccess())
    }

    func testStopReturnsPromptlyAndTheSocketCanBeServedAgain() async throws {
        let name = "acc-\(UUID().uuidString.prefix(8))"
        let path = DaemonClient.socketPath(name: name)
        let server = DaemonServer.Instance()
        await server.register("echo") { $0 }
        for round in 1...2 {
            try await server.start(socketPath: path)
            let reply = try await DaemonClient.sendRequest(name: name, method: "echo",
                                                           params: Data("{\"r\":\(round)}".utf8), requestId: round)
            XCTAssertEqual(String(decoding: reply, as: UTF8.self), "{\"r\":\(round)}",
                           "an accepted client must be served with blocking I/O (round \(round))")
            let stopping = Date()
            await server.stop()
            XCTAssertLessThan(Date().timeIntervalSince(stopping), 1.0, "stop() returns without waiting for the accept loop")
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    // MARK: - Log format carries no private data

    func testEventLineIsOneTerminatedJSONLineWithOnlyItsFields() throws {
        let line = DaemonLog.formatEvent(timestamp: Date(timeIntervalSince1970: 0), event: "accept_error",
                                         errno: EMFILE, disposition: "backoff", count: 3)
        // Verify R1: the writer appends lines verbatim, so a line without its
        // terminator runs into the next one on disk.
        XCTAssertTrue(line.hasSuffix("\n"), "the production writer does not add a terminator")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "one line per event")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["timestamp", "event", "errno", "disposition", "count"])
        XCTAssertEqual(object["errno"] as? Int, Int(EMFILE))
    }
}
