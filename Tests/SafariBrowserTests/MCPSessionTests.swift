import Foundation
import XCTest
@testable import SafariBrowser

private actor MCPResponses {
    var values: [JSONValue] = []
    func append(_ data: Data) throws { values.append(try JSONValue.decode(data)) }
    func snapshot() -> [JSONValue] { values }
}
private actor MCPMockRunner: MCPCommandRunning {
    var invocations: [[String]] = []
    var inputs: [Data] = []
    let delay: UInt64
    init(delay: UInt64 = 0) { self.delay = delay }
    func run(arguments: [String], input: Data, expectedImage: String) async -> MCPCommandResult {
        invocations.append(arguments); inputs.append(input)
        do { try await Task.sleep(nanoseconds: delay) }
        catch { return MCPCommandResult(stdout: Data(), stderr: Data(), exitCode: nil, cancelled: true, truncated: false, failure: "cancelled") }
        return MCPCommandResult(stdout: input, stderr: Data("diagnostic".utf8), exitCode: 7, cancelled: false, truncated: false, failure: nil)
    }
    func count() -> Int { invocations.count }
}

final class MCPSessionTests: XCTestCase, @unchecked Sendable {
    func request(_ method: String, id: JSONValue = .int(1), params: [String: JSONValue] = [:], modern: Bool = true) throws -> Data {
        var p = params
        if modern { p["_meta"] = .object([MCPSession.versionKey: .string(MCPSession.modernVersion), MCPSession.capabilitiesKey: .object([:])]) }
        return try JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "method": .string(method), "params": .object(p)]).encoded()
    }
    private func fixture(delay: UInt64 = 0) throws -> (MCPSession, MCPResponses, MCPMockRunner) {
        let output = MCPResponses(), runner = MCPMockRunner(delay: delay)
        let catalog = try MCPToolCatalog(metadata: Data(SafariBrowser._dumpHelp().utf8))
        return (MCPSession(catalog: catalog, runner: runner, expectedImage: "fixture", output: { try await output.append($0) }), output, runner)
    }
    private func drain(_ output: MCPResponses, count: Int) async throws -> [JSONValue] {
        for _ in 0..<200 {
            let values = await output.snapshot()
            if values.count >= count { return values }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("response deadline")
        return await output.snapshot()
    }
    func testModernDiscoveryPaginationAndVersionErrors() async throws {
        let (session, output, runner) = try fixture()
        try await session.receive(request("server/discover"))
        try await session.receive(request("tools/list", id: .int(2)))
        var values = await output.snapshot()
        XCTAssertEqual(values.count, 2)
        guard values.count == 2 else { return }
        XCTAssertEqual(values[0]["result"]?["resultType"], .string("complete"))
        XCTAssertEqual(values[1]["result"]?["tools"]?.arrayValue?.count, 50)
        let cursor = try XCTUnwrap(values[1]["result"]?["nextCursor"])
        try await session.receive(request("tools/list", id: .int(3), params: ["cursor": cursor]))
        try await session.receive(request("tools/list", id: .int(4), params: ["cursor": .string("garbage")]))
        try await session.receive(request("server/discover", id: .int(5), modern: false))
        let unknown = JSONValue.object(["jsonrpc": .string("2.0"), "id": .int(6), "method": .string("ping"), "params": .object(["_meta": .object([MCPSession.versionKey: .string("future"), MCPSession.capabilitiesKey: .object([:])])])])
        try await session.receive(unknown.encoded())
        values = await output.snapshot()
        XCTAssertEqual(values[2]["result"]?["tools"]?.arrayValue?.count, 26)
        XCTAssertNil(values[2]["result"]?["nextCursor"])
        XCTAssertEqual(values[3]["error"]?["code"], .int(-32602))
        XCTAssertEqual(values[4]["error"]?["code"], .int(-32602))
        XCTAssertEqual(values[5]["error"]?["code"], .int(-32022))
        let count = await runner.count(); XCTAssertEqual(count, 0)
    }
    func testLegacyInitializationAndFramingErrorsDoNotExecute() async throws {
        let (session, output, runner) = try fixture()
        try await session.receive(request("tools/list", modern: false))
        try await session.receive(request("initialize", id: .int(2), params: ["protocolVersion": .string("2025-06-18"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])], modern: false))
        try await session.receive(request("tools/list", id: .int(3), modern: false))
        try await session.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        try await session.receive(request("tools/list", id: .int(4), modern: false))
        try await session.receive(Data("[1,]".utf8))
        try await session.receive(request("ping", id: .bool(true)))
        let values = await output.snapshot()
        XCTAssertEqual(values.count, 6)
        guard values.count == 6 else { return }
        XCTAssertNotNil(values[0]["error"])
        XCTAssertEqual(values[1]["result"]?["protocolVersion"], .string("2025-06-18"))
        XCTAssertNotNil(values[2]["error"])
        XCTAssertNil(values[3]["result"]?["resultType"])
        XCTAssertEqual(values[3]["result"]?["tools"]?.arrayValue?.count, 50)
        XCTAssertEqual(values[4]["error"]?["code"], .int(-32700))
        XCTAssertEqual(values[5]["error"]?["code"], .int(-32600))
        let count = await runner.count(); XCTAssertEqual(count, 0)
    }
    func testToolStreamsAndBusyRemainResponsive() async throws {
        let (session, output, runner) = try fixture(delay: 100_000_000)
        let params: [String: JSONValue] = ["name": .string("safari.wait"), "arguments": .object(["positionals": .object(["milliseconds": .string("0")]), "stdin": .string("payload")])]
        try await session.receive(request("tools/call", params: params))
        try await session.receive(request("tools/call", id: .int(2), params: params))
        try await session.receive(request("ping", id: .int(3)))
        let values = try await drain(output, count: 3)
        guard values.count == 3 else { return }
        XCTAssertEqual(values[0]["id"], .int(2))
        XCTAssertEqual(values[0]["result"]?["isError"], .bool(true))
        XCTAssertEqual(values[1]["id"], .int(3))
        XCTAssertEqual(values[2]["id"], .int(1))
        let result = values[2]["result"]
        XCTAssertEqual(result?["structuredContent"]?["stdout"]?["data"], .string("payload"))
        XCTAssertEqual(result?["structuredContent"]?["stderr"]?["data"], .string("diagnostic"))
        XCTAssertEqual(result?["structuredContent"]?["exit_code"], .int(7))
        XCTAssertEqual(result?["isError"], .bool(true))
        let count = await runner.count(); XCTAssertEqual(count, 1)
    }
    func testCancellationAndDuplicateIDNeverExecuteTwiceOrReplyLate() async throws {
        let (session, output, runner) = try fixture(delay: 10_000_000_000)
        let params: [String: JSONValue] = ["name": .string("safari.wait"), "arguments": .object(["positionals": .object(["milliseconds": .string("0")])])]
        try await session.receive(request("tools/call", id: .string("active"), params: params))
        try await session.receive(request("tools/call", id: .string("active"), params: params))
        try await session.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"active"}}"#.utf8))
        await session.shutdown()
        let values = await output.snapshot()
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?["id"], .null)
        XCTAssertEqual(values.first?["error"]?["code"], .int(-32600))
        let count = await runner.count(); XCTAssertLessThanOrEqual(count, 1)
    }
    func testBinaryOutputAndCaptureFailureAreExplicit() throws {
        let result = JSONValue.object(MCPSession.toolResult(MCPCommandResult(stdout: Data([0xff, 0x00]), exitCode: 0)))
        XCTAssertEqual(result["structuredContent"]?["stdout"]?["encoding"], .string("base64"))
        XCTAssertEqual(result["structuredContent"]?["stdout"]?["data"], .string("/wA="))
        XCTAssertEqual(result["isError"], .bool(false))
        let incomplete = JSONValue.object(MCPSession.toolResult(MCPCommandResult(exitCode: 0, truncated: true, failure: "limit")))
        XCTAssertEqual(incomplete["isError"], .bool(true))
        XCTAssertEqual(incomplete["structuredContent"]?["capture_complete"], .bool(false))
    }
    func testMalformedAndUnknownToolsNeverReachRunner() async throws {
        let (session, output, runner) = try fixture()
        try await session.receive(request("tools/call", params: ["name": .string("missing")]))
        try await session.receive(request("tools/call", id: .int(2), params: ["name": .string("safari.wait"), "arguments": .object(["options": .object(["unknown": .bool(true)])])]))
        try await session.receive(request("tools/call", id: .int(3), params: ["name": .string("safari.wait"), "arguments": .array([])]))
        let values = await output.snapshot()
        XCTAssertEqual(values[0]["error"]?["code"], .int(-32602))
        XCTAssertEqual(values[1]["result"]?["isError"], .bool(true))
        XCTAssertEqual(values[2]["error"]?["code"], .int(-32602))
        let count = await runner.count(); XCTAssertEqual(count, 0)
    }

    func testLargeRequestIDAndOversizedResultStayBounded() async throws {
        let (session, output, _) = try fixture()
        let identifier = JSONValue.string(String(repeating: "a", count: MCPSession.maximumFrameBytes - 350))
        let frame = try request("tools/call", id: identifier, params: ["name": .string("safari.wait"), "arguments": .object(["positionals": .object(["milliseconds": .string("0")])])])
        XCTAssertLessThanOrEqual(frame.count, MCPSession.maximumFrameBytes)
        try await session.receive(frame)
        let values = try await drain(output, count: 1)
        guard let value = values.first else { return }
        XCTAssertNotNil(value["error"])
        XCTAssertLessThanOrEqual(try value.encoded().count, MCPSession.maximumFrameBytes)
    }

    func testLegacyProgressMetadataAndModernPartialMetadata() async throws {
        let (session, output, _) = try fixture()
        try await session.receive(request("initialize", params: ["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("fixture"), "version": .string("1")]), "_meta": .object(["progressToken": .string("init")])], modern: false))
        var values = await output.snapshot()
        XCTAssertNotNil(values.first?["result"])
        try await session.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        try await session.receive(request("tools/list", id: .int(2), params: ["_meta": .object(["progressToken": .int(1)])], modern: false))
        try await session.receive(request("ping", id: .int(3), params: ["_meta": .object([MCPSession.capabilitiesKey: .object([:])])], modern: false))
        values = await output.snapshot()
        XCTAssertNotNil(values[1]["result"])
        XCTAssertEqual(values[2]["error"]?["code"], .int(-32602))
    }

}
