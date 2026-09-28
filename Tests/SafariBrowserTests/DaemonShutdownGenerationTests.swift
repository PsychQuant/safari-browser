import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonShutdownGenerationTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        func read() -> Int { lock.withLock { value } }
    }

    private func connect(_ path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        do { _ = try TestUnixSocket.readLine(fd: fd); return fd }
        catch { close(fd); throw error }
    }

    func testOldShutdownCannotBorrowNewHook() async throws {
        try await checkRevokedShutdown(useHook: true)
    }

    func testOldShutdownCannotInvokeUnscopedStop() async throws {
        try await checkRevokedShutdown(useHook: false)
    }

    private func checkRevokedShutdown(useHook: Bool) async throws {
        let path = NSTemporaryDirectory() + "s198-" + String(UUID().uuidString.prefix(8)) + ".sock"
        let watchdog = Counter(), oldHook = Counter(), newHook = Counter()
        let server = DaemonServer.Instance(shutdownWatchdog: { watchdog.increment() })
        let entered = expectation(description: "old shutdown blocked in request log")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); unlink(path) }
        if useHook { await server.setShutdownHook { oldHook.increment(); await server.stop() } }
        await server.setLogWriter { line in
            guard line.contains("request_response_prepared") else { return }
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        try await server.start(socketPath: path)
        let oldFD = try connect(path)
        defer { close(oldFD) }
        try TestUnixSocket.writeLine(fd: oldFD, line: #"{"method":"daemon.shutdown","params":{},"requestId":198}"#)
        await fulfillment(of: [entered], timeout: 1)
        await server.stop()
        await server.setLogWriter(nil)
        if useHook { await server.setShutdownHook { newHook.increment(); await server.stop() } }
        try await server.start(socketPath: path)
        release.signal()
        // #199 revokes the old transport itself. If an error frame was
        // already delivered it remains cancelled; otherwise EOF is unknown
        // to the post-send client and must never authorize replay.
        if let line = try? TestUnixSocket.readLine(fd: oldFD) {
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let error = reply["error"] as? [String: Any]
            XCTAssertEqual(error?["code"] as? String, "cancelled", "revoked shutdown must not claim success")
        }
        XCTAssertEqual(oldHook.read(), 0)
        XCTAssertEqual(newHook.read(), 0)
        XCTAssertEqual(watchdog.read(), 0, "revoked dispatch cannot schedule process termination")
        let newFD = try connect(path)
        defer { close(newFD) }
        try TestUnixSocket.writeLine(fd: newFD, line: #"{"method":"daemon.status","params":{},"requestId":199}"#)
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try TestUnixSocket.readLine(fd: newFD).utf8)) as? [String: Any])
        XCTAssertNotNil(status["result"])
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
    func testCapturedHookCompletionCannotAffectNewGeneration() async throws {
        try await checkCapturedCompletion(useHook: true)
    }

    func testCapturedFallbackCompletionCannotAffectNewGeneration() async throws {
        try await checkCapturedCompletion(useHook: false)
    }

    private func checkCapturedCompletion(useHook: Bool) async throws {
        let path = NSTemporaryDirectory() + "h198-" + String(UUID().uuidString.prefix(8)) + ".sock"
        let calls = Counter(), server = DaemonServer.Instance()
        defer { unlink(path) }
        if useHook { await server.setShutdownHook { calls.increment(); await server.stop() } }
        try await server.start(socketPath: path)
        let oldCompletion = await server.capturedShutdownCompletionForTesting()
        await server.stop()
        try await server.start(socketPath: path)
        await oldCompletion()
        XCTAssertEqual(calls.read(), 0)
        let fd = try connect(path)
        defer { close(fd) }
        try TestUnixSocket.writeLine(fd: fd, line: #"{"method":"daemon.status","params":{},"requestId":198}"#)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try TestUnixSocket.readLine(fd: fd).utf8)) as? [String: Any])
        XCTAssertNotNil(reply["result"])
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

}
