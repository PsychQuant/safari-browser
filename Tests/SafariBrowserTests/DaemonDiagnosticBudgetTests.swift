import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonDiagnosticBudgetTests: XCTestCase {
    typealias Budget = DaemonDiagnosticBudget
    private let error = Budget.Event(kind: .acceptError, errno: 4, disposition: .retry)
    private let terminal = Budget.Event(kind: .acceptError, errno: 9, disposition: .stop)

    func testAlternatingIncidentsShareBurstAndPreserveTerminalEvidence() throws {
        let now = ContinuousClock.now
        var budget = Budget(now: now)
        var emitted: [Budget.Emission] = []
        for index in 0..<100 {
            let event = Budget.Event(kind: index.isMultiple(of: 2) ? .acceptError : .acceptRecovered,
                errno: 4, disposition: index.isMultiple(of: 2) ? .retry : .recovered, count: index + 1)
            if let line = budget.record(event, at: now) { emitted.append(line) }
        }
        XCTAssertEqual(emitted.count, 7)
        XCTAssertTrue(budget.hasPending)
        let last = try XCTUnwrap(budget.record(terminal, at: now))
        XCTAssertEqual(last.event, terminal)
        let summary = try XCTUnwrap(last.suppressed)
        XCTAssertEqual(summary.total, 93)
        XCTAssertEqual(summary.byEvent[.acceptError], 46)
        XCTAssertEqual(summary.byEvent[.acceptRecovered], 47)
        XCTAssertEqual(summary.first?.count, 8)
        XCTAssertEqual(summary.lastRecovery?.count, 100)
        XCTAssertFalse(budget.hasPending)
        XCTAssertNil(budget.record(terminal, at: now), "terminal events cannot bypass an empty bucket")
        XCTAssertEqual(budget.drain(at: now.advanced(by: .milliseconds(500)))?.suppressed?.lastTerminal, terminal)
    }

    func testRefillDoesNotGrantCreditTwiceAfterClockRegression() throws {
        let now = ContinuousClock.now
        var budget = Budget(now: now)
        for _ in 0..<7 { XCTAssertNotNil(budget.record(error, at: now)) }
        XCTAssertNotNil(budget.record(error, at: now.advanced(by: .milliseconds(500))))
        XCTAssertNil(budget.record(error, at: now.advanced(by: .milliseconds(250))))
        XCTAssertNil(budget.record(error, at: now.advanced(by: .milliseconds(500))))
        let next = try XCTUnwrap(budget.record(error, at: now.advanced(by: .seconds(1))))
        XCTAssertEqual(next.suppressed?.total, 2)
        XCTAssertNil(budget.drain(at: now.advanced(by: .seconds(1))), "withheld counts cannot be emitted twice")
    }

    func testPendingOrdinarySummaryWaitsForReserveAndRefill() {
        let now = ContinuousClock.now
        var budget = Budget(now: now)
        for _ in 0..<7 { _ = budget.record(error, at: now) }
        XCTAssertNotNil(budget.record(terminal, at: now))
        XCTAssertNil(budget.record(error, at: now))
        XCTAssertNil(budget.drain(at: now.advanced(by: .milliseconds(500))))
        let summary = budget.drain(at: now.advanced(by: .seconds(1)))
        XCTAssertNil(summary?.event)
        XCTAssertEqual(summary?.suppressed?.total, 1)
    }

    func testDiscardingPendingDoesNotRestoreBurst() {
        let now = ContinuousClock.now
        var budget = Budget(now: now)
        for _ in 0..<20 { _ = budget.record(error, at: now) }
        budget.discardPending()
        XCTAssertFalse(budget.hasPending)
        XCTAssertNil(budget.record(error, at: now))
        XCTAssertEqual(budget.drain(at: now.advanced(by: .milliseconds(500)))?.suppressed?.total, 1)
    }
    func testFormattedSummaryHasFixedPrivateFieldsAndNoDuplicatedCounts() throws {
        let now = ContinuousClock.now
        var budget = Budget(now: now)
        for _ in 0..<7 { _ = budget.record(error, at: now) }
        for kind in Budget.Kind.allCases {
            _ = budget.record(.init(kind: kind, errno: 5, disposition: .closed), at: now)
        }
        let emission = try XCTUnwrap(budget.drain(at: now.advanced(by: .milliseconds(500))))
        let line = DaemonLog.formatDiagnostic(timestamp: Date(timeIntervalSince1970: 0), emission: emission)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["timestamp", "event", "errno", "disposition", "count", "suppressed"])
        XCTAssertEqual(json["event"] as? String, "diagnostics_suppressed")
        let summary = try XCTUnwrap(json["suppressed"] as? [String: Any])
        XCTAssertEqual(summary["total"] as? Int, 7)
        XCTAssertEqual((summary["byEvent"] as? [String: Int])?.count, 7)
        let first = try XCTUnwrap(summary["first"] as? [String: Any])
        XCTAssertEqual(Set(first.keys), ["event", "errno", "disposition", "count"])
        XCTAssertNil(budget.drain(at: now.advanced(by: .seconds(5))))
    }

    func testSuppressionCountersSaturateWithoutGrowingUnboundedKeys() {
        var summary = Budget.Suppression(total: Int.max, byEvent: [.acceptError: Int.max], byDisposition: [.retry: Int.max])
        summary.append(error)
        XCTAssertEqual(summary.total, Int.max)
        XCTAssertEqual(summary.byEvent[.acceptError], Int.max)
        XCTAssertEqual(summary.byEvent.count, 1)
        XCTAssertEqual(summary.byDisposition[.retry], Int.max)
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { value } }
        func advance(_ duration: Duration) { lock.withLock { value = value.advanced(by: duration) } }
    }
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
        var objects: [[String: Any]] {
            all.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }

    func testActualWriterUsesOneBudgetAcrossAlternatingEvents() async throws {
        let clock = Clock()
        let sink = Sink()
        let server = DaemonServer.Instance(diagnosticClock: { clock.now })
        await server.setLogWriter({ sink.append($0) }, logFull: true)
        for index in 0..<100 {
            await server.recordDiagnostic(.init(kind: index.isMultiple(of: 2) ? .acceptError : .acceptRecovered,
                errno: Int32(index % 5 + 1), disposition: index.isMultiple(of: 2) ? .retry : .recovered))
        }
        XCTAssertEqual(sink.all.count, 7)
        clock.advance(.milliseconds(500))
        await server.recordDiagnostic(.init(kind: .setupRecovered, errno: 0, disposition: .recovered))
        XCTAssertEqual(sink.all.count, 8)
        let summary = try XCTUnwrap(sink.objects.last?["suppressed"] as? [String: Any])
        XCTAssertEqual(summary["total"] as? Int, 93)
        XCTAssertEqual((summary["first"] as? [String: Any])?["errno"] as? Int, 3)
        XCTAssertEqual((summary["lastRecovery"] as? [String: Any])?["errno"] as? Int, 5)
        await server.stop()
    }

    func testAcceptAndSetupEventsUseTheSharedWriterGate() async throws {
        let clock = Clock()
        let sink = Sink()
        let server = DaemonServer.Instance(diagnosticClock: { clock.now })
        await server.setLogWriter { sink.append($0) }
        var outcomes: [(fd: Int32, errno: Int32)] = []
        var peers: [Int32] = []
        defer { peers.forEach { close($0) } }
        for _ in 0..<20 {
            var pipeFDs: [Int32] = [-1, -1]
            XCTAssertEqual(pipe(&pipeFDs), 0)
            peers.append(pipeFDs[1])
            outcomes.append((-1, EINTR))
            outcomes.append((pipeFDs[0], 0))
        }
        outcomes.append((-1, EBADF)) // terminal comes from the real loop
        let script = DaemonAcceptRecoveryTests.ScriptedListener(outcomes)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var wake: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&wake), 0)
        defer { close(wake[1]) }
        await DaemonServer.Instance.acceptLoop(listenerFd: listener, wakeFd: wake[0], instance: server,
                                               environment: script.environment(realSleep: false))
        XCTAssertEqual(sink.all.count, 8, "seven ordinary lines plus the real terminal, with no credit reset")
        XCTAssertEqual(sink.objects.last?["errno"] as? Int, Int(EBADF))
        XCTAssertEqual(sink.objects.last?["disposition"] as? String, "stop")
        XCTAssertEqual((sink.objects.last?["suppressed"] as? [String: Any])?["total"] as? Int, 34)
        await server.stop()
    }

    actor Sleeper {
        private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]
        func sleep() async throws {
            let token = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiting[token] = continuation }
                }
            } onCancel: { Task { await self.cancel(token) } }
        }
        private func cancel(_ token: UUID) { waiting.removeValue(forKey: token)?.resume(throwing: CancellationError()) }
        func tick() { let next = waiting; waiting.removeAll(); next.values.forEach { $0.resume() } }
        var count: Int { waiting.count }
    }

    private func waitForSleeper(_ sleeper: Sleeper) async -> Bool {
        for _ in 0..<200 {
            if await sleeper.count == 1 { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func testTimerFlushesLastSummaryWithoutAnotherEvent() async throws {
        let clock = Clock(), sink = Sink(), sleeper = Sleeper()
        let flushed = expectation(description: "suppression summary reaches writer")
        let server = DaemonServer.Instance(diagnosticClock: { clock.now }, diagnosticSleep: { try await sleeper.sleep() })
        await server.setLogWriter { line in
            sink.append(line)
            if line.contains("diagnostics_suppressed") { flushed.fulfill() }
        }
        for _ in 0..<10 { await server.recordDiagnostic(error) }
        let waiting = await waitForSleeper(sleeper)
        XCTAssertTrue(waiting, "one periodic flusher must own the pending summary")
        clock.advance(.milliseconds(500))
        await sleeper.tick()
        await fulfillment(of: [flushed], timeout: 1)
        XCTAssertEqual(sink.all.count, 8)
        XCTAssertEqual((sink.objects.last?["suppressed"] as? [String: Any])?["total"] as? Int, 3)
        await server.stop()
        await sleeper.tick()
    }

    func testDisabledWriterDiscardsPendingTimerAndReplacementStartsClean() async throws {
        let clock = Clock(), old = Sink(), next = Sink(), sleeper = Sleeper()
        let server = DaemonServer.Instance(diagnosticClock: { clock.now }, diagnosticSleep: { try await sleeper.sleep() })
        await server.setLogWriter { old.append($0) }
        for _ in 0..<10 { await server.recordDiagnostic(error) }
        let waiting = await waitForSleeper(sleeper)
        XCTAssertTrue(waiting)
        await server.setLogWriter(nil)
        clock.advance(.seconds(1))
        await sleeper.tick()
        await server.setLogWriter { next.append($0) }
        await server.recordDiagnostic(.init(kind: .setupFailed, errno: 38, disposition: .closed))
        XCTAssertEqual(old.all.count, 7)
        XCTAssertEqual(next.all.count, 1)
        XCTAssertNil(next.objects.first?["suppressed"])
        await server.stop()
        await sleeper.tick()
    }

    func testSlowWriterDoesNotBlockStop() async {
        let entered = expectation(description: "writer blocked outside actor")
        let stopped = expectation(description: "stop returned without releasing writer")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = DaemonServer.Instance()
        await server.setLogWriter { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        let candidate = error
        let record = Task { await server.recordDiagnostic(candidate) }
        await fulfillment(of: [entered], timeout: 1)
        let stop = Task { await server.stop(); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 1)
        release.signal()
        await stop.value
        await record.value
    }

    func testFailedSchedulingSourceDoesNotRescheduleItself() async {
        struct FailedSleep: Error {}
        let attempts = Sink(), clock = Clock()
        let attempted = expectation(description: "first scheduling attempt")
        let server = DaemonServer.Instance(diagnosticClock: { clock.now }, diagnosticSleep: {
            attempts.append("attempt")
            if attempts.all.count == 1 { attempted.fulfill() }
            throw FailedSleep()
        })
        await server.setLogWriter { _ in }
        for _ in 0..<8 { await server.recordDiagnostic(error) }
        await fulfillment(of: [attempted], timeout: 1)
        try? await Task.sleep(for: .milliseconds(50))
        await server.stop()
        XCTAssertEqual(attempts.all.count, 1, "a failing scheduling source cannot create a busy retry loop")
    }

    func testBlockedOldFlusherDoesNotSpawnAnotherOrWriteIntoReplacement() async throws {
        let clock = Clock(), sleeper = Sleeper(), old = Sink(), next = Sink()
        let blocked = expectation(description: "old flusher is writing")
        let newFlushed = expectation(description: "new summary after old task finishes")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = DaemonServer.Instance(diagnosticClock: { clock.now }, diagnosticSleep: { try await sleeper.sleep() })
        await server.setLogWriter { line in
            old.append(line)
            if line.contains("diagnostics_suppressed") {
                blocked.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
        }
        for _ in 0..<8 { await server.recordDiagnostic(error) }
        let oldWaiting = await waitForSleeper(sleeper)
        XCTAssertTrue(oldWaiting)
        clock.advance(.milliseconds(500)); await sleeper.tick()
        await fulfillment(of: [blocked], timeout: 1)
        await server.setLogWriter { line in
            next.append(line)
            if line.contains("diagnostics_suppressed") { newFlushed.fulfill() }
        }
        for _ in 0..<10 { await server.recordDiagnostic(.init(kind: .setupFailed, errno: 38, disposition: .closed)) }
        let whileBlocked = await sleeper.count
        XCTAssertEqual(whileBlocked, 0, "old writer still owns the only flusher task")
        XCTAssertEqual(next.all.count, 7)
        clock.advance(.milliseconds(500))
        release.signal()
        let newWaiting = await waitForSleeper(sleeper)
        XCTAssertTrue(newWaiting)
        await sleeper.tick()
        await fulfillment(of: [newFlushed], timeout: 1)
        let summary = try XCTUnwrap(next.objects.last?["suppressed"] as? [String: Any])
        XCTAssertEqual(summary["total"] as? Int, 3)
        XCTAssertEqual(summary["byEvent"] as? [String: Int], ["connection_setup_failed": 3])
        XCTAssertEqual(old.all.count, 8)
        await server.stop(); await sleeper.tick()
    }

    func testStopStartDoesNotResetDiagnosticCredit() async throws {
        let clock = Clock(), sink = Sink(), sleeper = Sleeper()
        let server = DaemonServer.Instance(diagnosticClock: { clock.now }, diagnosticSleep: { try await sleeper.sleep() })
        await server.setLogWriter { sink.append($0) }
        let path = NSTemporaryDirectory() + "b197-" + String(UUID().uuidString.prefix(8)) + ".sock"
        defer { unlink(path) }
        do {
            try await server.start(socketPath: path)
            for _ in 0..<8 { await server.recordDiagnostic(error) }
            await server.stop()
            try await server.start(socketPath: path)
            await server.recordDiagnostic(error)
            XCTAssertEqual(sink.all.count, 7)
            await server.recordDiagnostic(terminal)
            XCTAssertEqual(sink.all.count, 8)
            XCTAssertEqual((sink.objects.last?["suppressed"] as? [String: Any])?["total"] as? Int, 1)
        } catch { await server.stop(); throw error }
        await server.stop(); await sleeper.tick()
    }

    func testQuietGapRefillsCreditWithoutDiscardingWithheldHistory() async {
        let clock = Clock(), sink = Sink(), sleeper = Sleeper()
        let server = DaemonServer.Instance(diagnosticClock: { clock.now }, diagnosticSleep: { try await sleeper.sleep() })
        await server.setLogWriter { sink.append($0) }
        for _ in 0..<20 { await server.recordDiagnostic(error) }
        XCTAssertEqual(sink.all.count, 7)
        clock.advance(.seconds(6))
        for _ in 0..<8 { await server.recordDiagnostic(.init(kind: .setupRecovered, errno: 0, disposition: .recovered)) }
        XCTAssertEqual(sink.all.count, 14)
        XCTAssertEqual((sink.objects[7]["suppressed"] as? [String: Any])?["total"] as? Int, 13)
        XCTAssertNil(sink.objects.last?["suppressed"])
        await server.stop(); await sleeper.tick()
    }

    func testWriterRejectsTheNanosecondBeforeRefillBoundary() async {
        let clock = Clock(), sink = Sink(), sleeper = Sleeper()
        let server = DaemonServer.Instance(diagnosticClock: { clock.now }, diagnosticSleep: { try await sleeper.sleep() })
        await server.setLogWriter { sink.append($0) }
        for _ in 0..<8 { await server.recordDiagnostic(error) }
        clock.advance(.nanoseconds(499_999_999))
        await server.recordDiagnostic(error)
        XCTAssertEqual(sink.all.count, 7)
        clock.advance(.nanoseconds(1))
        await server.recordDiagnostic(error)
        XCTAssertEqual(sink.all.count, 8)
        XCTAssertEqual((sink.objects.last?["suppressed"] as? [String: Any])?["total"] as? Int, 2)
        await server.stop(); await sleeper.tick()
    }

    func testTimerAndCandidateRacePreserveTheEntireCandidateCount() async {
        let candidate = error, ending = terminal
        for _ in 0..<10 {
            let clock = Clock(), sink = Sink(), sleeper = Sleeper()
            let server = DaemonServer.Instance(diagnosticClock: { clock.now }, diagnosticSleep: { try await sleeper.sleep() })
            await server.setLogWriter { sink.append($0) }
            for _ in 0..<100 { await server.recordDiagnostic(candidate) }
            let waiting = await waitForSleeper(sleeper)
            XCTAssertTrue(waiting)
            clock.advance(.milliseconds(500))
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await sleeper.tick() }
                group.addTask { await server.recordDiagnostic(candidate) }
            }
            await server.recordDiagnostic(ending)
            for _ in 0..<200 {
                if sink.all.count == 9 { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            let rows = sink.objects
            let admitted = rows.filter { $0["event"] as? String != "diagnostics_suppressed" }.count
            let withheld = rows.reduce(0) { $0 + (($1["suppressed"] as? [String: Any])?["total"] as? Int ?? 0) }
            XCTAssertEqual(rows.count, 9)
            XCTAssertEqual(admitted + withheld, 102, "the supplied candidate total is conserved across records and aggregates")
            await server.stop(); await sleeper.tick()
        }
    }

    func testAcceptLoopQuietGapAndChangedErrnoKeepSharedSummary() async {
        let clock = Clock(), sink = Sink(), sleeper = Sleeper()
        let server = DaemonServer.Instance(diagnosticClock: { clock.now }, diagnosticSleep: { try await sleeper.sleep() })
        await server.setLogWriter { sink.append($0) }
        var peers: [Int32] = [], outcomes: [(fd: Int32, errno: Int32)] = []
        defer { peers.forEach { close($0) } }
        for index in 0..<20 {
            var pair: [Int32] = [-1, -1]
            XCTAssertEqual(pipe(&pair), 0)
            peers.append(pair[1])
            outcomes += [(-1, index.isMultiple(of: 2) ? EINTR : ECONNABORTED), (pair[0], 0)]
        }
        outcomes += [(-1, EMFILE), (-1, EINTR), (-1, EBADF)]
        let script = DaemonAcceptRecoveryTests.ScriptedListener(outcomes, beforeAccept: { call in
            if call == 41 { clock.advance(.seconds(6)) }
        })
        var environment = script.environment(realSleep: false)
        environment.now = { clock.now }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var wake: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&wake), 0)
        defer { close(wake[1]) }
        await DaemonServer.Instance.acceptLoop(listenerFd: listener, wakeFd: wake[0], instance: server, environment: environment)
        let rows = sink.objects
        XCTAssertEqual(rows.count, 9)
        if rows.count == 9 {
            XCTAssertEqual(rows[7]["errno"] as? Int, Int(EMFILE))
            XCTAssertEqual(rows[7]["disposition"] as? String, "backoff")
            let summary = rows[7]["suppressed"] as? [String: Any]
            XCTAssertEqual(summary?["total"] as? Int, 34)
            XCTAssertEqual((summary?["first"] as? [String: Any])?["errno"] as? Int, Int(ECONNABORTED))
            XCTAssertEqual((summary?["lastRecovery"] as? [String: Any])?["errno"] as? Int, Int(ECONNABORTED))
            XCTAssertEqual(rows[8]["errno"] as? Int, Int(EBADF))
            XCTAssertEqual(rows[8]["disposition"] as? String, "stop")
        }
        await server.stop(); await sleeper.tick()
    }

    func testSuppressionRetainsBackoffClassBetweenOtherFailuresAndRecoveries() throws {
        let now = ContinuousClock.now
        var budget = Budget(now: now)
        for _ in 0..<7 { _ = budget.record(error, at: now) }
        for event in [error,
            Budget.Event(kind: .acceptError, errno: EMFILE, disposition: .backoff),
            Budget.Event(kind: .acceptRecovered, errno: EMFILE, disposition: .recovered),
            error, Budget.Event(kind: .acceptRecovered, errno: EINTR, disposition: .recovered)] {
            XCTAssertNil(budget.record(event, at: now))
        }
        let emission = try XCTUnwrap(budget.drain(at: now.advanced(by: .milliseconds(500))))
        let encoded = DaemonLog.formatDiagnostic(timestamp: Date(timeIntervalSince1970: 0), emission: emission)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let summary = try XCTUnwrap(object["suppressed"] as? [String: Any])
        XCTAssertEqual(summary["byDisposition"] as? [String: Int], ["retry": 2, "backoff": 1, "recovered": 2])
        XCTAssertEqual(summary["total"] as? Int, 5)
    }

}
