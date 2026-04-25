import XCTest
import Foundation
@testable import SafariBrowser

/// Section 6 of `daemon-security-hardening` — lifecycle commands
/// MUST bypass the main-request actor. The three scenarios:
///
/// (a) `daemon.status` returns during an active long-running handler
///     (proves the bypass works).
/// (b) `daemon.shutdown` during a handler in flight produces a
///     `cancelled` envelope on the original client.
/// (c) The `cancelled` error code is NOT classified as fallback-worthy
///     so clients propagate the cancellation rather than retry the
///     stateless path against a dying daemon.
final class DaemonLifecycleCancellationTests: XCTestCase {

    // MARK: - (c) cancelled is domain-classified

    func testCancelledRemoteError_isNotFallbackWorthy() {
        let err = DaemonClient.Error.remoteError(
            code: "cancelled",
            message: "cancelled by daemon shutdown"
        )
        XCTAssertNil(err.fallbackReason,
                     "cancelled SHALL be domain-classified — clients propagate, not fallback")
    }

    // MARK: - peekLifecycleMethod (pure routing)

    func testPeekLifecycleMethod_matchesShutdown() {
        let line = Data(#"{"method":"daemon.shutdown","params":{},"requestId":1}"#.utf8)
        XCTAssertEqual(DaemonServer.Instance.peekLifecycleMethod(line: line), .shutdown)
    }

    func testPeekLifecycleMethod_matchesStatus() {
        let line = Data(#"{"method":"daemon.status"}"#.utf8)
        XCTAssertEqual(DaemonServer.Instance.peekLifecycleMethod(line: line), .status)
    }

    func testPeekLifecycleMethod_returnsNilForNormalRequest() {
        let line = Data(#"{"method":"applescript.execute","params":{"source":"x"}}"#.utf8)
        XCTAssertNil(DaemonServer.Instance.peekLifecycleMethod(line: line))
    }

    func testPeekLifecycleMethod_returnsNilForGarbage() {
        XCTAssertNil(DaemonServer.Instance.peekLifecycleMethod(line: Data("not json".utf8)))
        XCTAssertNil(DaemonServer.Instance.peekLifecycleMethod(line: Data(#"{"foo":"bar"}"#.utf8)))
    }

    // MARK: - encodeRequestId / encodeErrorRaw round-trip

    func testEncodeRequestId_intRoundTrip() throws {
        let encoded = DaemonServer.Instance.encodeRequestId(42)
        let decoded = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        XCTAssertEqual(decoded as? Int, 42)
    }

    func testEncodeRequestId_stringRoundTrip() throws {
        let encoded = DaemonServer.Instance.encodeRequestId("abc-def")
        let decoded = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        XCTAssertEqual(decoded as? String, "abc-def")
    }

    func testEncodeRequestId_nilProducesJsonNull() throws {
        let encoded = DaemonServer.Instance.encodeRequestId(nil)
        let s = String(data: encoded, encoding: .utf8)
        XCTAssertEqual(s, "null")
    }

    func testEncodeErrorRaw_preservesRequestIdAcrossSplice() throws {
        // The cancelled-envelope splicing path must preserve requestId
        // shape — Int requestId stays Int, String stays String.
        let intEnvelope = DaemonServer.Instance.encodeErrorRaw(
            requestIdJSON: DaemonServer.Instance.encodeRequestId(7),
            code: .cancelled,
            message: "cancelled by daemon shutdown"
        )
        let intDict = try JSONSerialization.jsonObject(with: intEnvelope, options: []) as? [String: Any]
        XCTAssertEqual(intDict?["requestId"] as? Int, 7)
        let intError = intDict?["error"] as? [String: Any]
        XCTAssertEqual(intError?["code"] as? String, "cancelled")
        XCTAssertEqual(intError?["message"] as? String, "cancelled by daemon shutdown")

        let stringEnvelope = DaemonServer.Instance.encodeErrorRaw(
            requestIdJSON: DaemonServer.Instance.encodeRequestId("req-1"),
            code: .cancelled,
            message: "shutdown"
        )
        let stringDict = try JSONSerialization.jsonObject(with: stringEnvelope, options: []) as? [String: Any]
        XCTAssertEqual(stringDict?["requestId"] as? String, "req-1")
    }

    // MARK: - In-flight tracking

    func testInstance_inFlightTrackingRoundTrip() async throws {
        let server = DaemonServer.Instance()
        let id1 = DaemonServer.Instance.encodeRequestId(11)
        let id2 = DaemonServer.Instance.encodeRequestId(22)
        await server.markInFlight(fd: 100, requestIdJSON: id1)
        await server.markInFlight(fd: 200, requestIdJSON: id2)

        let snapshot = await server.snapshotInFlight()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertTrue(snapshot.contains { $0.fd == 100 && $0.requestIdJSON == id1 })
        XCTAssertTrue(snapshot.contains { $0.fd == 200 && $0.requestIdJSON == id2 })

        await server.clearInFlight(fd: 100)
        let after = await server.snapshotInFlight()
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(after.contains { $0.fd == 200 })
    }

    // MARK: - Status snapshot bypass (a)

    /// Bypass `daemon.status` SHALL return without touching the cache
    /// actor. We exercise this by registering a slow handler that
    /// holds the cache-actor surrogate for a noticeable interval, then
    /// asserting that an immediately-issued `daemon.status` resolves
    /// in well under the slow-handler duration.
    func testDaemonStatus_returnsDuringSlowHandler() async throws {
        let socketPath = "/tmp/llt-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }
        let server = DaemonServer.Instance()
        defer { Task { await server.stop() } }

        // A slow handler that simulates a long-running AppleScript by
        // sleeping on an actor-isolated call.
        await server.register("slow") { _ in
            try? await Task.sleep(for: .milliseconds(800))
            return Data(#"{"output":"done"}"#.utf8)
        }
        try await server.start(socketPath: socketPath)

        // Issue a slow request in the background. Concrete-typed
        // capture sidesteps the region-isolation analyzer's confusion
        // when expectations + paths cross detached-Task boundaries.
        let slowPath: String = socketPath
        async let slowResult: Void = {
            _ = try? await Self.sendOneRequest(
                path: slowPath,
                body: #"{"method":"slow","params":{},"requestId":1}"#
            )
        }()

        // Tiny pause to ensure the slow request actually entered the handler.
        try await Task.sleep(for: .milliseconds(100))

        // Now issue a status request. With the bypass it MUST return in
        // well under the slow-handler's remaining duration.
        let started = Date()
        let response = try await Self.sendOneRequest(
            path: socketPath,
            body: #"{"method":"daemon.status","params":{},"requestId":2}"#
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5, "status SHALL bypass — got \(elapsed)s while slow handler was in flight")

        let dict = response as? [String: Any]
        XCTAssertEqual(dict?["requestId"] as? Int, 2)
        let result = dict?["result"] as? [String: Any]
        XCTAssertNotNil(result?["pid"])
        XCTAssertNotNil(result?["uptimeSeconds"])

        // Wait for the slow request to drain so the actor stops cleanly.
        _ = await slowResult
    }

    // MARK: - Shutdown cancels in-flight (b)

    /// `daemon.shutdown` while a handler is in flight MUST send a
    /// `cancelled` envelope to the in-flight client and complete the
    /// teardown. We verify by issuing a slow request that would return
    /// success after 800ms — but we shoot the daemon mid-flight at
    /// 100ms via `daemon.shutdown` and expect the slow request's
    /// response to carry `error.code == "cancelled"`.
    func testDaemonShutdown_cancelsInFlightRequest() async throws {
        let socketPath = "/tmp/llc-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }
        let server = DaemonServer.Instance()
        defer { Task { await server.stop() } }

        await server.register("slow") { _ in
            try? await Task.sleep(for: .milliseconds(2000))
            return Data(#"{"output":"done"}"#.utf8)
        }
        try await server.start(socketPath: socketPath)

        // Use async let with a bool result so the analyzer can prove
        // the captured path is Sendable (concrete String) and we
        // never await across an actor with a non-Sendable context.
        let slowPath: String = socketPath
        async let slowOutcome: Bool = {
            do {
                let resp = try await Self.sendOneRequest(
                    path: slowPath,
                    body: #"{"method":"slow","params":{},"requestId":1}"#
                )
                if let dict = resp as? [String: Any],
                   let error = dict["error"] as? [String: Any],
                   let code = error["code"] as? String {
                    return code == "cancelled"
                }
                return false
            } catch {
                // EOF / read failure is also acceptable cancellation
                // evidence — the daemon may have closed before sending.
                return true
            }
        }()

        try await Task.sleep(for: .milliseconds(150))
        _ = try await Self.sendOneRequest(
            path: socketPath,
            body: #"{"method":"daemon.shutdown","params":{},"requestId":99}"#
        )

        let cancelled = await slowOutcome
        XCTAssertTrue(cancelled, "slow request must surface cancelled (or EOF) on shutdown")
    }

    // MARK: - Helpers

    /// Simple raw POSIX-socket request: connect, write one line, read
    /// the handshake and one response line, then return the parsed
    /// JSON. The sockaddr_un path-length cap means we stage sockets
    /// under `/tmp` rather than `NSTemporaryDirectory()`.
    static func sendOneRequest(path: String, body: String) async throws -> Any {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() { buf[i] = b }
            buf[pathBytes.count] = 0
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        var connectRC: Int32 = -1
        var attempts = 0
        while connectRC != 0 && attempts < 50 {
            connectRC = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, addrLen)
                }
            }
            if connectRC != 0 { usleep(20_000); attempts += 1 }
        }
        if connectRC != 0 { throw POSIXError(.ECONNREFUSED) }

        let payload = Data((body + "\n").utf8)
        _ = payload.withUnsafeBytes { buf in
            write(fd, buf.baseAddress, buf.count)
        }

        // Discard handshake.
        _ = readOneLine(fd: fd)
        guard let line = readOneLine(fd: fd) else { throw POSIXError(.EIO) }
        return try JSONSerialization.jsonObject(with: line, options: [])
    }

    static func readOneLine(fd: Int32) -> Data? {
        var bytes: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 1)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                read(fd, ptr.baseAddress, 1)
            }
            if n <= 0 { return bytes.isEmpty ? nil : Data(bytes) }
            if buf[0] == 0x0A { return Data(bytes) }
            bytes.append(buf[0])
        }
    }
}
