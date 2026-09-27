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
    var daemonName: String!
    var server: DaemonServer.Instance!
    var cache: PreCompiledScripts.CompileCache!

    override func setUp() async throws {
        try await super.setUp()
        daemonName = "as-\(UUID().uuidString.prefix(8))"
        socketPath = DaemonClient.socketPath(dir: NSTemporaryDirectory(), name: daemonName)
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

    func testEphemeralRPCSelectsNonRetainingExecutionAndRestoresPolicy() async throws {
        var elapsed: [UInt64] = []
        for value in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            let output = try await DaemonRequestContext.$appleScriptCachePolicy.withValue(.ephemeral) {
                try await SafariBridge.executeAppleScriptViaDaemon(
                    source: "return \(value)", timeout: 2, name: daemonName, socketDir: NSTemporaryDirectory())
            }
            elapsed.append(DispatchTime.now().uptimeNanoseconds - start)
            XCTAssertEqual(output, String(value))
        }
        let ordered = elapsed.sorted()
        let metric: [String: Any] = ["kind": "ephemeral AppleScript return-fixture RPC", "samples": elapsed.count,
            "p50Nanoseconds": ordered[ordered.count / 2], "p95Nanoseconds": ordered[Int(Double(ordered.count - 1) * 0.95)]]
        print("EPHEMERAL_RPC_METRIC " + String(decoding: try JSONSerialization.data(withJSONObject: metric, options: [.sortedKeys]), as: UTF8.self))
        let transientCount = await cache.cacheCount
        XCTAssertEqual(transientCount, 0)
        var reusableTimes: [UInt64] = []
        for _ in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await SafariBridge.executeAppleScriptViaDaemon(
                source: "return 42", timeout: 2, name: daemonName, socketDir: NSTemporaryDirectory())
            reusableTimes.append(DispatchTime.now().uptimeNanoseconds - start)
        }
        let sortedReusable = reusableTimes.sorted()
        let reusableMetric: [String: Any] = ["kind": "reusable AppleScript return-fixture RPC", "samples": reusableTimes.count,
            "p50Nanoseconds": sortedReusable[sortedReusable.count / 2], "p95Nanoseconds": sortedReusable[Int(Double(sortedReusable.count - 1) * 0.95)]]
        print("REUSABLE_RPC_METRIC " + String(decoding: try JSONSerialization.data(withJSONObject: reusableMetric, options: [.sortedKeys]), as: UTF8.self))
        let stableCount = await cache.cacheCount
        XCTAssertEqual(stableCount, 1, "The task-local ephemeral policy must not leak into later requests")
    }

    func testLegacyDaemonRejectsEphemeralMethodBeforeSafeFallback() async throws {
        actor Counter {
            var calls = 0
            func called() { calls += 1 }
        }
        let counter = Counter()
        await server.stop()
        server = DaemonServer.Instance()
        await server.register("applescript.execute") { _ in
            await counter.called()
            return Data(#"{"status":"ok","output":"wrong-path"}"#.utf8)
        }
        try await server.start(socketPath: socketPath)
        var fallbackCalls = 0
        let value = try await DaemonRequestContext.$appleScriptCachePolicy.withValue(.ephemeral) {
            try await SafariBridge.runViaRouter(source: "return 42", daemonOptIn: true,
                daemonFn: { source in
                    try await SafariBridge.executeAppleScriptViaDaemon(
                        source: source, timeout: 2, name: self.daemonName, socketDir: NSTemporaryDirectory())
                }, statelessFn: { _ in fallbackCalls += 1; return "fallback-result" })
        }
        XCTAssertEqual(value, "fallback-result")
        XCTAssertEqual(fallbackCalls, 1)
        let legacyExecutions = await counter.calls
        XCTAssertEqual(legacyExecutions, 0, "An old daemon must not execute then ignore a cache hint")
    }

    func testEphemeralCompileAndRuntimeErrorsDoNotCreateCacheEntries() async throws {
        for source in ["this is invalid AppleScript !!!", "error \"owned failure\" number 9999"] {
            do {
                _ = try await DaemonRequestContext.$appleScriptCachePolicy.withValue(.ephemeral) {
                    try await SafariBridge.executeAppleScriptViaDaemon(
                        source: source, timeout: 2, name: daemonName, socketDir: NSTemporaryDirectory())
                }
                XCTFail("Expected script failure")
            } catch SafariBrowserError.appleScriptFailed { }
        }
        let count = await cache.cacheCount
        XCTAssertEqual(count, 0)
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
