import Foundation
import XCTest
import Darwin
@testable import SafariBrowser

final class MCPProcessRunnerTests: XCTestCase, @unchecked Sendable {
    private func fixture(timeout: TimeInterval = 3, limit: Int = 2 * 1024 * 1024) -> MCPProcessRunner {
        MCPProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/python3"), workerPrefix: ["-c"], timeout: timeout, outputLimit: limit)
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
