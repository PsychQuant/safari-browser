import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonRequestCompletionTests: XCTestCase {
    private final class Box<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        func read() -> Value { lock.withLock { stored } }
        func update(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
    }

    private actor Gate {
        private var opened = false
        private var waiting: CheckedContinuation<Void, Never>?
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func open() {
            opened = true
            waiting?.resume()
            waiting = nil
        }
    }

    private final class Payload: Sendable {
        private let onRelease: @Sendable () -> Void
        init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
        deinit { onRelease() }
    }

    /// 逾時只回報失敗，不 join 可能尚未結束的工作。
    private func observe<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let finished = expectation(description: "operation completed")
        let result = Box<Value?>(nil)
        let task = Task {
            let value = await operation()
            result.update { $0 = .some(value) }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        task.cancel()
        return result.read()
    }

    func testCompleteBeforeWaitPreservesFirstResultAgainstCancel() async {
        let completion = DaemonRequestCompletion<Int>()
        XCTAssertTrue(completion.complete(42))
        completion.cancel()
        XCTAssertFalse(completion.complete(99))
        let value = await observe { await completion.wait() }
        XCTAssertEqual(value, .some(42))
        let repeated = await observe { await completion.wait() }
        XCTAssertEqual(repeated, .some(nil))
    }

    func testWaitingConsumerReceivesResult() async {
        let completion = DaemonRequestCompletion<Int>()
        let entered = expectation(description: "consumer entered")
        let finished = expectation(description: "consumer finished")
        let values = Box<[Int?]>([])
        let task = Task {
            entered.fulfill()
            let value = await completion.wait()
            values.update { $0.append(value) }
            finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        // 讓等待者有機會安裝 continuation；結果仍未提供時不可自行完成。
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(values.read().isEmpty)
        XCTAssertTrue(completion.complete(7))
        await fulfillment(of: [finished], timeout: 2)
        task.cancel()
        XCTAssertEqual(values.read(), [7])
        XCTAssertFalse(completion.complete(8))
    }

    func testCancelBeforeWaitRejectsAllLaterResults() async {
        let completion = DaemonRequestCompletion<Int>()
        completion.cancel()
        completion.cancel()
        XCTAssertFalse(completion.complete(42))
        let value = await observe { await completion.wait() }
        XCTAssertEqual(value, .some(nil))
        XCTAssertFalse(completion.complete(99))
    }

    func testCancellationBeforeWaitRegistrationCompletes() async {
        let completion = DaemonRequestCompletion<Int>()
        let gate = Gate()
        let finished = expectation(description: "already cancelled consumer finished")
        let value = Box<Int??>(nil)
        let task = Task {
            await gate.wait()
            let result = await completion.wait()
            value.update { $0 = .some(result) }
            finished.fulfill()
        }
        task.cancel()
        await gate.open()
        await fulfillment(of: [finished], timeout: 2)
        completion.cancel()
        XCTAssertEqual(value.read(), .some(nil))
        XCTAssertFalse(completion.complete(1))
    }

    func testWaitTaskCancellationDoesNotWaitForNoncooperativeHandler() async {
        let completion = DaemonRequestCompletion<Int>()
        let gate = Gate()
        let handlerStarted = expectation(description: "handler started")
        let handlerFinished = expectation(description: "handler returned after gate")
        let consumerStarted = expectation(description: "consumer started")
        let consumerFinished = expectation(description: "consumer cancelled")
        let accepted = Box<Bool?>(nil)
        let result = Box<Int??>(nil)
        let handler = Task {
            handlerStarted.fulfill()
            await gate.wait()
            accepted.update { $0 = completion.complete(9) }
            handlerFinished.fulfill()
        }
        let consumer = Task {
            consumerStarted.fulfill()
            let value = await completion.wait()
            result.update { $0 = .some(value) }
            consumerFinished.fulfill()
        }
        await fulfillment(of: [handlerStarted, consumerStarted], timeout: 2)
        for _ in 0..<10 { await Task.yield() }
        consumer.cancel()
        await fulfillment(of: [consumerFinished], timeout: 2)
        XCTAssertEqual(result.read(), .some(nil))
        XCTAssertNil(accepted.read(), "handler remains active until the fixture gate opens")
        await gate.open()
        await fulfillment(of: [handlerFinished], timeout: 2)
        handler.cancel()
        XCTAssertEqual(accepted.read(), false)
    }

    func testConcurrentResultsAcceptExactlyOneValue() async {
        let completion = DaemonRequestCompletion<Int>()
        let accepted = Box<[Int]>([])
        DispatchQueue.concurrentPerform(iterations: 64) { value in
            if completion.complete(value) { accepted.update { $0.append(value) } }
        }
        XCTAssertEqual(accepted.read().count, 1)
        let result = await observe { await completion.wait() }
        XCTAssertEqual(result, .some(accepted.read().first))
    }

    func testConcurrentCompletionAndCancellationResolveOnlyOnce() async {
        for _ in 0..<32 {
            let completion = DaemonRequestCompletion<Int>()
            let accepted = Box<[Int]>([])
            let finished = expectation(description: "one terminal result")
            finished.assertForOverFulfill = true
            let observed = Box<Int??>(nil)
            let waiter = Task {
                let value = await completion.wait()
                observed.update { $0 = .some(value) }
                finished.fulfill()
            }
            DispatchQueue.concurrentPerform(iterations: 16) { value in
                if value.isMultiple(of: 2) {
                    completion.cancel()
                } else if completion.complete(value) {
                    accepted.update { $0.append(value) }
                }
            }
            await fulfillment(of: [finished], timeout: 2)
            waiter.cancel()
            XCTAssertLessThanOrEqual(accepted.read().count, 1)
            XCTAssertEqual(observed.read(), .some(accepted.read().first))
            XCTAssertFalse(completion.complete(99))
        }
    }

    func testConcurrentDuplicateWaitDoesNotReplaceOrStrandConsumer() async {
        let completion = DaemonRequestCompletion<Int>()
        let entered = expectation(description: "both consumers entered")
        entered.expectedFulfillmentCount = 2
        let finished = expectation(description: "both consumers finished")
        finished.expectedFulfillmentCount = 2
        let observed = Box<[Int?]>([])
        let tasks = (0..<2).map { _ in
            Task {
                entered.fulfill()
                let value = await completion.wait()
                observed.update { $0.append(value) }
                finished.fulfill()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(completion.complete(3))
        await fulfillment(of: [finished], timeout: 2)
        tasks.forEach { $0.cancel() }
        XCTAssertEqual(observed.read().count, 2)
        XCTAssertEqual(observed.read().compactMap { $0 }, [3])
        XCTAssertEqual(observed.read().filter { $0 == nil }.count, 1)
    }

    func testConsumedCompletionReleasesPayloadAndRejectsLatePayload() async {
        let completion = DaemonRequestCompletion<Payload>()
        let released = expectation(description: "consumed payload released")
        weak var weakPayload: Payload?
        do {
            let payload = Payload { released.fulfill() }
            weakPayload = payload
            XCTAssertTrue(completion.complete(payload))
        }
        XCTAssertNotNil(weakPayload)
        let consumed = await observe { await completion.wait() != nil }
        XCTAssertEqual(consumed, true)
        await fulfillment(of: [released], timeout: 2)
        XCTAssertNil(weakPayload)
        let lateReleased = expectation(description: "payload after consumption released")
        do {
            let payload = Payload { lateReleased.fulfill() }
            weakPayload = payload
            XCTAssertFalse(completion.complete(payload))
        }
        await fulfillment(of: [lateReleased], timeout: 2)
        XCTAssertNil(weakPayload)
        withExtendedLifetime(completion) {}
    }

    func testCancelledCompletionDoesNotRetainLatePayload() async {
        let completion = DaemonRequestCompletion<Payload>()
        completion.cancel()
        let released = expectation(description: "late payload released")
        weak var weakPayload: Payload?
        do {
            let payload = Payload { released.fulfill() }
            weakPayload = payload
            XCTAssertFalse(completion.complete(payload))
        }
        await fulfillment(of: [released], timeout: 2)
        XCTAssertNil(weakPayload)
        let cancelled = await observe { await completion.wait() == nil }
        XCTAssertEqual(cancelled, true)
        withExtendedLifetime(completion) {}
    }
}
