import XCTest
@testable import SafariBrowser

/// #174: `importRemote` re-encoded whatever timing object a daemon sent and
/// only then compared the encoding with its 64 KiB limit. The size is now
/// bounded from below by walking the object first: an object whose bound is
/// already over the limit is rejected without being encoded.
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

    func testNumbersBooleansAndEscapesCountTowardTheBound() {
        // Verify R1: every non-string scalar counted as one byte, so an object
        // made of large numbers passed the pre-check at a fraction of its
        // encoded size and was re-encoded anyway.
        let numbers: [String: Any] = ["n": Array(repeating: 99_999_999_999_999, count: 10_000)]
        XCTAssertNil(PerformanceTrace.jsonSizeLowerBound(numbers, budget: 65_536))
        let flags: [String: Any] = ["b": Array(repeating: false, count: 20_000)]
        XCTAssertNil(PerformanceTrace.jsonSizeLowerBound(flags, budget: 65_536))
        let controls: [String: Any] = ["s": String(repeating: "\u{0}", count: 40_000)]
        XCTAssertNil(PerformanceTrace.jsonSizeLowerBound(controls, budget: 65_536))
    }

    func testTightenedBoundStillNeverExceedsTheEncoding() throws {
        let object: [String: Any] = [
            "ints": [0, -1, 7, 42, -99_999, Int64.max, Int64.min] as [Any],
            "doubles": [0.1, 1e300, -2.5e-8, 3.0] as [Any],
            "flags": [true, false],
            "text": "a/b \"quoted\" back\\slash\n\t\u{0}\u{1f} ünïcödé 漢字 🙂",
            "null": NSNull(),
            "nested": [["k/": ["v": [1, 2, [3]]]]] as [Any],
        ]
        let encoded = try JSONSerialization.data(withJSONObject: object).count
        let bound = try XCTUnwrap(PerformanceTrace.jsonSizeLowerBound(object, budget: 1 << 20))
        XCTAssertLessThanOrEqual(bound, encoded, "bound \(bound) > encoding \(encoded) would reject legal input")
        XCTAssertGreaterThan(Double(bound), 0.6 * Double(encoded), "the bound should be close to the encoding for these values")
    }

    func testImportRejectsOversizedAndAcceptsLegitimateMetadata() {
        let collector = PerformanceTrace.Collector()
        XCTAssertFalse(collector.importRemote(["blob": String(repeating: "x", count: 200_000)], parentID: nil))
        XCTAssertTrue(collector.importRemote(summary(spans: 3), parentID: nil))
    }
}
