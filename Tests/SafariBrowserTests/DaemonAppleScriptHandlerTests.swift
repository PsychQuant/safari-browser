import XCTest
import Foundation
import Darwin
@testable import SafariBrowser

/// Task 7.1 — `applescript.execute` daemon method. This is the single
/// Phase 1 handler that `SafariBridge.runAppleScript` routes through when
/// daemon mode is opted in, so every Phase 1 command inherits daemon
/// acceleration transparently.
final class DaemonAppleScriptHandlerTests: XCTestCase {

    var socketPath: String!
    var server: DaemonServer.Instance!
    var cache: PreCompiledScripts.CompileCache!

    override func setUp() async throws {
        try await super.setUp()
        socketPath = "\(NSTemporaryDirectory())as-\(UUID().uuidString.prefix(8)).sock"
        server = DaemonServer.Instance()
        cache = PreCompiledScripts.CompileCache()
        await DaemonDispatch.registerPhase1Handlers(on: server, cache: cache)
        try await server.start(socketPath: socketPath)
    }

    override func tearDown() async throws {
        await server.stop()
        unlink(socketPath)
        try await super.tearDown()
    }

    // MARK: - Success path

    func testAppleScriptExecute_returnsStringOutput() async throws {
        let response = try sendJSONLine(
            body: #"{"method":"applescript.execute","params":{"source":"return \"hello\""},"requestId":1}"#
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["output"] as? String, "hello")
    }

    func testAppleScriptExecute_arithmeticReturnsIntegerAsString() async throws {
        let response = try sendJSONLine(
            body: #"{"method":"applescript.execute","params":{"source":"return 40 + 2"},"requestId":1}"#
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "ok")
        // NSAppleEventDescriptor.stringValue on an integer descriptor gives "42".
        XCTAssertEqual(result["output"] as? String, "42")
    }

    // MARK: - Cache re-use (Path A verification on the real handler)

    func testAppleScriptExecute_sameSourceTwice_cacheCountIsOne() async throws {
        _ = try sendJSONLine(body: #"{"method":"applescript.execute","params":{"source":"return 7"},"requestId":1}"#)
        _ = try sendJSONLine(body: #"{"method":"applescript.execute","params":{"source":"return 7"},"requestId":2}"#)
        let count = await cache.cacheCount
        XCTAssertEqual(count, 1, "identical source should not grow cache past 1")
    }

    // MARK: - Failure paths surface as structured error responses

    func testAppleScriptExecute_compileError_returnsStructuredError() async throws {
        // Broken AppleScript — missing `end tell` etc. NSAppleScript refuses
        // to compile it.
        let response = try sendJSONLine(
            body: #"{"method":"applescript.execute","params":{"source":"tell application \"Safari\" blah"},"requestId":1}"#
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "error")
        XCTAssertEqual(result["errorKind"] as? String, "compileFailed")
        XCTAssertNotNil(result["message"] as? String)
    }

    func testAppleScriptExecute_executeError_returnsStructuredError() async throws {
        // Compiles fine but throws at runtime via `error`.
        let response = try sendJSONLine(
            body: #"{"method":"applescript.execute","params":{"source":"error \"boom\" number 9999"},"requestId":1}"#
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "error")
        XCTAssertEqual(result["errorKind"] as? String, "executeFailed")
        let message = try XCTUnwrap(result["message"] as? String)
        XCTAssertTrue(message.contains("boom"), "error message should include AppleScript-reported reason; got: \(message)")
    }

    // MARK: - Missing params is handlerError

    func testAppleScriptExecute_missingSource_returnsHandlerError() async throws {
        let response = try sendJSONLine(
            body: #"{"method":"applescript.execute","params":{},"requestId":1}"#
        )
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "handlerError")
    }

    // MARK: - Raw socket helper

    private func sendJSONLine(body: String) throws -> [String: Any] {
        let fd = try TestUnixSocket.connect(path: socketPath)
        defer { close(fd) }
        try TestUnixSocket.writeLine(fd: fd, line: body)
        let line = try TestUnixSocket.readLine(fd: fd)
        let data = Data(line.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
    }
}
