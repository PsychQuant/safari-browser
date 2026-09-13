import Foundation
import XCTest
@testable import SafariBrowser

final class BoundedAXWorkerTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testInvalidBudgetsDoNotRunOrAcquireTheAllowance() {
        let worker = BoundedAXWorker()
        let calls = Counter()
        for budget in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(worker.run(budget: budget, fallback: "unknown") { _ in
                calls.increment()
                return "unexpected"
            }, "unknown")
        }
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(worker.withExclusive(fallback: "busy") { "available" }, "available")
    }

    func testHugeFiniteBudgetIsCappedWithoutDeadlineOverflow() {
        let worker = BoundedAXWorker()
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = worker.run(budget: Double.greatestFiniteMagnitude, fallback: UInt64(0)) {
            $0.uptimeNanoseconds
        }
        XCTAssertGreaterThan(deadline, started)
        XCTAssertLessThanOrEqual(Double(deadline - started) / 1_000_000_000, 0.81)
    }

    func testCallerBudgetReachesOperationAsAnAbsoluteDeadline() {
        let worker = BoundedAXWorker()
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = worker.run(budget: 0.04, fallback: UInt64(0)) { $0.uptimeNanoseconds }
        XCTAssertGreaterThan(deadline, started)
        XCTAssertLessThanOrEqual(Double(deadline - started) / 1_000_000_000, 0.05)
    }

    func testTimeoutKeepsAllowanceAndBusyCallsAreNeverQueued() {
        let worker = BoundedAXWorker()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let calls = Counter()
        defer { release.signal() }
        let started = Date()
        XCTAssertEqual(worker.run(budget: 0.02, fallback: "timeout") { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            finished.signal()
            return "late"
        }, "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        XCTAssertEqual(entered.wait(timeout: .now() + 0.5), .success)
        let busyStarted = Date()
        for _ in 0..<10 {
            XCTAssertEqual(worker.run(budget: 0.8, fallback: "busy") { _ in
                calls.increment()
                return "unexpected"
            }, "busy")
        }
        XCTAssertLessThan(Date().timeIntervalSince(busyStarted), 0.1)
        XCTAssertEqual(calls.count, 0)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 0.5), .success)
        assertEventuallyAvailable(worker)
        XCTAssertEqual(calls.count, 0, "rejected operations must never run after the old worker ends")
    }

    func testLateValueCannotContaminateANewCallWithDifferentResultType() {
        let worker = BoundedAXWorker()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        XCTAssertEqual(worker.run(budget: 0.01, fallback: "timeout") { _ in
            _ = release.wait(timeout: .now() + 2)
            return "old value"
        }, "timeout")
        release.signal()
        assertEventuallyAvailable(worker)
        XCTAssertEqual(worker.run(budget: 0.1, fallback: -1) { _ in 42 }, 42)
    }

    func testBackgroundReadExcludesSynchronousActionEvenAfterTimeout() {
        let worker = BoundedAXWorker()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        XCTAssertFalse(worker.run(budget: 0.01, fallback: false) { _ in
            _ = release.wait(timeout: .now() + 2)
            return true
        })
        var actionCalled = false
        XCTAssertEqual(worker.withExclusive(fallback: "busy") {
            actionCalled = true
            return "pressed"
        }, "busy")
        XCTAssertFalse(actionCalled)
        release.signal()
        assertEventuallyAvailable(worker)
    }

    func testSynchronousActionExcludesBackgroundReadsAndNestedActions() {
        let worker = BoundedAXWorker()
        let calls = Counter()
        let result = worker.withExclusive(fallback: "busy") {
            XCTAssertEqual(worker.run(budget: 0.8, fallback: "busy") { _ in
                calls.increment()
                return "unexpected"
            }, "busy")
            XCTAssertEqual(worker.withExclusive(fallback: "busy") {
                calls.increment()
                return "unexpected"
            }, "busy")
            return "done"
        }
        XCTAssertEqual(result, "done")
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(worker.run(budget: 0.1, fallback: "busy") { _ in "available" }, "available")
    }

    func testExclusiveOperationStaysOnCallingThreadAndAllowsNonSendableValues() {
        let worker = BoundedAXWorker()
        let thread = Thread.current
        let value = NSMutableString(string: "local node")
        let result = worker.withExclusive(fallback: value) {
            XCTAssertTrue(Thread.current === thread)
            value.append(" retained")
            return value
        }
        XCTAssertTrue(result === value)
        XCTAssertEqual(result as String, "local node retained")
    }

    private struct EmptyProvider: DialogProbeProvider {
        let calls: Counter
        func windows(timeout: Float) throws -> [Int] { calls.increment(); return [] }
        func windowID(_ node: Int, timeout: Float) throws -> Int { node }
        func role(_ node: Int, timeout: Float) throws -> String { "AXWindow" }
        func subrole(_ node: Int, timeout: Float) throws -> String? { nil }
        func children(_ node: Int, timeout: Float) throws -> [Int] { [] }
        func valueIsSettable(_ node: Int, timeout: Float) throws -> Bool? { nil }
        func text(_ node: Int, timeout: Float) throws -> String? { nil }
        func buttonTitle(_ node: Int, timeout: Float) throws -> String? { nil }
    }

    func testInjectedAllowanceExcludesEntryProbeWithoutConstructingProvider() {
        let worker = BoundedAXWorker()
        let calls = Counter()
        let factories = Counter()
        let probe = BoundedDialogProbe(worker: worker) {
            factories.increment()
            return EmptyProvider(calls: calls)
        }
        let state = worker.withExclusive(fallback: BlockingDialogState.clear) {
            probe.check(windowKey: .front)
        }
        XCTAssertEqual(state, .unprobed)
        XCTAssertEqual(factories.count, 0)
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(probe.check(windowKey: .front), .clear)
        XCTAssertEqual(factories.count, 1)
        XCTAssertEqual(calls.count, 1)
    }

    private func assertEventuallyAvailable(
        _ worker: BoundedAXWorker, file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(0.5)
        repeat {
            if worker.withExclusive(fallback: false, operation: { true }) { return }
            Thread.sleep(forTimeInterval: 0.001)
        } while Date() < deadline
        XCTFail("worker did not release its allowance after completion", file: file, line: line)
    }
}
