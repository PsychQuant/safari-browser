import XCTest
import Foundation
@testable import SafariBrowser

/// Covers the `IPC via Unix domain socket with JSON-lines protocol` spec
/// requirement. The server is exercised via a raw POSIX socket client so we
/// assert the wire format, not just the Swift API.
final class DaemonServerIPCTests: XCTestCase {
    var socketPath: String!
    var server: DaemonServer.Instance!

    override func setUp() async throws {
        try await super.setUp()
        socketPath = Self.makeTempSocketPath()
        server = DaemonServer.Instance()
    }

    override func tearDown() async throws {
        await server.stop()
        unlink(socketPath)
        try await super.tearDown()
    }

    // MARK: - Core round trip

    func testEcho_roundTrip() async throws {
        await server.register("echo") { params in params }
        try await server.start(socketPath: socketPath)

        let response = try sendRawRequest(
            path: socketPath,
            body: #"{"method":"echo","params":{"x":42},"requestId":1}"#
        )
        let json = try XCTUnwrap(response as? [String: Any])

        XCTAssertEqual(json["requestId"] as? Int, 1)
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(result["x"] as? Int, 42)
        XCTAssertNil(json["error"])
    }

    // MARK: - Request ID correlation

    func testRequestIdCorrelation_onSameConnection() async throws {
        await server.register("echo") { params in params }
        try await server.start(socketPath: socketPath)

        let responses = try sendRawRequestsSameConnection(
            path: socketPath,
            bodies: [
                #"{"method":"echo","params":{"tag":"A"},"requestId":1}"#,
                #"{"method":"echo","params":{"tag":"B"},"requestId":2}"#,
            ]
        )
        XCTAssertEqual(responses.count, 2)
        let first = try XCTUnwrap(responses[0] as? [String: Any])
        let second = try XCTUnwrap(responses[1] as? [String: Any])
        XCTAssertEqual(first["requestId"] as? Int, 1)
        XCTAssertEqual(second["requestId"] as? Int, 2)
        XCTAssertEqual((first["result"] as? [String: Any])?["tag"] as? String, "A")
        XCTAssertEqual((second["result"] as? [String: Any])?["tag"] as? String, "B")
    }

    // MARK: - Unknown method

    func testUnknownMethod_returnsError() async throws {
        try await server.start(socketPath: socketPath)

        let response = try sendRawRequest(
            path: socketPath,
            body: #"{"method":"does.not.exist","params":{},"requestId":7}"#
        )
        let json = try XCTUnwrap(response as? [String: Any])
        XCTAssertEqual(json["requestId"] as? Int, 7)
        XCTAssertNil(json["result"])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "methodNotFound")
    }

    // MARK: - Handler throws

    func testHandlerThrowing_mapsToError() async throws {
        struct Boom: Error {}
        await server.register("fail") { _ in throw Boom() }
        try await server.start(socketPath: socketPath)

        let response = try sendRawRequest(
            path: socketPath,
            body: #"{"method":"fail","params":{},"requestId":9}"#
        )
        let json = try XCTUnwrap(response as? [String: Any])
        XCTAssertEqual(json["requestId"] as? Int, 9)
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "handlerError")
    }

    // MARK: - Malformed request line

    func testMalformedJSON_returnsParseError() async throws {
        try await server.start(socketPath: socketPath)

        let response = try sendRawRequest(
            path: socketPath,
            body: "not json at all"
        )
        let json = try XCTUnwrap(response as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "parseError")
        // requestId is null when we can't parse the request itself
        XCTAssertTrue(json["requestId"] is NSNull || json["requestId"] == nil)
    }

    // MARK: - Stop cleanup

    func testStop_removesSocketFile() async throws {
        try await server.start(socketPath: socketPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    // MARK: - Helpers

    private static func makeTempSocketPath() -> String {
        let dir = NSTemporaryDirectory()
        let suffix = UUID().uuidString.prefix(8)
        // Keep short — sun_path is ~104 chars on macOS, and $TMPDIR can be long.
        return "\(dir)sbt-\(suffix).sock"
    }

    /// Connects, writes one line, reads one response line, closes.
    private func sendRawRequest(path: String, body: String) throws -> Any {
        let fd = try Self.connectUnixSocket(path: path)
        defer { close(fd) }
        try Self.writeLine(fd: fd, line: body)
        let line = try Self.readLine(fd: fd)
        let data = Data(line.utf8)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Sends multiple bodies on a single connection and collects responses in order.
    private func sendRawRequestsSameConnection(path: String, bodies: [String]) throws -> [Any] {
        let fd = try Self.connectUnixSocket(path: path)
        defer { close(fd) }
        for body in bodies {
            try Self.writeLine(fd: fd, line: body)
        }
        var responses: [Any] = []
        for _ in bodies {
            let line = try Self.readLine(fd: fd)
            let data = Data(line.utf8)
            responses.append(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        }
        return responses
    }

    private static func connectUnixSocket(path: String, retries: Int = 10) throws -> Int32 {
        // Server-start may not have bound yet; retry briefly.
        for attempt in 0..<retries {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 { throw POSIXError(.ECONNREFUSED) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutableBytes(of: &addr.sun_path) { pathBuf -> Int in
                let dest = pathBuf.baseAddress!.assumingMemoryBound(to: CChar.self)
                _ = path.withCString { src -> Int in
                    let maxLen = pathBuf.count - 1
                    strncpy(dest, src, maxLen)
                    dest[maxLen] = 0
                    return 0
                }
                return 0
            }
            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let rc = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            if rc == 0 {
                // Consume the server's handshake line (task 6.3).
                _ = try? Self.readLine(fd: fd)
                return fd
            }
            close(fd)
            if attempt < retries - 1 {
                usleep(20_000) // 20 ms
            }
        }
        throw POSIXError(.ECONNREFUSED)
    }

    private static func writeLine(fd: Int32, line: String) throws {
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

    private static func readLine(fd: Int32) throws -> String {
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
            if buf[0] == 0x0A { break } // newline
            bytes.append(buf[0])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
