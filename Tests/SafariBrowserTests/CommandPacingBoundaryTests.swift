import Foundation
import ArgumentParser
import XCTest
@testable import SafariBrowser

final class CommandPacingBoundaryTests: XCTestCase, @unchecked Sendable {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool?] = []
        func append(_ value: Bool?) { lock.withLock { values.append(value) } }
        func reset() { lock.withLock { values.removeAll() } }
        var snapshot: [Bool?] { lock.withLock { values } }
    }
    private struct OwnedAsyncCommand: AsyncParsableCommand {
        static let recorder = Recorder()
        func run() async throws { Self.recorder.append(CommandPacing.currentEnabled) }
    }
    private struct OwnedSyncCommand: ParsableCommand {
        static let recorder = Recorder()
        func run() throws { Self.recorder.append(CommandPacing.currentEnabled) }
    }
    private var enabled: [String: String] {
        ["SAFARI_BROWSER_PACING": "cauchy", "SAFARI_BROWSER_PACING_MIN_MS": "1",
         "SAFARI_BROWSER_PACING_MEDIAN_MS": "2", "SAFARI_BROWSER_PACING_MAX_MS": "3"]
    }
    private func run(_ environment: [String: String], arguments: [String] = ["history", "--limit", "0"]) async -> (Int32, String) {
        var diagnostic = Data()
        let code = await CLIExecution.execute(arguments: arguments, mode: .persistent,
            environment: environment, diagnosticSink: { _, bytes in diagnostic.append(bytes) })
        return (code, String(decoding: diagnostic, as: UTF8.self))
    }

    func testInvalidEnabledPolicyPrecedesCommandRuntimeFailure() async {
        // History rejects limit0 before opening any user database. The pacing
        // error must win even over this deterministic operation-level error.
        let invalid: [[String: String]] = [
            ["SAFARI_BROWSER_PACING": "owned-invalid-value"],
            ["SAFARI_BROWSER_PACING_MIN_MS": "-1"],
            ["SAFARI_BROWSER_PACING_MAX_MS": "3600001"],
            ["SAFARI_BROWSER_PACING_MEDIAN_MS": "nan"],
            ["SAFARI_BROWSER_PACING_SCALE_MS": "0"],
            ["SAFARI_BROWSER_PACING_MIN_MS": "owned-invalid-number"],
            ["SAFARI_BROWSER_PACING_MIN_MS": "0", "SAFARI_BROWSER_PACING_MEDIAN_MS": "0.0000005", "SAFARI_BROWSER_PACING_MAX_MS": "0.000001"],
        ]
        for fields in invalid {
            let environment = ["SAFARI_BROWSER_PACING": "cauchy"].merging(fields, uniquingKeysWith: { _, new in new })
            let result = await run(environment)
            XCTAssertEqual(result.0, 64)
            XCTAssertTrue(result.1.contains("SAFARI_BROWSER_PACING"), result.1)
            XCTAssertFalse(result.1.contains("--limit"), "Configuration must fail before operation")
            XCTAssertFalse(result.1.contains("owned-invalid"), "Do not echo arbitrary environment values")
        }
    }

    func testDisabledPolicyIgnoresAncillaryConfiguration() async {
        for mode in [nil, "", "off"] as [String?] {
            var environment = ["SAFARI_BROWSER_PACING_MIN_MS": "owned-invalid-number"]
            environment["SAFARI_BROWSER_PACING"] = mode
            let result = await run(environment)
            XCTAssertEqual(result.0, 64)
            XCTAssertTrue(result.1.contains("--limit must be a positive integer"))
            XCTAssertFalse(result.1.contains("SAFARI_BROWSER_PACING"))
        }
    }

    func testEnabledPolicyWaitsAfterRuntimeFailure() async {
        _ = await run([:]) // Warm the actual parser/command before timing.
        let start = ProcessInfo.processInfo.systemUptime
        let result = await run(["SAFARI_BROWSER_PACING": "cauchy",
            "SAFARI_BROWSER_PACING_MIN_MS": "300", "SAFARI_BROWSER_PACING_MEDIAN_MS": "350",
            "SAFARI_BROWSER_PACING_MAX_MS": "400"])
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(result.0, 64)
        XCTAssertTrue(result.1.contains("--limit must be a positive integer"))
        XCTAssertGreaterThanOrEqual(elapsed, 0.29, "Enabled pacing must wait after an admitted runtime failure")
        XCTAssertLessThan(elapsed, 3, "Small configured waits must remain bounded")
    }

    func testHelpRemainsAvailableWithInvalidPolicy() async {
        let result = await run(["SAFARI_BROWSER_PACING": "owned-invalid-value"], arguments: ["history", "--help"])
        XCTAssertEqual(result.0, 0)
        XCTAssertTrue(result.1.contains("USAGE: safari-browser history"))
        XCTAssertFalse(result.1.contains("owned-invalid-value"))
    }

    func testBareCommandGroupsKeepUsageAvailable() async {
        for group in ["get", "storage", "cookies", "mouse", "is"] {
            let result = await run(["SAFARI_BROWSER_PACING": "owned-invalid-mode"], arguments: [group])
            XCTAssertEqual(result.0, 0, group)
            XCTAssertTrue(result.1.contains("USAGE: safari-browser " + group), result.1)
            XCTAssertFalse(result.1.contains("SAFARI_BROWSER_PACING"), result.1)
        }
    }

    func testOneShotWrapperUsesSuppliedEnvironmentAndSleepsExactlyOnce() async throws {
        var wrapper = MCPWorkerCommand()
        wrapper.arguments = ["history", "--limit", "0"]
        var sleeps = 0
        do {
            try await CLIExecution.runParsed(wrapper, environment: [MCPWorkerContext.directKey: "1",
                MCPWorkerContext.imageKey: "owned-fixture", "SAFARI_BROWSER_PACING": "cauchy",
                "SAFARI_BROWSER_PACING_MIN_MS": "1", "SAFARI_BROWSER_PACING_MEDIAN_MS": "2",
                "SAFARI_BROWSER_PACING_MAX_MS": "3"], sleep: { _ in sleeps += 1 })
            XCTFail("Owned runtime error must propagate")
        } catch {
            XCTAssertTrue(SafariBrowser.message(for: error).contains("--limit must be a positive integer"))
        }
        XCTAssertEqual(sleeps, 1, "The hidden wrapper must not add a second wait or skip its inner command")
        XCTAssertNil(CommandPacing.currentEnabled)
    }

    func testSuccessfulSyncAndAsyncCommandsWaitOnceAndRestorePolicyScope() async throws {
        OwnedAsyncCommand.recorder.reset(); OwnedSyncCommand.recorder.reset()
        var sleeps = 0
        for command: any ParsableCommand in [OwnedAsyncCommand(), OwnedSyncCommand()] {
            try await CLIExecution.runParsed(command, environment: enabled, sleep: { ns in
                XCTAssertGreaterThan(ns, 1_000_000); XCTAssertLessThan(ns, 3_000_000); sleeps += 1
            })
            XCTAssertNil(CommandPacing.currentEnabled)
            try await CLIExecution.runParsed(command, environment: [:], sleep: { _ in XCTFail("Disabled invocation slept") })
            XCTAssertNil(CommandPacing.currentEnabled)
        }
        XCTAssertEqual(sleeps, 2)
        XCTAssertEqual(OwnedAsyncCommand.recorder.snapshot, [true, false])
        XCTAssertEqual(OwnedSyncCommand.recorder.snapshot, [true, false])
    }

    func testExplicitWaitAndEmptyBatchHaveNoAdditionalSleep() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("empty.json")
        try Data("[]".utf8).write(to: source)
        for arguments in [["wait", "0"], ["exec", "--script", source.path]] {
            let command = try SafariBrowser.parseAsRoot(arguments)
            try await CLIExecution.runParsed(command, environment: enabled, sleep: { _ in XCTFail("Container or explicit wait added a sleep") })
        }
        XCTAssertNil(CommandPacing.currentEnabled)
    }

    func testParserErrorPrecedesInvalidPacingConfiguration() async {
        let result = await run(["SAFARI_BROWSER_PACING": "owned-invalid-value"], arguments: ["history", "--limit", "not-an-integer"])
        XCTAssertEqual(result.0, 64)
        XCTAssertTrue(result.1.contains("--limit"))
        XCTAssertFalse(result.1.contains("SAFARI_BROWSER_PACING"))
    }

    func testDaemonControlsReachOwnedPathValidationWithoutPacing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("owned-missing-directory")
        for action in ["start", "stop", "status", "logs"] {
            let command = try SafariBrowser.parseAsRoot(["daemon", action, "--socket-dir", missing.path, "--name", "owned-pacing"])
            do {
                try await CLIExecution.runParsed(command, environment: ["SAFARI_BROWSER_PACING": "owned-invalid-mode"],
                    sleep: { _ in XCTFail("Daemon control added pacing") })
                XCTFail("Owned nonexistent directory must be rejected before daemon dispatch")
            } catch {
                let message = SafariBrowser.message(for: error)
                XCTAssertFalse(message.contains("SAFARI_BROWSER_PACING"), message)
                XCTAssertTrue(message.contains("directory"), message)
            }
        }
    }
}
