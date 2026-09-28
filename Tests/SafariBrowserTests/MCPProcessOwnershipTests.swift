import Foundation
import Darwin
import XCTest
@testable import SafariBrowser

final class MCPProcessOwnershipTests: XCTestCase, @unchecked Sendable {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var blocked = true
        private var retireCalls = 0
        private var launchCount = 0
        var isBlocked: Bool { lock.withLock { blocked } }
        var calls: Int { lock.withLock { retireCalls } }
        var launches: Int { lock.withLock { launchCount } }
        func release() { lock.withLock { blocked = false } }
        func retired() { lock.withLock { retireCalls += 1 } }
        func launched() { lock.withLock { launchCount += 1 } }
    }
    private var binary: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("safari-browser") }
    private func image() throws -> String { try MCPExecutableIdentity.readImage(at: binary, architecture: MCPExecutableIdentity.currentArchitecture()) }

    func testOneShotRetirementKillsARealLateJoiningMemberBeforeReleasingLeader() async throws {
        final class LateMember: @unchecked Sendable {
            var member: MCPChildReservation?
            var joined = false
            var failure: String?
        }
        let state = LateMember()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("joined")
        var lifecycle = MCPProcessRunner.Lifecycle()
        lifecycle.retire = { leader in
            do {
                if state.member == nil, try leader.observe() == .exited {
                    // The fixture leader ignores TERM and stops itself, so an
                    // exited leader here proves the first KILL already occurred.
                    let script = "import os,signal,sys,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); os.setpgid(0,int(sys.argv[1])); pathlib.Path(sys.argv[2]).write_text(str(os.getpgrp())); signal.pause()"
                    state.member = try MCPWorkerSpawn.child(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                        arguments: ["-c", script, String(leader.pid), ready.path], environment: [:], descriptors: [:], group: .inherit)
                    let deadline = ProcessInfo.processInfo.systemUptime + 0.5
                    while ProcessInfo.processInfo.systemUptime < deadline {
                        if (try? String(contentsOf: ready, encoding: .utf8)) == String(leader.pid) { state.joined = true; break }
                        usleep(1_000)
                    }
                }
            } catch { state.failure = String(describing: error) }
            return leader.retire(timeout: 0)
        }
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        let runner = MCPProcessRunner(executable: python, workerPrefix: ["-c"], supervisorExecutable: python,
            timeout: 0.25, cleanupTimeout: 1, lifecycle: lifecycle)
        let result = await runner.run(arguments: ["import os,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('started',flush=True); os.kill(os.getpid(),signal.SIGSTOP)"],
                                      input: Data(), expectedImage: "fixture")
        // Member has its own local spawn reservation. Cleanup never uses a PID
        // obtained from ps or a worker reply, even if the assertion is RED.
        let member = state.member
        let memberExited = (try? member?.observe()) == .exited
        let memberCleanup = member?.retire()
        let cleanup = await runner.shutdown()
        XCTAssertNil(state.failure)
        XCTAssertTrue(state.joined, "Fixture must join the still-reserved group after its first kill")
        XCTAssertEqual(result.stdout, Data("started\n".utf8))
        XCTAssertTrue(result.failure?.contains("timed out") == true)
        XCTAssertFalse(result.failure?.contains("pending") == true)
        XCTAssertTrue(memberExited, "A late member survived the one-shot runner's retirement")
        if let memberCleanup { guard case .reaped = memberCleanup else { return XCTFail("Owned fixture member was not reaped") } }
        XCTAssertNil(cleanup)
    }

    func testImageRejectionKeepsIntentionalCaptureDistinctionBetweenModes() async {
        let isolated = MCPProcessRunner(executable: binary, timeout: 2)
        let persistent = MCPPersistentRunner(executable: binary, timeout: 2)
        let oneShot = await isolated.run(arguments: ["wait", "0"], input: Data(), expectedImage: "different-catalog-image")
        let warm = await persistent.run(arguments: ["wait", "0"], input: Data(), expectedImage: "different-catalog-image")
        for result in [oneShot, warm] {
            XCTAssertEqual(result.exitCode, 64)
            XCTAssertTrue(String(decoding: result.stderr, as: UTF8.self).contains("executable changed"))
            XCTAssertEqual(MCPSession.toolResult(result)["isError"], .bool(true))
        }
        let isolatedResult = MCPSession.toolResult(oneShot)["structuredContent"]
        let persistentResult = MCPSession.toolResult(warm)["structuredContent"]
        XCTAssertEqual(isolatedResult?["capture_complete"], .bool(true))
        XCTAssertEqual(isolatedResult?["failure"], .null)
        XCTAssertEqual(persistentResult?["capture_complete"], .bool(false))
        XCTAssertTrue(persistentResult?["failure"]?.stringValue?.contains("restart") == true)
        let firstCleanup = await isolated.shutdown(), secondCleanup = await persistent.shutdown()
        XCTAssertNil(firstCleanup); XCTAssertNil(secondCleanup)
    }

    func testLostReservationRemainsTerminalWithoutAnotherLaunchOrRetirement() async throws {
        let gate = Gate()
        var lifecycle = MCPProcessRunner.Lifecycle()
        lifecycle.didLaunch = { _ in gate.launched() }
        lifecycle.retire = { child in
            gate.retired()
            // Deliberately reap only this known direct child after its normal
            // helper exit. The reservation must observe actual ECHILD afterward.
            var status: Int32 = 0
            let reaped = waitpid(child.pid, &status, WNOHANG)
            if reaped == 0 { return .pending }
            return child.retire(timeout: 0)
        }
        let runner = MCPProcessRunner(executable: binary, timeout: 2, cleanupTimeout: 0.05, lifecycle: lifecycle)
        let first = await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: try image())
        XCTAssertTrue(first.failure?.contains("ownership was lost") == true)
        let observedCalls = gate.calls
        for _ in 0..<2 {
            let next = await runner.run(arguments: ["--help"], input: Data(), expectedImage: try image())
            XCTAssertTrue(next.failure?.contains("not executed") == true)
            XCTAssertEqual(next.stdout, Data())
        }
        let cleanup = await runner.shutdown()
        XCTAssertTrue(cleanup?.contains("ownership was lost") == true)
        XCTAssertEqual(gate.launches, 1)
        XCTAssertEqual(gate.calls, observedCalls, "Lost authority must never enter the signal/reap path again")
    }

    func testShutdownReportsPendingAndCanFinishTheSameReservationLater() async throws {
        let gate = Gate()
        defer { gate.release() }
        var lifecycle = MCPProcessRunner.Lifecycle()
        lifecycle.retire = { gate.isBlocked ? .pending : $0.retire(timeout: 0) }
        let runner = MCPProcessRunner(executable: binary, timeout: 2, cleanupTimeout: 0.05, lifecycle: lifecycle)
        let result = await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: try image())
        XCTAssertTrue(result.failure?.contains("pending") == true)
        let started = ProcessInfo.processInfo.systemUptime
        let pending = await runner.shutdown()
        XCTAssertTrue(pending?.contains("pending") == true)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
        gate.release()
        let cleaned = await runner.shutdown(); XCTAssertNil(cleaned)
        let rejected = await runner.run(arguments: ["--help"], input: Data(), expectedImage: try image())
        XCTAssertTrue(rejected.failure?.contains("not executed") == true)
        XCTAssertEqual(rejected.stdout, Data())
    }

    func testPreselectedPendingOwnerBlocksBothOneShotAndNewPersistentPair() async throws {
        let gate = Gate()
        defer { gate.release() }
        var lifecycle = MCPPersistentRunner.Lifecycle()
        lifecycle.isolated.retire = { gate.isBlocked ? .pending : $0.retire(timeout: 0) }
        lifecycle.didLaunch = { _ in gate.launched() }
        let runner = MCPPersistentRunner(executable: binary, environment: [:], timeout: 2, cleanupTimeout: 0.05, lifecycle: lifecycle)
        let identifier = try image()
        let large = String(repeating: "0", count: sysconf(_SC_ARG_MAX) / 2 + 4096)
        let first = await runner.run(arguments: ["wait", large], input: Data(), expectedImage: identifier)
        XCTAssertTrue(first.failure?.contains("pending") == true)
        let script = Data("[{\"cmd\":\"wait\",\"args\":[\"0\"]}]".utf8)
        let rejected = await runner.run(arguments: ["exec"], input: script, expectedImage: identifier)
        XCTAssertTrue(rejected.failure?.contains("not executed") == true)
        XCTAssertEqual(rejected.stdout, Data(), "A new normal call must not execute around an old pending one-shot")
        XCTAssertEqual(gate.launches, 0)
        let secondLarge = await runner.run(arguments: ["wait", large], input: Data(), expectedImage: identifier)
        XCTAssertTrue(secondLarge.failure?.contains("not executed") == true)
        gate.release()
        let recovered = await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: identifier)
        XCTAssertNil(recovered.failure)
        XCTAssertEqual(gate.launches, 1)
        let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
    }
}
