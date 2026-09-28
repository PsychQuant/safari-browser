import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

private actor ShutdownProbe: MCPCommandRunning {
    private var events: [String] = []
    let failure: String?
    init(failure: String? = nil) { self.failure = failure }
    func run(arguments: [String], input: Data, expectedImage: String) async -> MCPCommandResult {
        events.append("running")
        do { try await Task.sleep(for: .seconds(5)) }
        catch { events.append("cancelled"); return MCPCommandResult(cancelled: true, failure: "cancelled") }
        return MCPCommandResult(exitCode: 0)
    }
    func shutdown() async -> String? { events.append("shutdown"); return failure }
    func snapshot() -> [String] { events }
}
final class MCPModeIntegrationTests: XCTestCase, @unchecked Sendable {
    func testDefaultPersistentAndExplicitModesAndIdleBounds() throws {
        XCTAssertEqual(try MCPCommand.parse([]).workerMode, .persistent)
        XCTAssertEqual(try MCPCommand.parse([]).workerIdleTimeout, 30)
        XCTAssertEqual(try MCPCommand.parse(["--worker-mode", "isolated"]).workerMode, .isolated)
        XCTAssertEqual(try MCPCommand.parse(["--worker-mode=persistent", "--worker-idle-timeout=0.001"]).workerIdleTimeout, 0.001)
        XCTAssertEqual(try MCPCommand.parse(["--worker-idle-timeout=86400"]).workerIdleTimeout, 86400)
        for value in ["0", "-1", "nan", "inf", "0.0009", "86401"] {
            XCTAssertThrowsError(try MCPCommand.parse(["--worker-idle-timeout=" + value]), value)
        }
        XCTAssertThrowsError(try MCPCommand.parse(["--worker-mode=unknown"]))
    }
    private func session(_ runner: ShutdownProbe) throws -> MCPSession {
        MCPSession(catalog: try MCPToolCatalog(metadata: Data(SafariBrowser._dumpHelp().utf8)), runner: runner,
                   expectedImage: "fixture", output: { _ in })
    }
    func testIdleShutdownCallsRunnerOnceAndSurfacesCleanupFailure() async throws {
        let runner = ShutdownProbe(failure: "Worker cleanup is pending")
        let session = try session(runner)
        async let first: Void = session.shutdown()
        async let second: Void = session.shutdown()
        _ = await (first, second)
        await session.shutdown()
        let events = await runner.snapshot()
        XCTAssertEqual(events, ["shutdown"])
        let failure = await session.terminalFailure()
        XCTAssertEqual(failure, "Worker cleanup is pending")
    }
    func testActiveShutdownWaitsForCancellationThenCleansRunner() async throws {
        let runner = ShutdownProbe(), session = try session(runner)
        let request = try JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
            "params": .object(["name": .string("safari.wait"), "arguments": .object(["positionals": .object(["milliseconds": .string("0")])]),
                "_meta": .object([MCPSession.versionKey: .string(MCPSession.modernVersion), MCPSession.capabilitiesKey: .object([:])])])
        ]).encoded()
        try await session.receive(request)
        for _ in 0..<100 {
            if await runner.snapshot().contains("running") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await session.shutdown()
        let events = await runner.snapshot()
        XCTAssertEqual(events, ["running", "cancelled", "shutdown"])
    }
}
