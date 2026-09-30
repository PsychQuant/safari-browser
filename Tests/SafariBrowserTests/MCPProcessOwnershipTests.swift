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
        /// No retirement pass left the leader exited but still reserved for the
        /// fixture to observe: the runner failed before a callback ran, the
        /// leader died on its own, or a pass reaped it in the pass that first
        /// sent the KILL. Classified by the evidence of pending cleanup, not by
        /// absence alone: pending cleanup is reported as a product failure.
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
    /// "Due" is judged from a clock read AFTER `leader.retire` returns. The
    /// product reads its own clock inside `retire`, after this fixture's
    /// reading of the first pass, so `after - first` is never smaller than the
    /// product's `now - stopStarted`: whenever the product sends the KILL in a
    /// pass, the fixture considers that pass due. The converse can fail by
    /// microseconds, and then the fixture waits for an exit that has not been
    /// caused yet; that costs one bounded wait and the next pass corrects it.
    /// A read BEFORE `retire` had neither property (verify R2: about 2% of
    /// in-process runs under contention missed the pass). As a backstop, a pass
    /// that starts with the leader already exited and still reserved joins the
    /// member before calling `retire`, which covers a product whose grace is
    /// shorter than the 150 ms copied below.
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
        /// Ask the member to join the leader's group and wait for its answer.
        /// Runs inside the retirement callback, so both waits are bounded.
        @Sendable func join(_ leader: MCPChildReservation) {
            let line = Array("\(leader.pid)\n".utf8)
            // errno is read inside the lock, immediately after `write`.
            let refusal: String? = fixture.lock.withLock {
                fixture.joinRequested = true
                guard fixture.commandFD >= 0 else { return "command pipe already closed" }
                let count = write(fixture.commandFD, line, line.count)
                if count == line.count { return nil }
                return count < 0 ? "command write errno \(errno)" : "short command write (\(count) of \(line.count))"
            }
            let phase: LateJoinPhase
            if let refusal {
                phase = .joinFailed(refusal)
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
        }
        var lifecycle = MCPProcessRunner.Lifecycle()
        lifecycle.retire = { leader in
            do {
                // Backstop: an earlier pass sent the KILL and the leader has
                // exited while still reserved. Join now, before this pass reaps it.
                let requested = fixture.lock.withLock { fixture.joinRequested }
                if !requested, try leader.observe() == .exited {
                    fixture.note("leader exited between passes, still reserved")
                    join(leader)
                }
            } catch { fixture.lock.withLock { fixture.failures.append(String(describing: error)) } }
            let first = fixture.lock.withLock { () -> TimeInterval in
                if fixture.firstPass == nil { fixture.firstPass = ProcessInfo.processInfo.systemUptime }
                return fixture.firstPass!
            }
            let retirement = leader.retire(timeout: 0)
            let after = ProcessInfo.processInfo.systemUptime   // after the product's own clock reads
            fixture.note(String(format: "%.3f retire → %@", after - first, String(describing: retirement)))
            // The first KILL is due 150 ms after the first pass sent TERM
            // (MCPChildReservation.retire, MCPWorkerSupervisor.swift).
            let requested = fixture.lock.withLock { fixture.joinRequested }
            guard case .pending = retirement, !requested, after - first >= 0.15 else { return retirement }
            do {
                let exitDeadline = ProcessInfo.processInfo.systemUptime + 0.5
                var exited = false
                while !exited && ProcessInfo.processInfo.systemUptime < exitDeadline {
                    exited = try leader.observe() == .exited
                    if !exited { usleep(1_000) }
                }
                guard exited else { return retirement }   // KILL not sent yet: try on the next pass
                fixture.note("leader exited, still reserved")
                join(leader)
            } catch { fixture.lock.withLock { fixture.failures.append(String(describing: error)) } }
            return retirement
        }
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        // cleanupTimeout counts from the start of retirement, and the fixture
        // blocks the runner's queue for up to 0.5 s twice; 3 s leaves room for
        // that without relaxing what retirement must achieve (max accepted: 5 s).
        // The 0.6 s timeout bounds the leader's own interpreter start-up.
        let runner = MCPProcessRunner(executable: python, workerPrefix: ["-c"], supervisorExecutable: python,
            timeout: 0.6, cleanupTimeout: 3, lifecycle: lifecycle)
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
                // Not `try`: a cancelled test must still reach the cleanup below,
                // or the SIGTERM-ignoring member outlives it.
                try? await Task.sleep(for: .milliseconds(5))
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

    /// `SAFARI_BROWSER_LATE_JOIN_REPEAT=N` repeats the scenario N times inside
    /// this one process (scripts/stress-late-join.sh), which is the form that
    /// exercises the retirement-pass timing; one process per run does not.
    func testOneShotRetirementKillsARealLateJoiningMember() async throws {
        let environment = ProcessInfo.processInfo.environment["SAFARI_BROWSER_LATE_JOIN_REPEAT"]
        let repeats = max(1, environment.flatMap { Int($0) } ?? 1)
        for index in 1...repeats {
            let run = try await runLateJoinScenario()
            checkLateJoin(run, label: repeats > 1 ? "run \(index)/\(repeats): " : "")
        }
    }

    /// The fixture phases speak first; only `.joined` lets the product
    /// assertions speak. Every message carries the runner's and the member's
    /// own cleanup evidence, so a fixture stall is not mistaken for the product.
    private func checkLateJoin(_ run: LateJoinEvidence, label: String) {
        let trace = run.events.joined(separator: "; ")
        let evidence = "runner failure: \(run.result.failure ?? "none"); runner cleanup: \(run.cleanup ?? "none"); "
            + "member cleanup: \(run.memberCleanup.map { String(describing: $0) } ?? "none"); trace: \(trace)"
        XCTAssertEqual(run.callbackFailures, [], "\(label)observe() failed inside retirement: \(trace)")
        switch run.phase {
        case .memberNotReady:
            return XCTFail("\(label)Fixture: the pre-started member never became ready (\(evidence))")
        case .exitNeverObserved:
            // A retirement that never completes is the product's failure, not
            // the fixture's: it never killed the leader it was retiring.
            if run.cleanup != nil || run.result.failure?.contains("pending") == true {
                return XCTFail("\(label)Retirement never killed the leader (\(evidence))")
            }
            return XCTFail("\(label)Fixture: no retirement pass left the leader exited but still reserved for the fixture to observe (\(evidence))")
        case .joinFailed(let why):
            return XCTFail("\(label)Fixture: the member could not join the still-reserved group (\(why)): \(evidence)")
        case .joinTimedOut:
            return XCTFail("\(label)Fixture: the member did not answer the join command: \(evidence)")
        case .joined:
            break
        }
        // The leader is the runner's own interpreter and cannot be pre-warmed:
        // one killed before it printed anything is a start-up-time fixture
        // failure, not a product regression.
        if run.result.stdout.isEmpty {
            return XCTFail("\(label)Fixture: the leader was terminated before its interpreter printed 'started' (\(evidence))")
        }
        XCTAssertEqual(run.result.stdout, Data("started\n".utf8), "\(label)leader output")
        XCTAssertTrue(run.result.failure?.contains("timed out") == true, "\(label)runner failure: \(run.result.failure ?? "none")")
        XCTAssertFalse(run.result.failure?.contains("pending") == true, "\(label)retirement left pending: \(trace)")
        XCTAssertNil(run.observationFailure)
        XCTAssertTrue(run.memberExited, "\(label)A late member that joined the reserved group survived the one-shot runner's retirement: \(trace)")
        guard case .reaped(let status)? = run.memberCleanup else { return XCTFail("\(label)Owned fixture member was not reaped") }
        XCTAssertEqual(status & 0x7f, SIGKILL, "\(label)The late member must have been terminated, not completed naturally")
        XCTAssertNil(run.cleanup, "\(label)runner shutdown left cleanup pending")
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
