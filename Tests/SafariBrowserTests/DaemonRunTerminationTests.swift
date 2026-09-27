import Darwin
import Foundation
import XCTest
import ArgumentParser
@testable import SafariBrowser

final class DaemonRunTerminationTests: XCTestCase {
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private func paths() -> (socket: String, pid: String) {
        let base = NSTemporaryDirectory() + "r198-" + String(UUID().uuidString.prefix(8))
        return (base + ".sock", base + ".pid")
    }

    private func removed(_ path: String) async -> Bool {
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !FileManager.default.fileExists(atPath: path)
    }

    func testPermanentListenerFailureCleansOuterPidWithoutIdleTimeout() async throws {
        let server = DaemonServeLoop.Server(), p = paths()
        defer { unlink(p.socket); unlink(p.pid) }
        // Failure may be delivered during start or immediately afterward.
        do {
            try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600,
                                   acceptEnvironment: .init(wait: { _, _ in .failed(EINVAL) }))
        } catch { XCTAssertTrue(error is DaemonServer.ListenerFailure) }
        let pidRemoved = await removed(p.pid)
        XCTAssertTrue(pidRemoved, "permanent listener failure must clean the outer PID without waiting for idle timeout")
        await server.stop()
    }

    func testStopDuringStartupPreventsLateBind() async throws {
        let server = DaemonServeLoop.Server(), p = paths(), gate = Gate()
        let entered = expectation(description: "startup paused before bind")
        let stopAccepted = expectation(description: "stop accepted")
        defer { unlink(p.socket); unlink(p.pid) }
        let starting = Task {
            try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600,
                                   lifecycle: .init(beforeListenerStart: { entered.fulfill(); await gate.wait() },
                                                    observe: { if case .beganStop = $0 { stopAccepted.fulfill() } }))
        }
        await fulfillment(of: [entered], timeout: 1)
        let stopping = Task { await server.stop() }
        // The gate deliberately ignores cancellation; stop must wait for this
        // startup to finish and the resumed startup must not bind afterward.
        await fulfillment(of: [stopAccepted], timeout: 1)
        await gate.open()
        _ = await starting.result
        await stopping.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.socket), "a stop accepted during startup must prevent a late bind")
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.pid))
        await server.stop()
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func set(_ value: T) { lock.withLock { self.value = value } }
        func get() -> T { lock.withLock { value } }
    }

    private func assertHealthy(socket: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socket.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        _ = try TestUnixSocket.readLine(fd: fd) // bounded handshake
        try TestUnixSocket.writeLine(fd: fd, line: #"{"method":"daemon.status","params":{},"requestId":198}"#)
        let response = Data(try TestUnixSocket.readLine(fd: fd).utf8)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertNotNil(reply["result"])
        XCTAssertEqual(reply["requestId"] as? Int, 198)
    }

    func testConcurrentStartsShareStartupAndHealthyListener() async throws {
        let server = DaemonServeLoop.Server(), p = paths(), gate = Gate()
        let entered = expectation(description: "only one startup")
        entered.assertForOverFulfill = true
        let joined = expectation(description: "second start joined startup")
        let completed = expectation(description: "both starts complete")
        completed.expectedFulfillmentCount = 2
        let lifecycle = DaemonServeLoop.LifecycleEnvironment(beforeListenerStart: {
            entered.fulfill(); await gate.wait()
        }, observe: { if case .joinedStartup = $0 { joined.fulfill() } })
        let results = Box<[Bool]>([])
        let a = Task {
            do { try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600, lifecycle: lifecycle) }
            catch { results.set([false]) }
            completed.fulfill()
        }
        await fulfillment(of: [entered], timeout: 1)
        let b = Task {
            do { try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600, lifecycle: lifecycle) }
            catch { results.set([false]) }
            completed.fulfill()
        }
        await fulfillment(of: [joined], timeout: 1)
        await gate.open()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(results.get().isEmpty)
        try assertHealthy(socket: p.socket)
        await server.stop()
        a.cancel(); b.cancel()
    }

    func testFailureDuringStartupPreservesTypedReasonAndNeverRestoresRunning() async throws {
        let server = DaemonServeLoop.Server(), p = paths(), gate = Gate()
        let beforeFailure = Gate()
        let bound = expectation(description: "bound but startup not finished")
        let accepted = expectation(description: "failure accepted while starting")
        let finished = expectation(description: "startup throws after cleanup")
        let errorBox = Box<DaemonServer.ListenerFailure?>(nil)
        let task = Task {
            do {
                try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600,
                                       acceptEnvironment: .init(wait: { _, _ in .failed(EINVAL) },
                                                                beforeFailureNotification: { await beforeFailure.wait() }),
                                       lifecycle: .init(afterListenerStart: { bound.fulfill(); await gate.wait() },
                                                        observe: { if case .beganStop = $0 { accepted.fulfill() } }))
                XCTFail("failed startup must throw")
            } catch { errorBox.set(error as? DaemonServer.ListenerFailure) }
            finished.fulfill()
        }
        await fulfillment(of: [bound], timeout: 1)
        await beforeFailure.open()
        await fulfillment(of: [accepted], timeout: 1)
        await gate.open()
        await fulfillment(of: [finished], timeout: 2)
        let expected = DaemonServer.ListenerFailure(operation: .poll, errno: EINVAL)
        XCTAssertEqual(errorBox.get(), expected)
        let reason = await server.waitUntilStopped()
        XCTAssertEqual(reason, .listenerFailed(expected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.socket))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.pid))
        try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600)
        try assertHealthy(socket: p.socket)
        await server.stop()
        task.cancel()
    }

    func testAllRegisteredWaitersReceiveFailureOnlyAfterCleanup() async throws {
        let server = DaemonServeLoop.Server(), p = paths(), failureGate = Gate(), cleanupGate = Gate()
        let registered = expectation(description: "three registered waiters")
        registered.expectedFulfillmentCount = 3
        let cleaning = expectation(description: "teardown begun")
        let stopJoined = expectation(description: "ordinary stop joined failure cleanup")
        let finished = expectation(description: "three completed waiters")
        finished.expectedFulfillmentCount = 3
        try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600,
                               acceptEnvironment: .init(accept: { _ in (-1, EBADF) }, wait: { _, _ in .ready },
                                                        beforeFailureNotification: { await failureGate.wait() }),
                               lifecycle: .init(beforeTeardown: { cleaning.fulfill(); await cleanupGate.wait() },
                                                observe: {
            if case .registeredStopWaiter = $0 { registered.fulfill() }
            if case .joinedStop = $0 { stopJoined.fulfill() }
        }))
        let results = (0..<3).map { _ in Box<DaemonServeLoop.StopReason?>(nil) }
        let tasks = results.map { box in Task {
            let reason = await server.waitUntilStopped()
            XCTAssertFalse(FileManager.default.fileExists(atPath: p.pid))
            XCTAssertFalse(FileManager.default.fileExists(atPath: p.socket))
            box.set(reason)
            finished.fulfill()
        } }
        await fulfillment(of: [registered], timeout: 1)
        await failureGate.open()
        await fulfillment(of: [cleaning], timeout: 1)
        XCTAssertTrue(results.allSatisfy { $0.get() == nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.pid))
        // A concurrent ordinary stop must not overwrite the accepted failure.
        let stop = Task { await server.stop() }
        await fulfillment(of: [stopJoined], timeout: 1)
        await cleanupGate.open()
        await fulfillment(of: [finished], timeout: 2)
        let expected = DaemonServeLoop.StopReason.listenerFailed(.init(operation: .accept, errno: EBADF))
        XCTAssertTrue(results.allSatisfy { $0.get() == expected })
        await stop.value
        tasks.forEach { $0.cancel() }
    }

    func testRestartWaitsForConcurrentStopsAndOldShutdownHookCannotStopNewRun() async throws {
        let server = DaemonServeLoop.Server(), p = paths(), cleanupGate = Gate()
        let oldHook = Box<(@Sendable () async -> Void)?>(nil)
        let cleaning = expectation(description: "single teardown")
        cleaning.assertForOverFulfill = true
        let stopped = expectation(description: "two stop callers finished")
        stopped.expectedFulfillmentCount = 2
        let secondStopJoined = expectation(description: "second stop joined cleanup")
        let restartWaiting = expectation(description: "restart waiting for cleanup")
        let restarted = expectation(description: "restart finished")
        let newBound = Box(false)
        defer { unlink(p.socket); unlink(p.pid) }
        try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600,
                               lifecycle: .init(beforeTeardown: { cleaning.fulfill(); await cleanupGate.wait() },
                                                observe: { event in
            if case .joinedStop = event { secondStopJoined.fulfill() }
            if case .waitingForTeardown = event { restartWaiting.fulfill() }
        }, didInstallShutdownHook: { oldHook.set($0) }))
        let a = Task { await server.stop(); stopped.fulfill() }
        await fulfillment(of: [cleaning], timeout: 1)
        let b = Task { await server.stop(); stopped.fulfill() }
        let c = Task {
            do {
                try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600,
                                       lifecycle: .init(afterListenerStart: { newBound.set(true) }))
            } catch { XCTFail("restart failed: \(error)") }
            restarted.fulfill()
        }
        await fulfillment(of: [secondStopJoined, restartWaiting], timeout: 1)
        XCTAssertFalse(newBound.get())
        await cleanupGate.open()
        await fulfillment(of: [stopped, restarted], timeout: 2)
        XCTAssertTrue(newBound.get())
        let hook = try XCTUnwrap(oldHook.get())
        await hook()
        try assertHealthy(socket: p.socket)
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.socket))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.pid))
        a.cancel(); b.cancel(); c.cancel()
    }

    func testDelayedOldListenerNotificationDoesNotRemoveReplacementSocketOrPid() async throws {
        let server = DaemonServeLoop.Server(), p = paths(), gate = Gate()
        let delayed = expectation(description: "old notification delayed after inner cleanup")
        let released = expectation(description: "old notification fully handled")
        try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600,
                               acceptEnvironment: .init(wait: { _, _ in .failed(EINVAL) },
                                                        beforeFailureNotification: {
            delayed.fulfill(); await gate.wait()
        }), lifecycle: .init(observe: { if case .handledListenerFailure = $0 { released.fulfill() } }))
        await fulfillment(of: [delayed], timeout: 1)
        // This simulates the next process creating its entries after the
        // failed listener's path disappeared, before old outer cleanup.
        let savedPid = p.pid + ".old"
        try FileManager.default.moveItem(atPath: p.pid, toPath: savedPid)
        defer { unlink(savedPid) }
        try Data(contentsOf: URL(fileURLWithPath: savedPid)).write(to: URL(fileURLWithPath: p.pid))
        let socketMarker = "replacement socket owner"
        try socketMarker.write(toFile: p.socket, atomically: true, encoding: .utf8)
        await server.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.pid))
        XCTAssertEqual(try String(contentsOfFile: p.socket, encoding: .utf8), socketMarker)
        let oldReason = await server.waitUntilStopped()
        XCTAssertEqual(oldReason, .requested)
        try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600)
        await gate.open()
        await fulfillment(of: [released], timeout: 1)
        try assertHealthy(socket: p.socket)
        await server.stop()
        let reason = await server.waitUntilStopped()
        XCTAssertEqual(reason, .requested)
    }

    func testStartupBindFailureCleansPidAndReturnsStartupFailureReason() async throws {
        let server = DaemonServeLoop.Server(), p = paths()
        do {
            try await server.start(socketPath: p.socket + String(repeating: "x", count: 120), pidPath: p.pid, idleTimeout: 3600)
            XCTFail("overlong socket must fail")
        } catch { XCTAssertTrue(error is DaemonServer.DaemonError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.pid))
        let reason = await server.waitUntilStopped()
        XCTAssertEqual(reason, .startupFailed)
        try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600)
        try assertHealthy(socket: p.socket)
        await server.stop()
    }

    func testCancellationOfStartingCallerCleansBeforeReturning() async throws {
        let server = DaemonServeLoop.Server(), p = paths(), gate = Gate()
        let entered = expectation(description: "startup waiting")
        let accepted = expectation(description: "cancel accepted")
        let done = expectation(description: "cancelled start returned")
        let task = Task {
            do {
                try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600,
                                       lifecycle: .init(beforeListenerStart: { entered.fulfill(); await gate.wait() },
                                                        observe: { if case .beganStop = $0 { accepted.fulfill() } }))
                XCTFail("cancelled start must throw")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: p.pid))
            XCTAssertFalse(FileManager.default.fileExists(atPath: p.socket))
            done.fulfill()
        }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        await fulfillment(of: [accepted], timeout: 1)
        await gate.open()
        await fulfillment(of: [done], timeout: 2)
        await server.stop()
    }

    func testIdleCompletionAndCancelledOldWatchdogCannotStopNewRun() async throws {
        let server = DaemonServeLoop.Server(), p = paths(), oldSleep = Gate()
        let sleeping = expectation(description: "old watchdog sleeping")
        let awake = expectation(description: "old watchdog wakes after cancellation")
        try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 1,
                               lifecycle: .init(watchdogSleep: {
            sleeping.fulfill(); await oldSleep.wait(); awake.fulfill()
        }))
        await fulfillment(of: [sleeping], timeout: 1)
        await server.stop()
        let idleAccepted = expectation(description: "new watchdog accepts idle stop")
        let newSleep = Gate()
        try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: -1,
                               lifecycle: .init(observe: { event in
            if case .beganStop(let reason) = event {
                XCTAssertEqual(reason, .idleTimeout); idleAccepted.fulfill()
            }
        }, now: { Date().addingTimeInterval(4000) }, watchdogSleep: { await newSleep.wait() }))
        await oldSleep.open()
        await fulfillment(of: [awake], timeout: 1)
        try assertHealthy(socket: p.socket)
        await newSleep.open()
        await fulfillment(of: [idleAccepted], timeout: 1)
        let reason = await server.waitUntilStopped()
        XCTAssertEqual(reason, .idleTimeout)
        XCTAssertNoThrow(try reason.throwIfListenerFailed())
    }

    func testProcessCompletionMapsOnlyPermanentFailureToError() throws {
        XCTAssertNoThrow(try DaemonServeLoop.StopReason.requested.throwIfListenerFailed())
        XCTAssertNoThrow(try DaemonServeLoop.StopReason.idleTimeout.throwIfListenerFailed())
        let failure = DaemonServer.ListenerFailure(operation: .poll, errno: EINVAL)
        XCTAssertThrowsError(try DaemonServeLoop.StopReason.listenerFailed(failure).throwIfListenerFailed()) { error in
            XCTAssertEqual(error as? DaemonServer.ListenerFailure, failure)
            XCTAssertEqual(String(describing: error), "listener poll failed: errno=22")
            XCTAssertEqual(DaemonServeCommand.exitCode(for: error), .failure)
            XCTAssertEqual(DaemonServeCommand.message(for: error), "listener poll failed: errno=22")
        }
    }

    func testHostNormalShutdownDuringStartupExitsSuccessfully() async throws {
        let server = DaemonServeLoop.Server(), p = paths(), gate = Gate()
        let bound = expectation(description: "host bound but still starting")
        let stopping = expectation(description: "shutdown accepted")
        let finished = expectation(description: "host finished")
        let host = Task {
            do {
                try await DaemonServeCommand.runUntilStopped(server: server) {
                    try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600,
                                           lifecycle: .init(afterListenerStart: { bound.fulfill(); await gate.wait() },
                                                            observe: { if case .beganStop = $0 { stopping.fulfill() } }))
                }
            } catch { XCTFail("ordinary shutdown must not become a failed CLI exit: \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [bound], timeout: 1)
        let stop = Task { await server.stop() }
        await fulfillment(of: [stopping], timeout: 1)
        await gate.open()
        await fulfillment(of: [finished], timeout: 2)
        await stop.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.pid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.socket))
        host.cancel()
    }

    func testHostPermanentFailureReturnsNonzeroErrorAfterCleanup() async throws {
        let server = DaemonServeLoop.Server(), p = paths(), gate = Gate()
        let waiting = expectation(description: "host registered for completion")
        let finished = expectation(description: "host reports failure")
        let host = Task {
            do {
                try await DaemonServeCommand.runUntilStopped(server: server) {
                    try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600,
                                           acceptEnvironment: .init(wait: { _, _ in .failed(EINVAL) },
                                                                    beforeFailureNotification: { await gate.wait() }),
                                           lifecycle: .init(observe: {
                        if case .registeredStopWaiter = $0 { waiting.fulfill() }
                    }))
                }
                XCTFail("permanent failure must reach the command's error exit")
            } catch {
                XCTAssertEqual(error as? DaemonServer.ListenerFailure, .init(operation: .poll, errno: EINVAL))
                XCTAssertEqual(DaemonServeCommand.exitCode(for: error), .failure)
                XCTAssertEqual(DaemonServeCommand.message(for: error), "listener poll failed: errno=22")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: p.pid))
            XCTAssertFalse(FileManager.default.fileExists(atPath: p.socket))
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 1)
        await gate.open()
        await fulfillment(of: [finished], timeout: 2)
        host.cancel()
    }
    func testNewRunTimestampResetsPreviousIdleDeadline() async {
        let server = DaemonServer.Instance()
        let old = Date(timeIntervalSince1970: 100)
        let now = old.addingTimeInterval(1000)
        await server.configureIdleTimeout(60)
        await server.recordActivity(at: old)
        await server.recordStartTimestamp(now)
        let immediatelyIdle = await server.isIdle(now: now.addingTimeInterval(1))
        let laterIdle = await server.isIdle(now: now.addingTimeInterval(60))
        XCTAssertFalse(immediatelyIdle, "a new run starts a fresh idle interval")
        XCTAssertTrue(laterIdle)
    }

    func testCancelledJoinedStarterStopsSharedStartupForBothCallers() async {
        let server = DaemonServeLoop.Server(), p = paths(), gate = Gate()
        let entered = expectation(description: "first startup paused")
        let joined = expectation(description: "second starter joined")
        let accepted = expectation(description: "shared cancellation accepted")
        let finished = expectation(description: "both starters returned cancellation")
        finished.expectedFulfillmentCount = 2
        let lifecycle = DaemonServeLoop.LifecycleEnvironment(beforeListenerStart: {
            entered.fulfill(); await gate.wait()
        }, observe: {
            if case .joinedStartup = $0 { joined.fulfill() }
            if case .beganStop = $0 { accepted.fulfill() }
        })
        let start: @Sendable () async -> Void = {
            do {
                try await server.start(socketPath: p.socket, pidPath: p.pid, idleTimeout: 3600, lifecycle: lifecycle)
                XCTFail("cancelled shared startup must not succeed")
            } catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        let a = Task { await start() }
        await fulfillment(of: [entered], timeout: 1)
        let b = Task { await start() }
        await fulfillment(of: [joined], timeout: 1)
        b.cancel()
        await fulfillment(of: [accepted], timeout: 1)
        await gate.open()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.socket))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.pid))
        let reason = await server.waitUntilStopped()
        XCTAssertEqual(reason, .requested)
        a.cancel()
    }

}
