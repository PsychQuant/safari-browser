import Foundation
import XCTest
@testable import SafariBrowser

final class PerformanceTraceTests: XCTestCase {
    private enum Failure: Error { case sentinel(String) }

    func testNestedDurationsAreInclusiveAndLinked() throws {
        let clock = TraceTestClock()
        let collector = PerformanceTrace.Collector(clock: clock.now)
        let value = PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
            PerformanceTrace.span(.command) {
                clock.advance(10)
                PerformanceTrace.span(.targetResolve) { clock.advance(20) }
                clock.advance(7)
                return 42
            }
        }
        XCTAssertEqual(value, 42)
        let result = try XCTUnwrap(collector.finish(status: .ok))
        XCTAssertEqual(result.totalNanoseconds, 37)
        XCTAssertEqual(result.spans.count, 2)
        XCTAssertEqual(result.spans.first?.durationNanoseconds, 37)
        XCTAssertEqual(result.spans.last?.durationNanoseconds, 20)
        XCTAssertEqual(result.spans.last?.parentID, result.spans.first?.id)
    }

    func testThrownOperationRunsOnceAndContentsAreAbsent() throws {
        let collector = PerformanceTrace.Collector()
        var calls = 0
        let secret = "private-selector-script-and-path"
        XCTAssertThrowsError(try PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
            try PerformanceTrace.span(.command) { calls += 1; throw Failure.sentinel(secret) }
        }) { error in
            guard case Failure.sentinel(let original) = error else { return XCTFail("error changed") }
            XCTAssertEqual(original, secret)
        }
        XCTAssertEqual(calls, 1)
        let summary = try XCTUnwrap(collector.finish(status: .error))
        XCTAssertEqual(summary.spans.first?.outcome, .error)
        let line = try XCTUnwrap(PerformanceTrace.line(summary))
        XCTAssertLessThanOrEqual(line.count, 65536)
        XCTAssertFalse(String(decoding: line, as: UTF8.self).contains(secret))
    }

    func testFinishIsOnceAndLateWorkerCannotChangeSnapshot() throws {
        let clock = TraceTestClock()
        let collector = PerformanceTrace.Collector(clock: clock.now)
        let token = try XCTUnwrap(collector.begin(.axInspect))
        clock.advance(5)
        let snapshot = try XCTUnwrap(collector.finish(status: .error))
        XCTAssertEqual(snapshot.spans.first?.outcome, .unfinished)
        XCTAssertEqual(snapshot.spans.first?.durationNanoseconds, 5)
        clock.advance(100)
        collector.end(token, outcome: .ok)
        XCTAssertNil(collector.begin(.processWait))
        XCTAssertNil(collector.finish(status: .ok))
        XCTAssertEqual(snapshot.spans.first?.durationNanoseconds, 5)
    }

    func testConcurrentSpansAreBounded() throws {
        let collector = PerformanceTrace.Collector(maxSpans: 999)
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
                PerformanceTrace.span(.axInspect) {}
            }
        }
        let result = try XCTUnwrap(collector.finish(status: .ok))
        XCTAssertEqual(result.spans.count, 64)
        XCTAssertEqual(result.droppedSpans, 936)
        XCTAssertEqual(Set(result.spans.map(\.id)).count, 64)
    }

    func testEnabledRequiresExactOne() {
        for value in ["", "0", "true", "yes", " 1"] {
            XCTAssertFalse(PerformanceTrace.isEnabled(["SAFARI_BROWSER_TRACE_TIMING": value]))
        }
        XCTAssertFalse(PerformanceTrace.isEnabled([:]))
        XCTAssertTrue(PerformanceTrace.isEnabled(["SAFARI_BROWSER_TRACE_TIMING": "1"]))
        XCTAssertEqual(PerformanceTrace.span(.command) { 17 }, 17)
    }

    func testAsyncContextsDoNotShareRequests() async {
        let summaries = await withTaskGroup(of: PerformanceTrace.Summary.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let collector = PerformanceTrace.Collector()
                    await PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
                        await PerformanceTrace.spanAsync(.command) { await Task.yield() }
                    }
                    return collector.finish(status: .ok)!
                }
            }
            var output: [PerformanceTrace.Summary] = []
            for await item in group { output.append(item) }
            return output
        }
        XCTAssertEqual(Set(summaries.map(\.requestID)).count, 12)
        XCTAssertTrue(summaries.allSatisfy { $0.spans.count == 1 && $0.spans[0].parentID == nil })
        XCTAssertNil(PerformanceTrace.context)
    }

    private func remote() -> [String: Any] {
        ["schemaVersion": 1, "requestID": UUID().uuidString, "status": "ok", "totalNanoseconds": 8,
         "spans": [["id": 1, "phase": "daemon.request", "durationNanoseconds": 8, "outcome": "ok"],
                   ["id": 2, "parentID": 1, "phase": "daemon.compile", "durationNanoseconds": 3, "outcome": "ok"]],
         "droppedSpans": 0]
    }

    func testRemoteMetadataIsBoundedAndReparented() throws {
        let collector = PerformanceTrace.Collector()
        let parent = try XCTUnwrap(collector.begin(.appleScriptDaemon))
        var object = remote()
        object["source"] = "secret-source-that-must-not-be-forwarded"
        XCTAssertTrue(collector.importRemote(object, parentID: parent))
        collector.end(parent, outcome: .ok)
        let result = try XCTUnwrap(collector.finish(status: .ok))
        XCTAssertEqual(result.spans.map(\.id), [1, 2, 3])
        XCTAssertEqual(result.spans.map(\.parentID), [nil, 1, 2])
        XCTAssertFalse(String(decoding: try XCTUnwrap(PerformanceTrace.line(result)), as: UTF8.self).contains("secret"))
    }

    func testMalformedRemoteMetadataIsIgnored() throws {
        for bad: [String: Any] in [
            ["schemaVersion": 2],
            ["requestID": "not-a-uuid"],
            ["spans": [["id": 1, "phase": "private-url", "durationNanoseconds": 1, "outcome": "ok"]]],
            ["spans": [["id": 1, "parentID": 1, "phase": "command", "durationNanoseconds": 1, "outcome": "ok"]]],
            ["spans": [["id": 1, "phase": "command", "durationNanoseconds": true, "outcome": "ok"]]],
            ["totalNanoseconds": -1], ["status": "unfinished"], ["processID": 0], ["processID": -1], ["processID": true]
        ] {
            let collector = PerformanceTrace.Collector()
            var object = remote(); object.merge(bad) { _, value in value }
            XCTAssertFalse(collector.importRemote(object, parentID: nil))
            XCTAssertEqual(collector.finish(status: .ok)?.spans.count, 0)
        }
    }
}

private final class TraceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: UInt64 = 0
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ value: UInt64) { lock.lock(); time += value; lock.unlock() }
}
