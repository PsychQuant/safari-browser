import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonEstablishedConnectionTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func path() -> String {
        NSTemporaryDirectory() + "c199-" + String(UUID().uuidString.prefix(8)) + ".sock"
    }

    private func connect(_ path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0), enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let rc = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        do { _ = try TestUnixSocket.readLine(fd: fd); return fd }
        catch { close(fd); throw error }
    }

    private actor Gate {
        private var open = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { open = true; waiter?.resume(); waiter = nil }
    }

    func testStopFinishesTransportBeforeNoncooperativeHandlerReturns() async throws {
        let socketPath = path(), gate = Gate(), finished = Counter(), effects = Counter()
        let entered = expectation(description: "handler already executing")
        let server = DaemonServer.Instance(connectionObservation: .init(didFinish: { finished.increment() }))
        defer { unlink(socketPath) }
        await server.register("fixture.noncooperative") { _ in
            entered.fulfill()
            await gate.wait()
            effects.increment()
            return Data("{}".utf8)
        }
        try await server.start(socketPath: socketPath)
        let fd = try connect(socketPath)
        defer { close(fd) }
        try TestUnixSocket.writeLine(fd: fd, line: #"{"method":"fixture.noncooperative","params":{},"requestId":199}"#)
        await fulfillment(of: [entered], timeout: 1)
        await server.stop()
        for _ in 0..<100 {
            if finished.value == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(finished.value, 1, "transport cannot wait for a noncooperative handler")
        let unfinished = await server.activeOperationCount
        XCTAssertEqual(unfinished, 1, "already executing work must remain honestly tracked")
        XCTAssertEqual(effects.value, 0)
        await gate.release()
        for _ in 0..<100 {
            if await server.activeOperationCount == 0, finished.value == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let remaining = await server.activeOperationCount
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(effects.value, 1, "cancellation cannot pretend an admitted effect was undone")
    }

    func testRevokedConnectionDoesNotDispatchBytesArrivingAfterStop() async throws {
        let socketPath = path(), invoked = Counter()
        let beforeRead = expectation(description: "loop passed its cancellation check")
        let finished = expectation(description: "old connection ends")
        let releaseRead = DispatchSemaphore(value: 0)
        defer { releaseRead.signal(); unlink(socketPath) }
        let server = DaemonServer.Instance(connectionObservation: .init(beforeRead: {
            beforeRead.fulfill()
            _ = releaseRead.wait(timeout: .now() + 5)
        }, didFinish: { finished.fulfill() }))
        await server.register("fixture.sideEffect") { _ in
            invoked.increment()
            return Data("{}".utf8)
        }
        try await server.start(socketPath: socketPath)
        let fd = try connect(socketPath)
        defer { close(fd) }
        await fulfillment(of: [beforeRead], timeout: 1)
        await server.stop()
        releaseRead.signal()
        // A corrected server may already have revoked its read side. Either a
        // write failure or EOF is valid, but no new handler invocation is valid.
        try? TestUnixSocket.writeLine(fd: fd, line: #"{"method":"fixture.sideEffect","params":{},"requestId":199}"#)
        _ = try? TestUnixSocket.readLine(fd: fd)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(invoked.value, 0, "bytes received after stop cannot start a handler")
    }

    func testStopWakesAnAcceptedClientWaitingWithoutAnyInput() async throws {
        let socketPath = path()
        let beforeRead = expectation(description: "client ready to read")
        let finished = expectation(description: "connection returned")
        let releaseRead = DispatchSemaphore(value: 0)
        defer { releaseRead.signal(); unlink(socketPath) }
        let server = DaemonServer.Instance(connectionObservation: .init(beforeRead: {
            beforeRead.fulfill()
            _ = releaseRead.wait(timeout: .now() + 5)
        }, didFinish: { finished.fulfill() }))
        try await server.start(socketPath: socketPath)
        let fd = try connect(socketPath)
        defer { close(fd) }
        await fulfillment(of: [beforeRead], timeout: 1)
        await server.stop()
        var byte: UInt8 = 0
        let result = Darwin.read(fd, &byte, 1)
        XCTAssertEqual(result, 0, "stop must close the accepted transport; client read must not time out")
        // Permit the old broken implementation to finish after the assertion,
        // so the RED fixture itself never leaves a permanently blocked read.
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        releaseRead.signal()
        await fulfillment(of: [finished], timeout: 2)
    }

    func testCompletedConnectionsAreRemovedFromTrackingBeforeStop() async throws {
        let socketPath = path()
        defer { unlink(socketPath) }
        let finished = expectation(description: "all three connections returned")
        finished.expectedFulfillmentCount = 3
        let server = DaemonServer.Instance(connectionObservation: .init(didFinish: { finished.fulfill() }))
        try await server.start(socketPath: socketPath)
        for _ in 0..<3 {
            let fd = try connect(socketPath)
            close(fd)
        }
        await fulfillment(of: [finished], timeout: 2)
        let retained = await server.trackedConnectionCount
        XCTAssertEqual(retained, 0, "completed tasks must retire while the daemon continues running")
        await server.stop()
    }

    func testStopAfterParsingCannotAdmitHandlerOrRecordActivity() async throws {
        let socketPath = path(), gate = Gate(), calls = Counter()
        let parsed = expectation(description: "frame parsed before actor admission")
        let finished = expectation(description: "transport finished")
        let server = DaemonServer.Instance(connectionObservation: .init(beforeDispatch: {
            parsed.fulfill(); await gate.wait()
        }, didFinish: { finished.fulfill() }))
        defer { unlink(socketPath) }
        await server.register("fixture.sideEffect") { _ in calls.increment(); return Data("{}".utf8) }
        try await server.start(socketPath: socketPath)
        let before = await server.currentLastActivityEpoch
        let fd = try connect(socketPath)
        defer { close(fd) }
        try TestUnixSocket.writeLine(fd: fd, line: #"{"method":"fixture.sideEffect","params":{},"requestId":1}"#)
        await fulfillment(of: [parsed], timeout: 1)
        await server.stop()
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(calls.value, 0)
        let after = await server.currentLastActivityEpoch
        let operations = await server.activeOperationCount
        XCTAssertEqual(after, before)
        XCTAssertEqual(operations, 0)
    }

    func testBufferedSecondRequestIsNotAdmittedAfterStop() async throws {
        let socketPath = path(), gate = Gate(), secondCalls = Counter()
        let firstEntered = expectation(description: "first handler entered")
        let finished = expectation(description: "transport finished")
        let server = DaemonServer.Instance(connectionObservation: .init(didFinish: { finished.fulfill() }))
        defer { unlink(socketPath) }
        await server.register("fixture.first") { _ in firstEntered.fulfill(); await gate.wait(); return Data("{}".utf8) }
        await server.register("fixture.second") { _ in secondCalls.increment(); return Data("{}".utf8) }
        try await server.start(socketPath: socketPath)
        let fd = try connect(socketPath)
        defer { close(fd) }
        try TestUnixSocket.writeLine(fd: fd, line: #"{"method":"fixture.first","params":{},"requestId":1}"# + "\n" + #"{"method":"fixture.second","params":{},"requestId":2}"#)
        await fulfillment(of: [firstEntered], timeout: 1)
        await server.stop()
        await fulfillment(of: [finished], timeout: 2)
        await gate.release()
        for _ in 0..<100 {
            if await server.activeOperationCount == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(secondCalls.value, 0)
    }

    func testOldOperationCannotWriteRetireOrLogIntoReplacementRun() async throws {
        let socketPath = path(), oldGate = Gate(), newGate = Gate()
        let oldEntered = expectation(description: "old handler entered")
        let newEntered = expectation(description: "new handler entered")
        let oldLog = DaemonDiagnosticBudgetTests.Sink(), newLog = DaemonDiagnosticBudgetTests.Sink()
        let server = DaemonServer.Instance()
        defer { unlink(socketPath) }
        await server.setLogWriter { oldLog.append($0) }
        await server.register("fixture.old") { _ in oldEntered.fulfill(); await oldGate.wait(); return Data("\"old\"".utf8) }
        await server.register("fixture.new") { _ in newEntered.fulfill(); await newGate.wait(); return Data("\"new\"".utf8) }
        try await server.start(socketPath: socketPath)
        let oldFD = try connect(socketPath)
        defer { close(oldFD) }
        try TestUnixSocket.writeLine(fd: oldFD, line: #"{"method":"fixture.old","params":{},"requestId":1}"#)
        await fulfillment(of: [oldEntered], timeout: 1)
        await server.stop()
        await server.setLogWriter { newLog.append($0) }
        try await server.start(socketPath: socketPath)
        let newFD = try connect(socketPath)
        defer { close(newFD) }
        try TestUnixSocket.writeLine(fd: newFD, line: #"{"method":"fixture.new","params":{},"requestId":2}"#)
        await fulfillment(of: [newEntered], timeout: 1)
        let slots = await server.snapshotInFlight()
        let activity = await server.currentLastActivityEpoch
        XCTAssertEqual(slots.count, 1)
        await oldGate.release()
        for _ in 0..<100 {
            if await server.activeOperationCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let stillActive = await server.snapshotInFlight()
        let connectionCount = await server.trackedConnectionCount
        let nowActivity = await server.currentLastActivityEpoch
        XCTAssertEqual(stillActive.first?.requestID, slots.first?.requestID)
        XCTAssertEqual(stillActive.first?.requestIdJSON, Data("2".utf8))
        XCTAssertEqual(connectionCount, 1)
        XCTAssertEqual(nowActivity, activity)
        XCTAssertTrue(oldLog.objects.contains { $0["method"] as? String == "fixture.old" })
        XCTAssertFalse(newLog.objects.contains { $0["method"] as? String == "fixture.old" })
        var pollState = pollfd(fd: newFD, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pollState, 1, 0), 0, "old result must not arrive at new peer")
        await newGate.release()
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try TestUnixSocket.readLine(fd: newFD).utf8)) as? [String: Any])
        XCTAssertEqual(response["requestId"] as? Int, 2)
        XCTAssertEqual(response["result"] as? String, "new")
        await server.stop()
    }

    func testMalformedParamsAreRejectedWithoutDispatchAndLifecycleStillIgnoresParams() async throws {
        let socketPath = path(), calls = Counter(), server = DaemonServer.Instance()
        defer { unlink(socketPath); Task { await server.stop() } }
        await server.register("fixture.params") { _ in calls.increment(); return Data("true".utf8) }
        try await server.start(socketPath: socketPath)
        let fd = try connect(socketPath)
        defer { close(fd) }
        for params in ["42", "true", "null", "\"string\""] {
            try TestUnixSocket.writeLine(fd: fd, line: "{\"method\":\"fixture.params\",\"params\":\(params),\"requestId\":1}")
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try TestUnixSocket.readLine(fd: fd).utf8)) as? [String: Any])
            XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "parseError")
        }
        XCTAssertEqual(calls.value, 0)
        try TestUnixSocket.writeLine(fd: fd, line: #"{"method":"fixture.params","params":{},"requestId":2}"#)
        let normal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try TestUnixSocket.readLine(fd: fd).utf8)) as? [String: Any])
        XCTAssertEqual(normal["result"] as? Bool, true)
        XCTAssertEqual(calls.value, 1)
        try TestUnixSocket.writeLine(fd: fd, line: #"{"method":"daemon.status","params":42,"requestId":3}"#)
        let lifecycle = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try TestUnixSocket.readLine(fd: fd).utf8)) as? [String: Any])
        XCTAssertNotNil(lifecycle["result"])
        await server.stop()
    }
}
