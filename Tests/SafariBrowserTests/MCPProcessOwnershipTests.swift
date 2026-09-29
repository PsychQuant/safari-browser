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

    /// What the late-joining fixture established (#217). Only `.joined` lets
    /// the product assertions speak; every other phase is a fixture failure,
    /// reported with its own message and the recorded events.
    private enum LateJoinPhase: Equatable {
        /// The pre-started member never reported ready.
        case memberNotReady
        /// No retirement pass sent the first KILL and left the leader for the
        /// fixture to observe exiting (runner failure, or a leader that exited
        /// on its own before the first KILL).
        case exitNeverObserved
        /// The member answered the join command with an errno.
        case joinFailed(String)
        /// The member did not answer the join command.
        case joinTimedOut
        case joined
    }

    private struct LateJoinEvidence {
        var phase: LateJoinPhase
        var events: [String]
        var result: MCPCommandResult
        var memberExited: Bool
        var observationFailure: String?
        var memberCleanup: MCPChildReservation.Retirement?
        var cleanup: String?
        var callbackFailures: [String]
    }

    /// One run of the late-joining scenario (#217). The member is started and
    /// warmed BEFORE the runner and joins the leader's group on command, so
    /// joining does not wait on interpreter start-up. The fixture acts right
    /// after the retirement pass that returns `.pending` once the first KILL is
    /// due: that pass began with the leader alive, so the leader is unreaped
    /// until a later pass, and the fixture waits for its exit and joins the
    /// member before handing control back. The previous fixture observed first
    /// and then called retire, and the leader could exit between those two
    /// observations and be reaped before any member existed.
    ///
    /// What this proves from outside: the member joined the leader's group
    /// while the leader was reserved (a reaped leader leaves no group, and
    /// `setpgid` fails), the member died by SIGKILL, and retirement completed.
    /// Whether one retirement pass kills the member before or after it reaps
    /// the leader is not observable from outside that single call: the
    /// correct order kills and reaps in the same pass once the group is
    /// quiet.
    private func runLateJoinScenario() async throws -> LateJoinEvidence {
        final class Fixture: @unchecked Sendable {
            let lock = NSLock()
            var commandFD: Int32 = -1
            var firstPass: TimeInterval?
            var joinRequested = false
            var phase: LateJoinPhase?
            var events: [String] = []
            var failures: [String] = []
            func note(_ event: String) { lock.withLock { events.append(event) } }
            func closeCommand() { lock.withLock { if commandFD >= 0 { close(commandFD); commandFD = -1 } } }
        }
        let fixture = Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = directory.appendingPathComponent("status")
        var command: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&command), 0)
        // A member that died after reporting ready must surface as EPIPE, not
        // as a SIGPIPE that kills the test process.
        _ = fcntl(command[1], F_SETNOSIGPIPE, 1)
        fixture.commandFD = command[1]
        defer { fixture.closeCommand() }
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
        let member: MCPChildReservation
        do {
            defer { close(command[0]) }
            member = try MCPWorkerSpawn.child(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", script, status.path], environment: [:], descriptors: [0: command[0]], group: .inherit)
        }
        @Sendable func statusLine(_ prefix: String) -> String? {
            // Complete lines only: a torn last line is not an answer yet.
            guard let text = try? String(contentsOf: status, encoding: .utf8) else { return nil }
            return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
                .map(String.init).first { $0.hasPrefix(prefix) }
        }
        // Readiness is established outside the product's retirement window, so
        // this bound is only a failure ceiling, never the pass condition.
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 10
        while statusLine("ready") == nil && ProcessInfo.processInfo.systemUptime < readyDeadline { usleep(2_000) }
        guard statusLine("ready") != nil else {
            return LateJoinEvidence(phase: .memberNotReady, events: [], result: MCPCommandResult(), memberExited: false,
                                    memberCleanup: member.retire(), callbackFailures: [])
        }
        var lifecycle = MCPProcessRunner.Lifecycle()
        lifecycle.retire = { leader in
            let now = ProcessInfo.processInfo.systemUptime
            let first = fixture.lock.withLock { () -> TimeInterval in
                if fixture.firstPass == nil { fixture.firstPass = now }
                return fixture.firstPass!
            }
            let retirement = leader.retire(timeout: 0)
            fixture.note(String(format: "%.3f retire → %@", now - first, String(describing: retirement)))
            // The first KILL is due 150 ms after the first pass sent TERM. Our
            // clock starts before the product's, so this never runs late.
            let requested = fixture.lock.withLock { fixture.joinRequested }
            guard case .pending = retirement, !requested, now - first >= 0.15 else { return retirement }
            do {
                let exitDeadline = ProcessInfo.processInfo.systemUptime + 0.5
                var exited = false
                while !exited && ProcessInfo.processInfo.systemUptime < exitDeadline {
                    exited = try leader.observe() == .exited
                    if !exited { usleep(1_000) }
                }
                guard exited else { return retirement }   // KILL not sent yet: try on the next pass
                fixture.note("leader exited, still reserved")
                let line = Array("\(leader.pid)\n".utf8)
                let written: Int = fixture.lock.withLock {
                    fixture.joinRequested = true
                    return fixture.commandFD >= 0 ? write(fixture.commandFD, line, line.count) : -1
                }
                var phase: LateJoinPhase
                if written != line.count {
                    phase = .joinFailed("command write errno \(errno)")
                } else {
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
                fixture.note("member \(phase)")
                fixture.lock.withLock { fixture.phase = phase }
            } catch { fixture.lock.withLock { fixture.failures.append(String(describing: error)) } }
            return retirement
        }
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        let runner = MCPProcessRunner(executable: python, workerPrefix: ["-c"], supervisorExecutable: python,
            timeout: 0.25, cleanupTimeout: 1, lifecycle: lifecycle)
        let result = await runner.run(arguments: ["import os,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('started',flush=True); os.kill(os.getpid(),signal.SIGSTOP)"],
                                      input: Data(), expectedImage: "fixture")
        let phase = fixture.lock.withLock { fixture.phase } ?? .exitNeverObserved
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
        fixture.closeCommand()   // a later pass must not write to a reused descriptor number
        return fixture.lock.withLock {
            LateJoinEvidence(phase: phase, events: fixture.events, result: result, memberExited: memberExited,
                             observationFailure: observationFailure, memberCleanup: memberCleanup, cleanup: cleanup,
                             callbackFailures: fixture.failures)
        }
    }

    func testOneShotRetirementKillsARealLateJoiningMemberBeforeReleasingLeader() async throws {
        let run = try await runLateJoinScenario()
        let trace = run.events.joined(separator: "; ")
        XCTAssertEqual(run.callbackFailures, [], "observe() failed inside retirement: \(trace)")
        switch run.phase {
        case .memberNotReady:
            return XCTFail("Fixture: the pre-started member never became ready")
        case .exitNeverObserved:
            // A retirement that never completes is the product's failure, not
            // the fixture's: it never killed the leader it was retiring.
            if run.cleanup != nil || run.result.failure?.contains("pending") == true {
                return XCTFail("Retirement never killed the leader (runner failure: \(run.result.failure ?? "none"); cleanup: \(run.cleanup ?? "none")): \(trace)")
            }
            return XCTFail("Fixture: no retirement pass left the killed leader for the fixture to observe (runner failure: \(run.result.failure ?? "none")): \(trace)")
        case .joinFailed(let why):
            return XCTFail("Fixture: the member could not join the still-reserved group (\(why)): \(trace)")
        case .joinTimedOut:
            return XCTFail("Fixture: the member did not answer the join command: \(trace)")
        case .joined:
            break
        }
        XCTAssertEqual(run.result.stdout, Data("started\n".utf8), "leader output")
        XCTAssertTrue(run.result.failure?.contains("timed out") == true, "runner failure: \(run.result.failure ?? "none")")
        XCTAssertFalse(run.result.failure?.contains("pending") == true, "retirement left pending: \(trace)")
        XCTAssertNil(run.observationFailure)
        XCTAssertTrue(run.memberExited, "A late member that joined the reserved group survived the one-shot runner's retirement: \(trace)")
        guard case .reaped(let status)? = run.memberCleanup else { return XCTFail("Owned fixture member was not reaped") }
        XCTAssertEqual(status & 0x7f, SIGKILL, "The late member must have been terminated, not completed naturally")
        XCTAssertNil(run.cleanup, "runner shutdown left cleanup pending")
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
