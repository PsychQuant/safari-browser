import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonConnectionShutdownTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        func hit() { lock.withLock { stored += 1 } }
        var value: Int { lock.withLock { stored } }
    }
    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        func set(_ value: T) { lock.withLock { stored = value } }
        var value: T { lock.withLock { stored } }
    }
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() { opened = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
    }

    private func path() -> String {
        NSTemporaryDirectory() + "s199-" + String(UUID().uuidString.prefix(8)) + ".sock"
    }
    private func connect(_ path: String, receiveBuffer: Int32? = nil) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0), enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        if var receiveBuffer { _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size)) }
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
    private func send(_ fd: Int32, method: String, id: Int) throws {
        let bytes = try JSONSerialization.data(withJSONObject: ["method": method, "params": [:], "requestId": id])
        try TestUnixSocket.writeLine(fd: fd, line: String(decoding: bytes, as: UTF8.self))
    }
    private func response(_ fd: Int32) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try TestUnixSocket.readLine(fd: fd).utf8)) as? [String: Any])
    }
    private func closed(_ path: String) async -> Bool {
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !FileManager.default.fileExists(atPath: path)
    }

    func testShutdownACKAndOneCancelledFrameReachHealthyPeers() async throws {
        let socketPath = path(), gate = Gate()
        let entered = expectation(description: "handler pending")
        let server = DaemonServer.Instance()
        defer { unlink(socketPath); Task { await gate.open(); await server.stop() } }
        await server.register("fixture.pending") { _ in entered.fulfill(); await gate.wait(); return Data("\"late\"".utf8) }
        try await server.start(socketPath: socketPath)
        let pending = try connect(socketPath), shutdown = try connect(socketPath)
        defer { close(pending); close(shutdown) }
        try send(pending, method: "fixture.pending", id: 1)
        await fulfillment(of: [entered], timeout: 1)
        try send(shutdown, method: "daemon.shutdown", id: 99)
        XCTAssertEqual(try response(shutdown)["requestId"] as? Int, 99)
        let cancelled = try response(pending)
        XCTAssertEqual(cancelled["requestId"] as? Int, 1)
        XCTAssertEqual((cancelled["error"] as? [String: Any])?["code"] as? String, "cancelled")
        await gate.open()
        var byte: UInt8 = 0
        XCTAssertEqual(read(pending, &byte, 1), 0, "late normal result must not become a second frame")
        let stopped = await closed(socketPath)
        XCTAssertTrue(stopped)
    }

    func testPartialNormalFrameCannotBeSplicedWithCancellation() async throws {
        let socketPath = path(), server = DaemonServer.Instance()
        let payload = String(repeating: "n", count: 8 * 1024 * 1024)
        defer { unlink(socketPath); Task { await server.stop() } }
        await server.register("fixture.large") { _ in try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]) }
        try await server.start(socketPath: socketPath)
        let slow = try connect(socketPath, receiveBuffer: 4096)
        defer { close(slow) }
        try send(slow, method: "fixture.large", id: 1)
        var readable = false
        for _ in 0..<200 {
            var state = pollfd(fd: slow, events: Int16(POLLIN), revents: 0)
            if poll(&state, 1, 0) > 0 { readable = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(readable, "normal response must have started writing")
        let shutdown = try connect(socketPath)
        defer { close(shutdown) }
        try send(shutdown, method: "daemon.shutdown", id: 99)
        XCTAssertEqual(try response(shutdown)["requestId"] as? Int, 99)
        let stopped = await closed(socketPath)
        XCTAssertTrue(stopped)
        var received = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(slow, $0.baseAddress!, $0.count) }
            if n == 0 { break }
            if n < 0 { XCTAssertEqual(errno, ECONNRESET); break }
            received.append(contentsOf: buffer.prefix(n))
        }
        XCTAssertGreaterThan(received.count, 0)
        XCTAssertLessThan(received.count, payload.utf8.count)
        XCTAssertFalse(String(decoding: received, as: UTF8.self).contains("cancelled"))
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: received), "partial frame stays unknown, not a fabricated complete result")
    }

    func testBlockedCancellationRepliesShareOneDeadlineAcrossClients() async throws {
        let socketPath = path(), gate = Gate(), attempts = Counter()
        let entered = expectation(description: "three handlers pending")
        entered.expectedFulfillmentCount = 3
        let server = DaemonServer.Instance(connectionEnvironment: .init(write: { fd, pointer, count in
            let text = String(decoding: UnsafeRawBufferPointer(start: pointer, count: count), as: UTF8.self)
            if text.contains("cancelled by daemon shutdown") {
                attempts.hit()
                return .init(count: -1, errno: EAGAIN)
            }
            let n = Darwin.write(fd, pointer, count)
            return .init(count: n, errno: n < 0 ? errno : 0)
        }, wait: { try await Task.sleep(for: $0) }))
        defer { unlink(socketPath); Task { await gate.open(); await server.stop() } }
        await server.register("fixture.pending") { _ in entered.fulfill(); await gate.wait(); return Data("{}".utf8) }
        try await server.start(socketPath: socketPath)
        var peers: [Int32] = []
        defer { peers.forEach { close($0) } }
        for id in 1...3 {
            let fd = try connect(socketPath); peers.append(fd)
            try send(fd, method: "fixture.pending", id: id)
        }
        await fulfillment(of: [entered], timeout: 1)
        let shutdown = try connect(socketPath)
        defer { close(shutdown) }
        let begin = ContinuousClock.now
        try send(shutdown, method: "daemon.shutdown", id: 99)
        _ = try response(shutdown)
        let stopped = await closed(socketPath)
        let elapsed = begin.duration(to: .now)
        XCTAssertTrue(stopped)
        XCTAssertGreaterThan(attempts.value, 0)
        XCTAssertLessThan(elapsed, .milliseconds(650), "three blocked clients cannot each consume a new 250 ms budget")
        await gate.open()
    }

    func testBlockedShutdownACKStillExecutesStop() async throws {
        let socketPath = path(), attempts = Counter()
        let finished = expectation(description: "shutdown transport ends")
        let server = DaemonServer.Instance(connectionObservation: .init(didFinish: { finished.fulfill() }),
                                          connectionEnvironment: .init(write: { fd, pointer, count in
            let bytes = Data(bytes: pointer, count: count)
            if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               object["requestId"] as? Int == 99 {
                attempts.hit()
                return .init(count: -1, errno: EAGAIN)
            }
            let n = Darwin.write(fd, pointer, count)
            return .init(count: n, errno: n < 0 ? errno : 0)
        }, wait: { try await Task.sleep(for: $0) }))
        defer { unlink(socketPath); Task { await server.stop() } }
        try await server.start(socketPath: socketPath)
        let fd = try connect(socketPath)
        defer { close(fd) }
        try send(fd, method: "daemon.shutdown", id: 99)
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertGreaterThan(attempts.value, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        var byte: UInt8 = 0
        XCTAssertEqual(read(fd, &byte, 1), 0)
    }

    func testActualClientClassifiesInterruptedReplyAsUnknownWithoutReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("r199-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let name = "owned", path = DaemonClient.socketPath(dir: directory.path, name: "owned")
        let wrotePrefix = expectation(description: "actual reply prefix written")
        let completed = expectation(description: "actual client returns unknown")
        let writes = Counter(), calls = Counter(), replays = Counter()
        let outcome = Box<DaemonClient.Error?>(nil)
        let server = DaemonServer.Instance(connectionEnvironment: .init(write: { fd, pointer, count in
            let frame = Data(bytes: pointer, count: count)
            if DaemonProtocol.decodeHandshakeVersion(frame) != nil {
                let n = Darwin.write(fd, pointer, count)
                return .init(count: n, errno: n < 0 ? errno : 0)
            }
            if writes.value == 0 {
                let n = Darwin.write(fd, pointer, min(count, 16))
                if n > 0 { writes.hit(); wrotePrefix.fulfill() }
                return .init(count: n, errno: n < 0 ? errno : 0)
            }
            return .init(count: -1, errno: EAGAIN)
        }, wait: { try await Task.sleep(for: $0) }))
        defer { Task { await server.stop() }; try? FileManager.default.removeItem(at: directory) }
        await server.register("fixture.once") { _ in calls.hit(); return Data("\"owned-result\"".utf8) }
        try await server.start(socketPath: path)
        let client = Task {
            do {
                _ = try await SafariBridge.runViaRouter(source: "owned fixture", daemonOptIn: true,
                    daemonFn: { _ in
                        let bytes = try await DaemonClient.sendRequest(name: name, method: "fixture.once", params: Data("{}".utf8),
                            requestId: 199, timeout: 3, socketDir: directory.path)
                        return String(decoding: bytes, as: UTF8.self)
                    }, statelessFn: { _ in replays.hit(); return "replayed" })
                XCTFail("partial reply cannot succeed")
            } catch { outcome.set(error as? DaemonClient.Error) }
            completed.fulfill()
        }
        await fulfillment(of: [wrotePrefix], timeout: 1)
        await server.stop()
        await fulfillment(of: [completed], timeout: 2)
        if case .requestOutcomeUnknown = outcome.value {} else { XCTFail("expected outcome unknown, got \(String(describing: outcome.value))") }
        XCTAssertNil(outcome.value?.fallbackReason)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(replays.value, 0)
        client.cancel()
    }
}
