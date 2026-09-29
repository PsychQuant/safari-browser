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

    /// What the late-joining fixture established in one attempt (#217). Only
    /// `.joined` lets the product assertions speak: every other phase means
    /// the scenario under test never happened, and must not be reported as a
    /// member the product failed to kill.
    private enum LateJoinPhase: Equatable {
        /// The pre-started member never reported ready.
        case memberNotReady
        /// The product reaped the leader in the same retirement pass that
        /// first saw it exit, before the fixture could observe that exit.
        /// Nothing had joined, so there was nothing to kill: inconclusive.
        case leaderReapedBeforeExitObserved
        /// The member answered the join command with an errno.
        case joinFailed(String)
        /// The member did not answer the join command.
        case joinTimedOut
        case joined
    }

    private struct LateJoinAttempt {
        var phase: LateJoinPhase
        var result: MCPCommandResult
        var memberExited: Bool
        var observationFailure: String?
        var memberCleanup: MCPChildReservation.Retirement?
        var cleanup: String?
        var callbackFailure: String?
    }

    /// One run of the late-joining scenario with a fresh runner. The member is
    /// started and warmed BEFORE the runner, and joins the leader's group on
    /// command: #217 measured its interpreter start overrunning the 0.5 s join
    /// budget under concurrent process spawning when it was started inside the
    /// retirement callback.
    private func runLateJoinAttempt() async throws -> LateJoinAttempt {
        final class Fixture: @unchecked Sendable {
            let lock = NSLock()
            var joinRequested = false
            var phase: LateJoinPhase?
            var failure: String?
        }
        let fixture = Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = directory.appendingPathComponent("status")
        var command: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&command), 0)
        defer { close(command[1]) }
        let script = """
            import os,signal,sys
            signal.signal(signal.SIGTERM,signal.SIG_IGN)
            out=open(sys.argv[1],'w'); out.write('ready\\n'); out.flush()
            line=sys.stdin.readline()
            try:
                os.setpgid(0,int(line)); out.write('joined:%d\\n'%os.getpgrp())
            except OSError as e:
                out.write('failed:%d\\n'%e.errno)
            out.flush(); signal.pause()
            """
        let member = try MCPWorkerSpawn.child(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, status.path], environment: [:], descriptors: [0: command[0]], group: .inherit)
        close(command[0])
        @Sendable func statusLine(_ prefix: String) -> String? {
            (try? String(contentsOf: status, encoding: .utf8))?.split(separator: "\n").map(String.init).first { $0.hasPrefix(prefix) }
        }
        // Readiness is established outside the product's retirement window, so
        // this bound is only a failure ceiling, never the pass condition.
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 10
        while statusLine("ready") == nil && ProcessInfo.processInfo.systemUptime < readyDeadline { usleep(2_000) }
        guard statusLine("ready") != nil else {
            let cleanup = member.retire()
            return LateJoinAttempt(phase: .memberNotReady, result: MCPCommandResult(), memberExited: false,
                                   memberCleanup: cleanup)
        }
        let commandFD = command[1]
        var lifecycle = MCPProcessRunner.Lifecycle()
        lifecycle.retire = { leader in
            do {
                let requested = fixture.lock.withLock { fixture.joinRequested }
                if !requested, try leader.observe() == .exited {
                    // The fixture leader ignores TERM and stops itself, so an
                    // exited leader here proves the first KILL already occurred
                    // while its reservation still holds the group.
                    fixture.lock.withLock { fixture.joinRequested = true }
                    let line = Array("\(leader.pid)\n".utf8)
                    let phase: LateJoinPhase
                    if write(commandFD, line, line.count) != line.count {
                        phase = .joinFailed("command write errno \(errno)")
                    } else {
                        // setpgid in a running interpreter: milliseconds.
                        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
                        var answer: LateJoinPhase?
                        while answer == nil && ProcessInfo.processInfo.systemUptime < deadline {
                            if let joined = statusLine("joined:") {
                                answer = joined == "joined:\(leader.pid)" ? .joined : .joinFailed("joined \(joined)")
                            } else if let failed = statusLine("failed:") {
                                answer = .joinFailed(failed)
                            } else { usleep(1_000) }
                        }
                        phase = answer ?? .joinTimedOut
                    }
                    fixture.lock.withLock { fixture.phase = phase }
                }
            } catch { fixture.lock.withLock { fixture.failure = String(describing: error) } }
            return leader.retire(timeout: 0)
        }
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        let runner = MCPProcessRunner(executable: python, workerPrefix: ["-c"], supervisorExecutable: python,
            timeout: 0.25, cleanupTimeout: 1, lifecycle: lifecycle)
        let result = await runner.run(arguments: ["import os,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('started',flush=True); os.kill(os.getpid(),signal.SIGSTOP)"],
                                      input: Data(), expectedImage: "fixture")
        let (requested, recorded, callbackFailure) = fixture.lock.withLock {
            (fixture.joinRequested, fixture.phase, fixture.failure)
        }
        let phase = recorded ?? (requested ? .joinTimedOut : .leaderReapedBeforeExitObserved)
        // Darwin can remove the process from group/proc snapshots before the
        // parent's WEXITED observation becomes available. Observe boundedly,
        // before sending any fixture cleanup signal, rather than assuming both
        // kernel views become visible in the same scheduler turn.
        var memberExited = false
        var observationFailure: String?
        if phase == .joined {
            let observationDeadline = ProcessInfo.processInfo.systemUptime + 0.3
            while ProcessInfo.processInfo.systemUptime < observationDeadline {
                do {
                    if try member.observe() == .exited { memberExited = true; break }
                } catch { observationFailure = String(describing: error); break }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        // Member has its own local spawn reservation. Cleanup never uses a PID
        // obtained from ps or a worker reply.
        let memberCleanup = member.retire()
        let cleanup = await runner.shutdown()
        return LateJoinAttempt(phase: phase, result: result, memberExited: memberExited,
                               observationFailure: observationFailure, memberCleanup: memberCleanup,
                               cleanup: cleanup, callbackFailure: callbackFailure)
    }

    func testOneShotRetirementKillsARealLateJoiningMemberBeforeReleasingLeader() async throws {
        // #217: an attempt in which the product reaped the leader before any
        // member could join tested nothing; run the scenario again rather than
        // report a member the product never had to kill.
        var inconclusive = 0
        var attempt: LateJoinAttempt?
        for _ in 1...5 {
            let next = try await runLateJoinAttempt()
            attempt = next
            guard next.phase == .leaderReapedBeforeExitObserved else { break }
            inconclusive += 1
        }
        let run = try XCTUnwrap(attempt)
        if inconclusive > 0 { print("[#217] late-join attempts retried as inconclusive: \(inconclusive)") }
        XCTAssertNil(run.callbackFailure)
        switch run.phase {
        case .memberNotReady:
            return XCTFail("Fixture: the pre-started member never became ready")
        case .leaderReapedBeforeExitObserved:
            return XCTFail("Fixture: in \(inconclusive) attempts the leader was reaped before its exit could be observed; no member ever joined")
        case .joinFailed(let why):
            return XCTFail("Fixture: the member could not join the still-reserved group (\(why))")
        case .joinTimedOut:
            return XCTFail("Fixture: the member did not answer the join command")
        case .joined:
            break
        }
        XCTAssertEqual(run.result.stdout, Data("started\n".utf8))
        XCTAssertTrue(run.result.failure?.contains("timed out") == true)
        XCTAssertFalse(run.result.failure?.contains("pending") == true)
        XCTAssertNil(run.observationFailure)
        XCTAssertTrue(run.memberExited, "A late member that joined the reserved group survived the one-shot runner's retirement")
        guard case .reaped(let status)? = run.memberCleanup else { return XCTFail("Owned fixture member was not reaped") }
        XCTAssertEqual(status & 0x7f, SIGKILL, "The late member must have been terminated, not completed naturally")
        XCTAssertNil(run.cleanup)
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
