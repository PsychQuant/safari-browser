import Foundation
import XCTest
import Darwin
@testable import SafariBrowser

final class MCPProcessRunnerTests: XCTestCase, @unchecked Sendable {
    private func fixture(timeout: TimeInterval = 3, limit: Int = 2 * 1024 * 1024) -> MCPProcessRunner {
        MCPProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/python3"), workerPrefix: ["-c"], supervisorExecutable: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("safari-browser"), timeout: timeout, outputLimit: limit)
    }

    func testStoppedWorkerWaitsForTimeoutInsteadOfBeingMistakenForExit() async {
        let started = ProcessInfo.processInfo.systemUptime
        let result = await fixture(timeout: 1).run(
            arguments: ["import os,signal; print('stopped-fixture',flush=True); os.kill(os.getpid(),signal.SIGSTOP)"],
            input: Data(), expectedImage: "test")
        XCTAssertEqual(result.stdout, Data("stopped-fixture\n".utf8))
        XCTAssertTrue(result.failure?.contains("timed out") == true)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.8,
                                    "A stopped event must not prematurely retire a live worker")
    }

    func testStoppedSupervisorRetainsTheLeaderUntilTimeout() async {
        // Deliberately non-cooperative helper fixture: it stops itself before
        // interpreting bootstrap input. The host owns this direct-child leader.
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        let runner = MCPProcessRunner(executable: python, workerPrefix: ["-c"], supervisorExecutable: python, timeout: 1)
        let started = ProcessInfo.processInfo.systemUptime
        let result = await runner.run(arguments: ["import os,signal; print('stopped-supervisor',flush=True); os.kill(os.getpid(),signal.SIGSTOP)"],
                                      input: Data(), expectedImage: "fixture")
        XCTAssertEqual(result.stdout, Data("stopped-supervisor\n".utf8))
        XCTAssertTrue(result.failure?.contains("timed out") == true)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.8,
                                    "A stopped group leader must remain reserved until timeout")
    }

    func testShutdownCancelsActiveExecutionAndRejectsLaterCalls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let runner = fixture(timeout: 3)
        let active = Task { await runner.run(arguments: ["import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(30)", started.path], input: Data(), expectedImage: "fixture") }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: started.path) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        let start = ProcessInfo.processInfo.systemUptime
        let cleanup = await runner.shutdown()
        XCTAssertNil(cleanup)
        let result = await active.value
        XCTAssertTrue(result.cancelled)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let later = await runner.run(arguments: ["print('unexpected')"], input: Data(), expectedImage: "fixture")
        XCTAssertTrue(later.failure?.contains("not executed") == true)
        XCTAssertEqual(later.stdout, Data())
    }

    func testConcurrentExecutionIsRejectedBeforeItsEffect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started"), release = directory.appendingPathComponent("release"), effect = directory.appendingPathComponent("effect")
        let runner = fixture(timeout: 3)
        let active = Task { await runner.run(arguments: ["import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch();\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(.005)", started.path, release.path], input: Data(), expectedImage: "fixture") }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: started.path) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        let result = await runner.run(arguments: ["import pathlib,sys; pathlib.Path(sys.argv[1]).touch()", effect.path], input: Data(), expectedImage: "fixture")
        FileManager.default.createFile(atPath: release.path, contents: nil)
        let first = await active.value
        XCTAssertNil(first.failure)
        XCTAssertTrue(result.failure?.contains("not executed") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path))
    }

    func testPendingCleanupPreventsAnotherEffectUntilTheSameOwnerRetires() async throws {
        final class Gate: @unchecked Sendable {
            let lock = NSLock()
            private var blocked = true
            func unblock() { lock.withLock { blocked = false } }
            var isBlocked: Bool { lock.withLock { blocked } }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let effect = directory.appendingPathComponent("effect")
        let gate = Gate()
        var lifecycle = MCPProcessRunner.Lifecycle()
        lifecycle.retire = { gate.isBlocked ? .pending : $0.retire(timeout: 0) }
        let runner = MCPProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/python3"), workerPrefix: ["-c"],
            supervisorExecutable: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("safari-browser"),
            timeout: 2, cleanupTimeout: 0.05, lifecycle: lifecycle)
        let started = ProcessInfo.processInfo.systemUptime
        let first = await runner.run(arguments: ["print('first')"], input: Data(), expectedImage: "fixture")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.8, "Unconfirmed retirement must return within its userspace budget")
        XCTAssertEqual(first.stdout, Data("first\n".utf8))
        XCTAssertTrue(first.failure?.contains("pending") == true)
        let rejected = await runner.run(arguments: ["import pathlib,sys; pathlib.Path(sys.argv[1]).touch()", effect.path], input: Data(), expectedImage: "fixture")
        XCTAssertTrue(rejected.failure?.contains("not executed") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path))
        gate.unblock()
        let recovered = await runner.run(arguments: ["print('recovered')"], input: Data(), expectedImage: "fixture")
        XCTAssertNil(recovered.failure)
        XCTAssertEqual(recovered.stdout, Data("recovered\n".utf8))
        let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
    }

    func testInheritedDeadlineCannotExtendConfiguredTimeout() async {
        let runner = MCPProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/python3"), workerPrefix: ["-c"],
            supervisorExecutable: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("safari-browser"),
            timeout: 0.15, invocationDeadline: ProcessInfo.processInfo.systemUptime + 30)
        let started = ProcessInfo.processInfo.systemUptime
        let result = await runner.run(arguments: ["import time; time.sleep(1)"], input: Data(), expectedImage: "fixture")
        XCTAssertTrue(result.failure?.contains("timed out") == true)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.7,
                          "An inherited budget may shorten, but never extend, the configured timeout")
    }

    func testTimeoutPreservesActualWorkerTermGraceAndSignalStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("grace")
        let script = """
        import os,signal,sys,time,pathlib
        def finish(sig,frame):
            pathlib.Path(sys.argv[1]).write_text('received')
            time.sleep(.1)
            pathlib.Path(sys.argv[1]).write_text('completed')
            signal.signal(signal.SIGTERM,signal.SIG_DFL)
            os.kill(os.getpid(),signal.SIGTERM)
        signal.signal(signal.SIGTERM,finish)
        print('ready',flush=True)
        time.sleep(5)
        """
        let result = await fixture(timeout: 0.4).run(arguments: [script, marker.path], input: Data(), expectedImage: "fixture")
        XCTAssertEqual(result.stdout, Data("ready\n".utf8))
        XCTAssertTrue(result.failure?.contains("timed out") == true)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "completed",
                       "The real CLI must retain its TERM grace even though a supervisor leads its group")
        XCTAssertEqual(result.exitCode, 143, "Report the actual CLI signal status, not a missing helper record")
    }

    func testSeparateStreamsStdinArgumentsAndContext() async {
        let script = "import os,sys; sys.stdout.buffer.write(sys.stdin.buffer.read()); print(repr(sys.argv[1:]),file=sys.stderr); print(os.environ['SAFARI_BROWSER_MCP_DIRECT']+os.environ['SAFARI_BROWSER_MCP_IMAGE_ID'],file=sys.stderr); sys.exit(7)"
        let result = await fixture().run(arguments: [script, "--literal", "a b'\"$()"], input: Data([0, 10, 255]), expectedImage: "IMAGE")
        XCTAssertEqual(result.stdout, Data([0, 10, 255]))
        XCTAssertTrue(String(decoding: result.stderr, as: UTF8.self).contains("--literal"))
        XCTAssertTrue(String(decoding: result.stderr, as: UTF8.self).contains("1IMAGE"))
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertNil(result.failure)
    }

    func testDrainsBothStreamsWhileWritingLargeInput() async {
        let script = "import sys; sys.stdout.buffer.write(b'x'*200000); sys.stdout.flush(); sys.stderr.buffer.write(b'y'*200000); sys.stderr.flush(); print(len(sys.stdin.buffer.read()))"
        let result = await fixture().run(arguments: [script], input: Data(repeating: 97, count: 200000), expectedImage: "test")
        XCTAssertEqual(result.stdout.count, 200007)
        XCTAssertEqual(result.stderr.count, 200000)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.failure)
    }

    func testCaptureLimitStopsWorkerAndMarksIncomplete() async {
        let result = await fixture(limit: 1024).run(arguments: ["import os;\nwhile True: os.write(1,b'x'*4096)"], input: Data(), expectedImage: "test")
        XCTAssertEqual(result.stdout.count, 1024)
        XCTAssertTrue(result.truncated)
        XCTAssertNotNil(result.failure)
    }

    func testTimeoutAndCancellationKillOwnedDescendants() async throws {
        for cancel in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = directory.appendingPathComponent("survived")
            let started = directory.appendingPathComponent("started")
            let script = "import os,time,signal,sys; signal.signal(signal.SIGTERM,signal.SIG_IGN); p=os.fork();\nif p==0:\n time.sleep(1.5); open(sys.argv[1],'w').write('alive'); os._exit(0)\nopen(sys.argv[2],'w').write(str(p)); time.sleep(5)"
            let runner = fixture(timeout: cancel ? 3 : 0.6)
            let task = Task { await runner.run(arguments: [script, marker.path, started.path], input: Data(), expectedImage: "test") }
            if cancel {
                for _ in 0..<200 {
                    if FileManager.default.fileExists(atPath: started.path) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                task.cancel()
            }
            let result = await task.value
            XCTAssertTrue(FileManager.default.fileExists(atPath: started.path), "Fixture must actually fork before cleanup is tested")
            XCTAssertEqual(result.cancelled, cancel)
            XCTAssertNotNil(result.failure)
            try await Task.sleep(for: .milliseconds(1600))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testStderrOverflowAndSignalExitAreErrors() async {
        let limited = await fixture(limit: 512).run(arguments: ["import os; os.write(2,b'x'*513)"], input: Data(), expectedImage: "test")
        XCTAssertEqual(limited.stderr.count, 512)
        XCTAssertTrue(limited.truncated)
        XCTAssertNotNil(limited.failure)
        let signalled = await fixture().run(arguments: ["import os,signal; os.kill(os.getpid(),signal.SIGTERM)"], input: Data(), expectedImage: "test")
        XCTAssertEqual(signalled.exitCode, 143)
        XCTAssertNotNil(signalled.failure)
    }

    func testCompletedWorkerIsReapedAndExactLimitIsComplete() async throws {
        let result = await fixture(limit: 1024).run(arguments: ["import os; print(os.getpid(),flush=True); os.write(2,b'x'*1024)"], input: Data(), expectedImage: "test")
        XCTAssertEqual(result.stderr.count, 1024)
        XCTAssertFalse(result.truncated)
        XCTAssertNil(result.failure)
        let pid = try XCTUnwrap(Int32(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testAlreadyCancelledTaskNeverLaunchesWorker() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture().run(arguments: ["print('executed')"], input: Data(), expectedImage: "test")
        }
        let result = await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.stdout, Data())
        XCTAssertNil(result.exitCode)
    }

    func testEarlyStdinCloseDoesNotSignalParent() async {
        let result = await fixture().run(arguments: ["import os; os.close(0)"], input: Data(repeating: 1, count: 1000000), expectedImage: "test")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testInvalidInputAndMissingExecutableFailWithoutLaunch() async {
        let oversized = await fixture().run(arguments: ["pass"], input: Data(repeating: 1, count: 4 * 1024 * 1024 + 1), expectedImage: "test")
        XCTAssertNil(oversized.exitCode)
        XCTAssertNotNil(oversized.failure)
        let nul = await fixture().run(arguments: ["pass\0"], input: Data(), expectedImage: "test")
        XCTAssertNil(nul.exitCode)
        XCTAssertNotNil(nul.failure)
        let missing = await MCPProcessRunner(executable: URL(fileURLWithPath: "/no/such/mcp-worker")).run(arguments: [], input: Data(), expectedImage: "test")
        XCTAssertNil(missing.exitCode)
        XCTAssertNotNil(missing.failure)
    }
}
