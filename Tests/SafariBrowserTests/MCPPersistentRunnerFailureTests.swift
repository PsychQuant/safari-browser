import Foundation
import Darwin
import XCTest
@testable import SafariBrowser

final class MCPPersistentRunnerFailureTests: XCTestCase, @unchecked Sendable {
    private final class Observer: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: [Int32] = []
        private var blocked = false
        func launched(_ pid: Int32) { lock.withLock { pids.append(pid) } }
        var count: Int { lock.withLock { pids.count } }
        func block(_ value: Bool) { lock.withLock { blocked = value } }
        var isBlocked: Bool { lock.withLock { blocked } }
    }
    private static let fixture: Result<URL, Error> = Result {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fixture")
        let log = directory.appendingPathComponent("build.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library", "-o", executable.path] + [
            "Sources/SafariBrowser/MCP/MCPWorkerWire.swift", "Sources/SafariBrowser/MCP/MCPWorkerSupervisor.swift",
            "Tests/Fixtures/MCPPersistentRunnerFixture.swift"
        ].map { root.appendingPathComponent($0).path }
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Fixture build", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: (try? String(contentsOf: log, encoding: .utf8)) ?? "Missing log"])
        }
        return executable
    }
    private func fixtureRunner(_ observer: Observer = Observer(), limit: Int = 2 * 1024 * 1024,
                               cleanup: TimeInterval = 2, loseOwnership: Bool = false) throws -> (MCPPersistentRunner, String) {
        let executable = try Self.fixture.get()
        let image = try MCPExecutableIdentity.readImage(at: executable, architecture: MCPExecutableIdentity.currentArchitecture())
        var lifecycle = MCPPersistentRunner.Lifecycle()
        lifecycle.supervisorArguments = ["supervisor"]
        lifecycle.didLaunch = { observer.launched($0) }
        lifecycle.retire = { child in
            if observer.isBlocked { return .pending }
            if loseOwnership {
                // Deliberately consume only this fixture's locally owned direct
                // child. The production owner must not signal after reported loss.
                var status: Int32 = 0
                let reaped = waitpid(child.pid, &status, WNOHANG)
                return reaped == child.pid || (reaped < 0 && errno == ECHILD) ? .ownershipLost : .pending
            }
            return child.retire(timeout: 0)
        }
        return (MCPPersistentRunner(executable: executable, environment: [:],
                                     isolatedSupervisorExecutable: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("safari-browser"), timeout: 2, outputLimit: limit,
                                     cleanupTimeout: cleanup, lifecycle: lifecycle), image)
    }
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    private func waitForFile(_ file: URL) async -> Bool {
        for _ in 0..<400 {
            if FileManager.default.fileExists(atPath: file.path) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func testCrashPartialWrongIDAndOversizedReplyNeverReplayTheEffect() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in ["effect-crash", "effect-partial", "effect-wrong-id", "effect-oversized-frame", "effect-retire"] {
            let observer = Observer()
            let (runner, image) = try fixtureRunner(observer)
            let marker = directory.appendingPathComponent(mode)
            let started = ProcessInfo.processInfo.systemUptime
            let result = await runner.run(arguments: [mode, marker.path], input: Data(), expectedImage: image)
            if mode == "effect-oversized-frame" {
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1, "Reject frame limit without waiting for EOF or command timeout")
            }
            XCTAssertNotNil(result.failure, mode)
            XCTAssertEqual(result.stdout, Data("prefix".utf8), mode)
            XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "effect\n")
            XCTAssertEqual(observer.count, 1, "No retry pair for failed invocation")
            if mode == "effect-retire" { XCTAssertEqual(result.exitCode, 17) }
            let next = await runner.run(arguments: ["ok"], input: Data(), expectedImage: image)
            XCTAssertNil(next.failure, mode); XCTAssertEqual(next.exitCode, 0)
            XCTAssertEqual(observer.count, 2)
            XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "effect\n")
            let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
        }
    }

    func testBusinessExitCodeSurvivesWorkerAndSupervisorRetirement() async throws {
        let (runner, image) = try fixtureRunner()
        let result = await runner.run(arguments: ["complete-exit"], input: Data(), expectedImage: image)
        XCTAssertEqual(result.exitCode, 17)
        XCTAssertNil(result.failure)
        let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
    }

    func testTrailingProtocolDataInvalidatesOtherwiseCompleteReply() async throws {
        let (runner, image) = try fixtureRunner()
        let result = await runner.run(arguments: ["complete-trailing"], input: Data(), expectedImage: image)
        XCTAssertNotNil(result.failure)
        let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
    }

    func testBothOutputCapsKeepExactPrefixAndExactLimitRemainsComplete() async throws {
        for mode in ["flood-stdout", "flood-stderr", "exact-limit"] {
            let (runner, image) = try fixtureRunner(limit: 1024)
            let result = await runner.run(arguments: [mode], input: Data(), expectedImage: image)
            let output = mode == "flood-stderr" ? result.stderr : result.stdout
            XCTAssertEqual(output, Data(repeating: 65, count: 1024), mode)
            XCTAssertEqual(result.truncated, mode != "exact-limit", mode)
            if mode == "exact-limit" { XCTAssertNil(result.failure); XCTAssertEqual(result.exitCode, 0) }
            else { XCTAssertNotNil(result.failure) }
            let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
        }
    }

    func testPendingCleanupQuarantinesOwnerWithoutLaunchingAnotherPair() async throws {
        let observer = Observer()
        let (runner, image) = try fixtureRunner(observer, cleanup: 0.02)
        _ = await runner.run(arguments: ["ok"], input: Data(), expectedImage: image)
        observer.block(true)
        let failed = await runner.run(arguments: ["complete-exit"], input: Data(), expectedImage: image)
        XCTAssertTrue(failed.failure?.contains("pending") == true)
        let refused = await runner.run(arguments: ["ok"], input: Data(), expectedImage: image)
        XCTAssertTrue(refused.failure?.contains("not executed") == true)
        XCTAssertEqual(observer.count, 1)
        let incomplete = await runner.shutdown()
        XCTAssertNotNil(incomplete)
        observer.block(false)
        let cleaned = await runner.shutdown()
        XCTAssertNil(cleaned, "Same reservation can be cleaned after the observation resumes")
        XCTAssertEqual(observer.count, 1)
    }

    func testIdleEOFRebuildsBeforeSendingTheNextDistinctRequest() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trigger = directory.appendingPathComponent("trigger"), ready = directory.appendingPathComponent("ready")
        let observer = Observer()
        let (runner, image) = try fixtureRunner(observer)
        let first = await runner.run(arguments: ["close-idle", trigger.path, ready.path], input: Data(), expectedImage: image)
        XCTAssertNil(first.failure)
        try Data().write(to: trigger)
        let prepared = await waitForFile(ready); XCTAssertTrue(prepared)
        let next = await runner.run(arguments: ["ok"], input: Data(), expectedImage: image)
        XCTAssertNil(next.failure)
        XCTAssertEqual(next.exitCode, 0)
        XCTAssertNotEqual(next.stdout, first.stdout)
        XCTAssertEqual(observer.count, 2)
        let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
    }

    func testLostOwnershipRefusesSubsequentCallsAndReportsShutdownFailure() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("effect")
        let observer = Observer()
        let (runner, image) = try fixtureRunner(observer, loseOwnership: true)
        let result = await runner.run(arguments: ["effect-crash", marker.path], input: Data(), expectedImage: image)
        XCTAssertTrue(result.failure?.contains("ownership was lost") == true)
        let refused = await runner.run(arguments: ["ok"], input: Data(), expectedImage: image)
        XCTAssertTrue(refused.failure?.contains("not executed") == true)
        XCTAssertEqual(observer.count, 1)
        let shutdown = await runner.shutdown()
        XCTAssertTrue(shutdown?.contains("ownership was lost") == true)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "effect\n")
    }

    func testMissingLaunchPathInvalidatesWarmRunnerUntilRestart() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try Self.fixture.get(), alias = directory.appendingPathComponent("worker")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
        let image = try MCPExecutableIdentity.readImage(at: executable, architecture: MCPExecutableIdentity.currentArchitecture())
        let observer = Observer()
        var lifecycle = MCPPersistentRunner.Lifecycle()
        lifecycle.supervisorArguments = ["supervisor"]; lifecycle.didLaunch = { observer.launched($0) }
        let runner = MCPPersistentRunner(executable: alias, lifecycle: lifecycle)
        let first = await runner.run(arguments: ["ok"], input: Data(), expectedImage: image)
        XCTAssertNil(first.failure)
        try FileManager.default.removeItem(at: alias)
        let absent = await runner.run(arguments: ["ok"], input: Data(), expectedImage: image)
        XCTAssertTrue(absent.failure?.contains("executable changed") == true)
        XCTAssertTrue(absent.failure?.contains("not executed") == true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
        let restored = await runner.run(arguments: ["ok"], input: Data(), expectedImage: image)
        XCTAssertTrue(restored.failure?.contains("restart") == true)
        XCTAssertEqual(observer.count, 1)
        let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
    }

    func testPrivateEncodingExpansionKeepsPublicInputAdmission() async throws {
        let count = 470_000
        try XCTSkipIf(sysconf(_SC_ARG_MAX) / 2 < count + 16_384, "This OS routes this argv before private encoding")
        let (runner, image) = try fixtureRunner()
        let arguments = ["large", String(repeating: "\u{0001}", count: count)]
        let input = Data(repeating: 97, count: 4 * 1024 * 1024)
        // The public UTF-8 JSON input fits 8 MiB. Private base64 expansion does not.
        let publicInput = try JSONSerialization.data(withJSONObject: ["arguments": arguments, "stdin": String(decoding: input, as: UTF8.self)])
        XCTAssertLessThan(publicInput.count, 8 * 1024 * 1024)
        let expected = await MCPProcessRunner(executable: try Self.fixture.get(), environment: [:], supervisorExecutable: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("safari-browser"), timeout: 3)
            .run(arguments: arguments, input: input, expectedImage: image)
        XCTAssertNil(expected.failure)
        XCTAssertEqual(expected.stdout, Data("isolated\n".utf8))
        let actual = await runner.run(arguments: arguments, input: input, expectedImage: image)
        XCTAssertEqual(actual.exitCode, expected.exitCode)
        XCTAssertEqual(actual.stdout, expected.stdout)
        XCTAssertEqual(actual.stderr, expected.stderr)
        XCTAssertNil(actual.failure)
        let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
    }

    func testLargeArgPreselectionKeepsOriginalKernelAdmissionAndCanBeCancelled() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let observer = Observer()
        let (runner, image) = try fixtureRunner(observer)
        _ = await runner.run(arguments: ["ok"], input: Data(), expectedImage: image)
        let maximum = sysconf(_SC_ARG_MAX)
        XCTAssertGreaterThan(maximum, 0)
        // Exceed the specified half-ARG_MAX route boundary, without depending
        // on a particular OS limit or exceeding a per-argument string limit.
        let padding = Array(repeating: String(repeating: "x", count: 4096), count: maximum / 2 / 4096 + 1)
        let arguments = ["large"] + padding
        let expected = await MCPProcessRunner(executable: try Self.fixture.get(), environment: [:], supervisorExecutable: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("safari-browser"), timeout: 2)
            .run(arguments: arguments, input: Data(), expectedImage: image)
        let actual = await runner.run(arguments: arguments, input: Data(), expectedImage: image)
        XCTAssertEqual(actual.stdout, expected.stdout); XCTAssertEqual(actual.stderr, expected.stderr)
        XCTAssertEqual(actual.exitCode, expected.exitCode); XCTAssertEqual(actual.failure, expected.failure)
        XCTAssertEqual(observer.count, 1, "Large argv must select original runner, not another persistent pair")
        let marker = directory.appendingPathComponent("started")
        let active = Task { await runner.run(arguments: ["block", marker.path] + padding, input: Data(), expectedImage: image) }
        let started = await waitForFile(marker); XCTAssertTrue(started, "Fixture must actually reach the isolated execution")
        let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
        let result = await active.value
        XCTAssertTrue(result.cancelled); XCTAssertNotNil(result.failure)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "effect\n")
    }
}
