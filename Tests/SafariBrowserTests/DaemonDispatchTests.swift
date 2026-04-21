import XCTest
import Foundation
import Darwin
@testable import SafariBrowser

/// Task 4.1 — wires `PreCompiledScripts.CompileCache` into
/// `DaemonServer.Instance` method dispatch, proving the full round trip:
/// DaemonServer receives JSON → routes to handler → handler executes
/// pre-compiled script via cache → result flows back. Exercises the
/// `No Safari state cache` requirement by checking that repeated calls
/// do not accumulate state beyond the pre-compiled handle count.
final class DaemonDispatchTests: XCTestCase {

    var socketPath: String!
    var server: DaemonServer.Instance!
    var cache: PreCompiledScripts.CompileCache!

    override func setUp() async throws {
        try await super.setUp()
        socketPath = "\(NSTemporaryDirectory())dspt-\(UUID().uuidString.prefix(8)).sock"
        server = DaemonServer.Instance()
        cache = PreCompiledScripts.CompileCache()
    }

    override func tearDown() async throws {
        await server.stop()
        unlink(socketPath)
        try await super.tearDown()
    }

    // MARK: - End-to-end: `cache.arithmetic` demonstrates the wiring

    /// Registers `cache.arithmetic`, fires a request through the socket, and
    /// verifies the handler compiles/executes the arithmetic AppleScript and
    /// returns the correct result.
    func testCacheArithmetic_endToEnd() async throws {
        await DaemonDispatch.registerDemoHandlers(on: server, cache: cache)
        try await server.start(socketPath: socketPath)

        let response = try sendJSONLine(
            path: socketPath,
            body: #"{"method":"cache.arithmetic","params":{"expression":"6 * 7"},"requestId":1}"#
        )
        XCTAssertEqual(response["requestId"] as? Int, 1)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["int32"] as? Int, 42)
    }

    /// Missing `expression` param MUST surface a handlerError, not a silent
    /// 0 or a crash.
    func testCacheArithmetic_missingExpression_returnsError() async throws {
        await DaemonDispatch.registerDemoHandlers(on: server, cache: cache)
        try await server.start(socketPath: socketPath)

        let response = try sendJSONLine(
            path: socketPath,
            body: #"{"method":"cache.arithmetic","params":{},"requestId":2}"#
        )
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "handlerError")
    }

    // MARK: - Path A: no Safari-state cache growth

    /// Sending the SAME expression five times MUST grow the CompileCache by
    /// exactly one entry (the arithmetic source). Different expressions each
    /// contribute one entry.
    func testPathA_repeatedSameExpression_onlyCachesOnce() async throws {
        await DaemonDispatch.registerDemoHandlers(on: server, cache: cache)
        try await server.start(socketPath: socketPath)

        for _ in 0..<5 {
            _ = try sendJSONLine(
                path: socketPath,
                body: #"{"method":"cache.arithmetic","params":{"expression":"2 + 2"},"requestId":1}"#
            )
        }
        let count = await cache.cacheCount
        XCTAssertEqual(count, 1, "identical expression should not grow cache past 1")
    }

    func testPathA_differentExpressions_growLinearly() async throws {
        await DaemonDispatch.registerDemoHandlers(on: server, cache: cache)
        try await server.start(socketPath: socketPath)

        let exprs = ["1 + 1", "2 * 3", "10 - 4"]
        for (i, expr) in exprs.enumerated() {
            _ = try sendJSONLine(
                path: socketPath,
                body: #"{"method":"cache.arithmetic","params":{"expression":"\#(expr)"},"requestId":\#(i)}"#
            )
        }
        let count = await cache.cacheCount
        XCTAssertEqual(count, exprs.count, "distinct expressions should each cache once")
    }

    // MARK: - Helpers

    private func sendJSONLine(path: String, body: String) throws -> [String: Any] {
        let fd = try TestUnixSocket.connect(path: path)
        defer { close(fd) }
        try TestUnixSocket.writeLine(fd: fd, line: body)
        let line = try TestUnixSocket.readLine(fd: fd)
        let data = Data(line.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
    }
}

/// Reusable POSIX Unix-socket client for tests. Mirrors the production
/// `DaemonClient` but connects by explicit path so tests can target sockets
/// outside `$TMPDIR` without polluting `socketPath(name:)`.
enum TestUnixSocket {
    static func connect(path: String, retries: Int = 20) throws -> Int32 {
        for attempt in 0..<retries {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 { throw POSIXError(.ECONNREFUSED) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                for (i, b) in pathBytes.enumerated() { buf[i] = b }
                buf[pathBytes.count] = 0
            }
            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let rc = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, addrLen)
                }
            }
            if rc == 0 {
                // Consume the server's handshake line (task 6.3) so tests
                // that follow send-a-request-get-a-response semantics see
                // only response envelopes, not the protocol version banner.
                _ = try? readLine(fd: fd)
                return fd
            }
            close(fd)
            if attempt < retries - 1 { usleep(20_000) }
        }
        throw POSIXError(.ECONNREFUSED)
    }

    static func writeLine(fd: Int32, line: String) throws {
        let payload = line + "\n"
        let bytes = Array(payload.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf -> Int in
                write(fd, buf.baseAddress! + written, buf.count - written)
            }
            if n < 0 { throw POSIXError(.EIO) }
            written += n
        }
    }

    static func readLine(fd: Int32) throws -> String {
        var bytes: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 1)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                read(fd, ptr.baseAddress, 1)
            }
            if n <= 0 {
                if bytes.isEmpty { throw POSIXError(.EIO) }
                break
            }
            if buf[0] == 0x0A { break }
            bytes.append(buf[0])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
