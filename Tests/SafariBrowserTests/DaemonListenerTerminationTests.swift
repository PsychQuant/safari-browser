import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonListenerTerminationTests: XCTestCase {
    private func socketPath() -> String {
        NSTemporaryDirectory() + "l198-" + String(UUID().uuidString.prefix(8)) + ".sock"
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    func testPermanentAcceptCleansSocketWithoutExplicitStop() async throws {
        let path = socketPath(), server = DaemonServer.Instance()
        let attempted = expectation(description: "permanent accept failure")
        let environment = DaemonServer.AcceptEnvironment(accept: { _ in
            attempted.fulfill()
            return (-1, EBADF)
        }, wait: { _, _ in .ready })
        try await server.start(socketPath: path, environment: environment)
        await fulfillment(of: [attempted], timeout: 1)
        let removed = await waitUntil { !FileManager.default.fileExists(atPath: path) }
        XCTAssertTrue(removed, "permanent listener failure must clean its socket without an explicit stop")
        await server.stop()
    }

    func testBlockedTerminalWriterDoesNotRetainSocket() async throws {
        let path = socketPath(), server = DaemonServer.Instance()
        let entered = expectation(description: "terminal writer blocked")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await server.setLogWriter { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        try await server.start(socketPath: path, environment: .init(wait: { _, _ in .failed(EINVAL) }))
        await fulfillment(of: [entered], timeout: 1)
        let removed = await waitUntil { !FileManager.default.fileExists(atPath: path) }
        XCTAssertTrue(removed, "blocked terminal logging must not retain the failed listener's socket")
        await server.stop()
        release.signal()
    }

    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptors: (listener: Int32, wakeRead: Int32, wakeObserver: Int32)?
        private var values: [DaemonServer.ListenerFailure] = []
        private var clean = false

        func capture(listener: Int32, wakeRead: Int32) {
            lock.withLock {
                guard descriptors == nil else { return }
                descriptors = (listener, wakeRead, dup(wakeRead))
            }
        }

        func record(_ failure: DaemonServer.ListenerFailure, path: String) {
            lock.withLock {
                values.append(failure)
                guard let fds = descriptors else { return }
                var pipeState = pollfd(fd: fds.wakeObserver, events: Int16(POLLIN), revents: 0)
                let writeEndClosed = poll(&pipeState, 1, 0) == 1 && pipeState.revents & Int16(POLLHUP) != 0
                clean = fcntl(fds.listener, F_GETFD) == -1 && fcntl(fds.wakeRead, F_GETFD) == -1
                    && writeEndClosed && !FileManager.default.fileExists(atPath: path)
            }
        }

        var failures: [DaemonServer.ListenerFailure] { lock.withLock { values } }
        var allResourcesReleased: Bool { lock.withLock { clean } }
        deinit { if let fds = descriptors, fds.wakeObserver >= 0 { close(fds.wakeObserver) } }
    }

    private actor Gate {
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() { opened = true; waiter?.resume(); waiter = nil }
    }

    func testPermanentAcceptNotifiesOnceAfterClosingAllOwnedResources() async throws {
        let server = DaemonServer.Instance(), path = socketPath(), observed = Observation()
        let delivered = expectation(description: "accept failure delivered once")
        delivered.assertForOverFulfill = true
        let environment = DaemonServer.AcceptEnvironment(accept: { _ in (-1, EBADF) }, wait: { listener, wake in
            observed.capture(listener: listener, wakeRead: wake)
            return .ready
        })
        try await server.start(socketPath: path, environment: environment) { failure in
            observed.record(failure, path: path)
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 1)
        await server.stop()
        await server.stop()
        XCTAssertEqual(observed.failures, [.init(operation: .accept, errno: EBADF)])
        XCTAssertTrue(observed.allResourcesReleased, "listener, both wake ends, and socket must be released before callback")
        XCTAssertEqual(observed.failures.first?.description, "listener accept failed: errno=9")
    }

    func testPermanentPollNotifiesWhileTerminalWriterRemainsBlocked() async throws {
        let server = DaemonServer.Instance(), path = socketPath(), observed = Observation()
        let writerEntered = expectation(description: "terminal writer blocked")
        let notified = expectation(description: "poll failure delivered independently of writer")
        let writerDone = expectation(description: "writer released")
        let release = DispatchSemaphore(value: 0)
        let enteredGate = Gate()
        defer { release.signal() }
        await server.setLogWriter { _ in
            writerEntered.fulfill()
            Task { await enteredGate.open() }
            _ = release.wait(timeout: .now() + 5)
            writerDone.fulfill()
        }
        let environment = DaemonServer.AcceptEnvironment(wait: { listener, wake in
            observed.capture(listener: listener, wakeRead: wake)
            return .failed(EINVAL)
        }, beforeFailureNotification: { await enteredGate.wait() })
        try await server.start(socketPath: path, environment: environment) { failure in
            observed.record(failure, path: path)
            notified.fulfill()
        }
        await fulfillment(of: [writerEntered, notified], timeout: 1)
        XCTAssertEqual(observed.failures, [.init(operation: .poll, errno: EINVAL)])
        XCTAssertTrue(observed.allResourcesReleased, "blocked writer cannot retain any listener resources")
        await server.stop()
        release.signal()
        await fulfillment(of: [writerDone], timeout: 1)
    }

    func testNormalWakeAndRecoverableAcceptErrorsDoNotNotifyFailure() async throws {
        let server = DaemonServer.Instance(), path = socketPath()
        let unexpected = expectation(description: "normal completion is not permanent failure")
        unexpected.isInverted = true
        let script = DaemonAcceptRecoveryTests.ScriptedListener([(-1, EINTR), (-1, EMFILE), (-1, EAGAIN)])
        try await server.start(socketPath: path, environment: script.environment(realSleep: false)) { _ in
            unexpected.fulfill()
        }
        await fulfillment(of: [unexpected], timeout: 0.15)
        XCTAssertEqual(script.acceptCount, 3)
        await server.stop()
    }

    func testCancellationDuringPollDoesNotNotifyPermanentFailure() async throws {
        let server = DaemonServer.Instance(), path = socketPath()
        let waiting = expectation(description: "poll entered")
        let returned = expectation(description: "poll returned after cancellation")
        let unexpected = expectation(description: "cancelled poll is not permanent failure")
        unexpected.isInverted = true
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        try await server.start(socketPath: path, environment: .init(wait: { _, _ in
            waiting.fulfill()
            _ = release.wait(timeout: .now() + 5)
            returned.fulfill()
            return .failed(EINVAL)
        })) { _ in unexpected.fulfill() }
        await fulfillment(of: [waiting], timeout: 1)
        await server.stop()
        release.signal()
        await fulfillment(of: [returned, unexpected], timeout: 0.15)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testDelayedOldNotificationCannotCleanRestartedListener() async throws {
        let server = DaemonServer.Instance(), name = "l198-" + String(UUID().uuidString.prefix(8))
        let path = DaemonClient.socketPath(name: name), gate = Gate()
        let delayed = expectation(description: "old failure paused after cleanup")
        let delivered = expectation(description: "captured old callback delivered once")
        delivered.assertForOverFulfill = true
        let newFailure = expectation(description: "new listener must remain running")
        newFailure.isInverted = true
        let environment = DaemonServer.AcceptEnvironment(wait: { _, _ in .failed(EINVAL) },
            beforeFailureNotification: { delayed.fulfill(); await gate.wait() })
        try await server.start(socketPath: path, environment: environment) { failure in
            XCTAssertEqual(failure, .init(operation: .poll, errno: EINVAL))
            delivered.fulfill()
        }
        await fulfillment(of: [delayed], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "cleanup precedes the scheduling hook")
        await server.stop()
        try await server.start(socketPath: path) { _ in newFailure.fulfill() }
        await gate.open()
        await fulfillment(of: [delivered, newFailure], timeout: 0.15)
        do {
            let reply = try await DaemonClient.sendRequest(name: name, method: "daemon.status", params: Data("{}".utf8), requestId: 198, timeout: 2)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        } catch { await server.stop(); throw error }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        await server.stop()
    }

    func testStoppedGenerationCannotCleanNewListenerWhenOldAcceptReturnsFailure() async throws {
        let server = DaemonServer.Instance(), name = "l198-" + String(UUID().uuidString.prefix(8))
        let path = DaemonClient.socketPath(name: name)
        let accepting = expectation(description: "old accept entered")
        let returned = expectation(description: "old accept returned")
        let unexpected = expectation(description: "revoked generation cannot notify")
        unexpected.isInverted = true
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let environment = DaemonServer.AcceptEnvironment(accept: { _ in
            accepting.fulfill()
            _ = release.wait(timeout: .now() + 5)
            returned.fulfill()
            return (-1, EBADF)
        }, wait: { _, _ in .ready })
        try await server.start(socketPath: path, environment: environment) { _ in unexpected.fulfill() }
        await fulfillment(of: [accepting], timeout: 1)
        await server.stop()
        try await server.start(socketPath: path)
        release.signal()
        await fulfillment(of: [returned, unexpected], timeout: 0.15)
        do {
            let reply = try await DaemonClient.sendRequest(name: name, method: "daemon.status", params: Data("{}".utf8), requestId: 199, timeout: 2)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        } catch { await server.stop(); throw error }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        await server.stop()
    }

}
