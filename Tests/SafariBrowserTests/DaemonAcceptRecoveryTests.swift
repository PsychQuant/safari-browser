import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

/// #178: `acceptLoop` returned on every negative `accept()`, so a transient
/// EINTR / ECONNABORTED / EMFILE left a daemon that was alive, still owned its
/// socket file, and never accepted another connection. These tests drive the
/// loop with a scripted `accept` so each errno class can be exercised without
/// exhausting the process's descriptors.
final class DaemonAcceptRecoveryTests: XCTestCase {

    // MARK: - Scripted accept

    /// Returns the scripted outcomes in order, then EBADF forever (the loop's
    /// normal "listener closed" exit), and counts calls.
    final class ScriptedAccept: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [(fd: Int32, errno: Int32)]
        private(set) var calls = 0
        init(_ outcomes: [(fd: Int32, errno: Int32)]) { self.outcomes = outcomes }
        var function: DaemonServer.AcceptFunction {
            { [self] _ in
                lock.lock(); defer { lock.unlock() }
                calls += 1
                return outcomes.isEmpty ? (-1, EBADF) : outcomes.removeFirst()
            }
        }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private func error(_ code: Int32) -> (fd: Int32, errno: Int32) { (-1, code) }

    // MARK: - Classification

    func testTransientErrorsRetryResourceErrorsBackOffAndDescriptorErrorsStop() {
        for code in [EINTR, ECONNABORTED, EAGAIN, EPROTO] {
            XCTAssertEqual(DaemonServer.acceptDisposition(errno: code), .retry, "errno \(code)")
        }
        for code in [EMFILE, ENFILE, ENOBUFS, ENOMEM] {
            XCTAssertEqual(DaemonServer.acceptDisposition(errno: code), .backoff, "errno \(code)")
        }
        // A closed or invalid listener must never be retried: after stop()
        // the descriptor number may already belong to something else.
        for code in [EBADF, ENOTSOCK, EINVAL, EOPNOTSUPP, EFAULT, 0, 9999] {
            XCTAssertEqual(DaemonServer.acceptDisposition(errno: code), .stop, "errno \(code)")
        }
    }

    func testBackoffGrowsAndIsBounded() {
        let delays = (0..<20).map { DaemonServer.acceptBackoff(attempt: $0) }
        XCTAssertEqual(delays.first, .milliseconds(10))
        for (a, b) in zip(delays, delays.dropFirst()) { XCTAssertLessThanOrEqual(a, b) }
        XCTAssertEqual(delays.last, .seconds(1), "backoff must cap at one second")
        XCTAssertEqual(DaemonServer.acceptBackoff(attempt: Int.max), .seconds(1), "no overflow at huge attempts")
    }

    // MARK: - The loop keeps serving after transient errors

    func testLoopServesTheNextClientAfterTransientErrors() async throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[1]) }
        let script = ScriptedAccept([error(EINTR), error(EMFILE), error(ECONNABORTED), (pair[0], 0)])
        let instance = DaemonServer.Instance()
        let sink = LogSink()
        await instance.setLogWriter({ sink.append($0) })

        await DaemonServer.Instance.acceptLoop(listenerFd: 99, instance: instance, accept: script.function)

        // The connection accepted after three failures got its handshake.
        var buffer = [UInt8](repeating: 0, count: 4096)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let n = read(pair[1], &buffer, buffer.count)
        XCTAssertGreaterThan(n, 0, "the client accepted after transient errors must receive the handshake")
        XCTAssertTrue(String(decoding: buffer.prefix(max(n, 0)), as: UTF8.self).contains("protocol"))
        XCTAssertEqual(script.callCount, 5, "three failures, one client, then the EBADF exit")

        let log = sink.all.joined(separator: "\n")
        XCTAssertTrue(log.contains("\"accept_error\""), log)
        XCTAssertTrue(log.contains("\"errno\":\(EMFILE)"), log)
        XCTAssertTrue(log.contains("\"accept_recovered\""), log)
        XCTAssertFalse(log.contains("\"errno\":\(EBADF)"), "the normal stop exit is not an error worth logging: \(log)")
    }

    func testClosedListenerStopsWithoutRetrying() async {
        let script = ScriptedAccept([error(EBADF)])
        await DaemonServer.Instance.acceptLoop(listenerFd: 99, instance: DaemonServer.Instance(), accept: script.function)
        XCTAssertEqual(script.callCount, 1)
    }

    func testImmediateRetriesCannotSpin() async {
        // An endless EINTR storm must fall back to the bounded backoff rather
        // than burning a core. Cancel after a short while and count calls.
        let storm: DaemonServer.AcceptFunction = { _ in (-1, EINTR) }
        let counter = ScriptedAccept([])
        let counting: DaemonServer.AcceptFunction = { fd in _ = counter.function(fd); return storm(fd) }
        let task = Task { await DaemonServer.Instance.acceptLoop(listenerFd: 99, instance: DaemonServer.Instance(), accept: counting) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await task.value
        XCTAssertLessThan(counter.callCount, 200,
                          "\(counter.callCount) accept calls in 300 ms — the loop is spinning instead of backing off")
    }

    func testCancellationDuringBackoffEndsTheLoopPromptly() async {
        let exhausted: DaemonServer.AcceptFunction = { _ in (-1, ENFILE) }
        let task = Task { await DaemonServer.Instance.acceptLoop(listenerFd: 99, instance: DaemonServer.Instance(), accept: exhausted) }
        try? await Task.sleep(for: .milliseconds(1500))   // well into the 1 s cap
        let cancelled = Date()
        task.cancel()
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 0.5,
                          "stop must not wait out a backoff sleep")
    }

    func testRepeatedErrorsAreRateLimitedInTheLog() {
        // Pure: a persistent error must not flood the log. (Driving 130 real
        // loop iterations would take minutes — the anti-spin backoff is the
        // point of the loop.) First occurrence, then every 64th.
        let logged = (1...200).filter { DaemonServer.shouldLogAcceptEvent(occurrence: $0) }
        XCTAssertEqual(logged, [1, 64, 128, 192])
    }

    func testTwoRepeatsOfTheSameErrorLogOnce() async {
        let script = ScriptedAccept([error(ECONNABORTED), error(ECONNABORTED)])
        let instance = DaemonServer.Instance()
        let sink = LogSink()
        await instance.setLogWriter({ sink.append($0) })
        await DaemonServer.Instance.acceptLoop(listenerFd: 99, instance: instance, accept: script.function)
        XCTAssertEqual(sink.all.filter { $0.contains("\"accept_error\"") }.count, 1, sink.all.joined(separator: "\n"))
    }

    // MARK: - Connection setup failure is diagnosed (the #175 branch)

    func testConnectionSetupFailureIsClosedAndLogged() async {
        // A pipe is not a socket: SO_NOSIGPIPE fails with ENOTSOCK, exactly the
        // branch #175 added. The fd must be closed and the failure recorded.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[1]) }
        let script = ScriptedAccept([(fds[0], 0)])
        let instance = DaemonServer.Instance()
        let sink = LogSink()
        await instance.setLogWriter({ sink.append($0) })
        await DaemonServer.Instance.acceptLoop(listenerFd: 99, instance: instance, accept: script.function)
        XCTAssertEqual(fcntl(fds[0], F_GETFD), -1, "the unprotected descriptor must be closed")
        let log = sink.all.joined(separator: "\n")
        XCTAssertTrue(log.contains("\"connection_setup_failed\""), log)
        XCTAssertTrue(log.contains("\"errno\":\(ENOTSOCK)"), log)
    }

    // MARK: - Log format carries no private data

    func testEventLineHasOnlyEventErrnoDispositionAndCount() throws {
        let line = DaemonLog.formatEvent(timestamp: Date(timeIntervalSince1970: 0), event: "accept_error",
                                         errno: EMFILE, disposition: "backoff", count: 3)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["timestamp", "event", "errno", "disposition", "count"])
        XCTAssertEqual(object["errno"] as? Int, Int(EMFILE))
        XCTAssertFalse(line.contains("\n"), "one JSON line per event")
    }
}
