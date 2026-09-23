import XCTest
@testable import SafariBrowser

/// #174: `importRemote` re-encoded whatever timing object a daemon sent and
/// only then compared the encoding with its 64 KiB limit. The size is now
/// bounded from below by walking the object first, so an oversized object is
/// rejected without being encoded.
final class PerformanceTraceImportBoundTests: XCTestCase {
    private func summary(spans: Int, phase: String = "command") -> [String: Any] {
        [
            "schemaVersion": 1,
            "requestID": "01234567-89ab-4cde-8fab-0123456789ab",
            "status": "ok",
            "totalNanoseconds": 200,
            "droppedSpans": 0,
            "spans": (1...max(spans, 1)).prefix(spans).map { id -> [String: Any] in
                ["id": id, "phase": phase, "durationNanoseconds": 10, "outcome": "ok"]
            },
        ]
    }

    func testLowerBoundNeverExceedsTheActualEncoding() throws {
        for object in [summary(spans: 1), summary(spans: 64), ["a": [1, "two", NSNull(), ["x": true]]] as [String: Any]] {
            let encoded = try JSONSerialization.data(withJSONObject: object).count
            let bound = try XCTUnwrap(PerformanceTrace.jsonSizeLowerBound(object, budget: 1 << 20))
            XCTAssertLessThanOrEqual(bound, encoded, "a lower bound larger than the encoding would reject legal input")
        }
    }

    func testOversizedObjectStopsAtTheBudget() {
        let huge: [String: Any] = ["spans": [], "blob": String(repeating: "x", count: 200_000)]
        XCTAssertNil(PerformanceTrace.jsonSizeLowerBound(huge, budget: 65_536))
        let many: [String: Any] = ["spans": Array(repeating: ["id": 1], count: 100_000)]
        XCTAssertNil(PerformanceTrace.jsonSizeLowerBound(many, budget: 65_536))
    }

    func testImportRejectsOversizedAndAcceptsLegitimateMetadata() {
        let collector = PerformanceTrace.Collector()
        XCTAssertFalse(collector.importRemote(["blob": String(repeating: "x", count: 200_000)], parentID: nil))
        XCTAssertTrue(collector.importRemote(summary(spans: 3), parentID: nil))
    }
}
