import Foundation
import Darwin
import XCTest
@testable import SafariBrowser

final class MCPPersistentRunnerTests: XCTestCase, @unchecked Sendable {
    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("safari-browser")
    }
    private func identity() throws -> String {
        try MCPExecutableIdentity.readImage(at: binary, architecture: MCPExecutableIdentity.currentArchitecture())
    }
    private func runner(timeout: TimeInterval = 3, idle: TimeInterval = 30, limit: Int = 2 * 1024 * 1024) -> MCPPersistentRunner {
        var environment = ProcessInfo.processInfo.environment
        environment["SAFARI_BROWSER_TRACE_TIMING"] = "1"
        return MCPPersistentRunner(executable: binary, environment: environment, timeout: timeout, idleTimeout: idle, outputLimit: limit)
    }
    private func trace(_ result: MCPCommandResult) throws -> PerformanceTrace.Summary {
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.cancelled); XCTAssertFalse(result.truncated)
        let text = String(decoding: result.stderr, as: UTF8.self)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix(PerformanceTrace.prefix) })
        return try JSONDecoder().decode(PerformanceTrace.Summary.self, from: Data(line.dropFirst(PerformanceTrace.prefix.count).utf8))
    }
    private func eventuallyExited(_ pid: Int32, timeout: TimeInterval = 2) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            var info = proc_bsdinfo()
            let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            if count == 0, errno == ESRCH { return true }
            if count == MemoryLayout<proc_bsdinfo>.size, info.pbi_status == SZOMB { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func testSequentialCallsReuseActualWorkerAndShutdownCleansIdleProcess() async throws {
        let runner = runner(), image = try identity()
        var pids = Set<Int>(), ids = Set<String>()
        for _ in 0..<5 {
            let result = await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image)
            let summary = try trace(result)
            pids.insert(try XCTUnwrap(summary.processID)); ids.insert(summary.requestID)
        }
        XCTAssertEqual(pids.count, 1); XCTAssertEqual(ids.count, 5)
        let error = await runner.shutdown()
        XCTAssertNil(error)
        if let pid = pids.first { let gone = await eventuallyExited(Int32(pid)); XCTAssertTrue(gone) }
        let after = await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image)
        XCTAssertNotNil(after.failure); XCTAssertNil(after.exitCode)
    }

    func testIdleExpiryReapsPairAndNextCallStartsFreshWorker() async throws {
        let runner = runner(idle: 0.05), image = try identity()
        let first = try trace(await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image))
        let pid = try XCTUnwrap(first.processID)
        let gone = await eventuallyExited(Int32(pid))
        XCTAssertTrue(gone, "Idle owner must actually retire without another request")
        let next = try trace(await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image))
        XCTAssertNotEqual(next.processID, pid)
        let error = await runner.shutdown(); XCTAssertNil(error)
    }

    func testBusyCancellationAndLaterDistinctCall() async throws {
        let runner = runner(), image = try identity()
        _ = try trace(await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image))
        let active = Task { await runner.run(arguments: ["wait", "30000"], input: Data(), expectedImage: image) }
        try await Task.sleep(for: .milliseconds(50))
        let start = ProcessInfo.processInfo.systemUptime
        let busy = await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image)
        XCTAssertNil(busy.exitCode)
        XCTAssertTrue(busy.failure?.contains("busy") == true)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        let cancelStart = ProcessInfo.processInfo.systemUptime
        active.cancel()
        let cancelled = await active.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelStart, 1)
        XCTAssertTrue(cancelled.cancelled); XCTAssertNotNil(cancelled.failure)
        _ = try trace(await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image))
        let error = await runner.shutdown(); XCTAssertNil(error)
    }

    func testTimeoutAndShutdownCancelActiveWorkWithoutReusingIt() async throws {
        for shutdown in [false, true] {
            let runner = runner(timeout: shutdown ? 3 : 0.3), image = try identity()
            let before = try trace(await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image))
            let active = Task { await runner.run(arguments: ["wait", shutdown ? "30000" : "700"], input: Data(), expectedImage: image) }
            if shutdown { try await Task.sleep(for: .milliseconds(50)); let error = await runner.shutdown(); XCTAssertNil(error) }
            let result = await active.value
            XCTAssertNotNil(result.failure)
            if shutdown { XCTAssertTrue(result.cancelled) }
            else {
                XCTAssertTrue(result.failure?.contains("timed out") == true)
                let next = try trace(await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image))
                XCTAssertNotEqual(next.processID, before.processID)
            }
            let error = await runner.shutdown(); XCTAssertNil(error)
        }
    }

    func testOldIdleDeadlineCannotRetireAnActiveOrFollowingCall() async throws {
        let runner = runner(idle: 0.2), image = try identity()
        for _ in 0..<3 {
            let first = try trace(await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image))
            let active = try trace(await runner.run(arguments: ["wait", "300"], input: Data(), expectedImage: image))
            let next = try trace(await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image))
            XCTAssertEqual(active.processID, first.processID)
            XCTAssertEqual(next.processID, first.processID)
        }
        let error = await runner.shutdown(); XCTAssertNil(error)
    }

    func testInvalidInputAndPrecancelNeverDispatchAndDoNotPoisonWarmPair() async throws {
        let runner = runner(), image = try identity()
        let before = try trace(await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image))
        for (args, input) in [(["wait", "0\0"], Data()), (["wait", "0"], Data(repeating: 0, count: 4 * 1024 * 1024 + 1))] {
            let result = await runner.run(arguments: args, input: input, expectedImage: image)
            XCTAssertNil(result.exitCode); XCTAssertTrue(result.failure?.contains("not executed") == true)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await runner.run(arguments: ["wait", "30000"], input: Data(), expectedImage: image)
        }
        let result = await cancelled.value
        XCTAssertTrue(result.cancelled); XCTAssertNil(result.exitCode)
        let after = try trace(await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image))
        XCTAssertEqual(before.processID, after.processID)
        let error = await runner.shutdown(); XCTAssertNil(error)
    }
}
