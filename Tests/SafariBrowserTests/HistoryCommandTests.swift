import XCTest

@testable import SafariBrowser

/// #109: `history_visits.visit_time` is Core Data reference time — seconds
/// since 2001-01-01 UTC, not the Unix epoch. Getting this wrong produces
/// timestamps that are silently off by roughly 31 years and raises no error
/// anywhere, which is precisely why it gets its own test with fixed values
/// rather than being checked by eye against live data.
final class HistoryCommandTests: XCTestCase {

    // MARK: - Core Data epoch conversion

    func testCoreDataEpochOffsetMatchesTheKnownConstant() {
        XCTAssertEqual(HistoryCommand.coreDataEpochOffset, 978_307_200)
    }

    func testConvertsKnownReferenceTimes() {
        // Values from the local-data-query spec's example table.
        let cases: [(Double, TimeInterval, String)] = [
            (0, 978_307_200, "2001-01-01T00:00:00Z"),
            (1, 978_307_201, "2001-01-01T00:00:01Z"),
            (788_918_400, 1_767_225_600, "2026-01-01T00:00:00Z"),
        ]

        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")

        for (reference, expectedUnix, expectedISO) in cases {
            let date = HistoryCommand.date(fromCoreDataReferenceTime: reference)
            XCTAssertEqual(
                date.timeIntervalSince1970, expectedUnix, accuracy: 0.001,
                "reference time \(reference) should map to Unix \(expectedUnix)")
            XCTAssertEqual(iso.string(from: date), expectedISO)
        }
    }

    func testUnconvertedValueWouldLandDecadesEarlier() {
        // Guards the failure mode itself: if the offset were ever dropped,
        // a 2026 visit would render as 1995. Assert the gap explicitly so a
        // regression cannot pass by "looking like a date".
        let reference = 788_918_400.0
        let correct = HistoryCommand.date(fromCoreDataReferenceTime: reference)
        let naive = Date(timeIntervalSince1970: reference)

        let yearsApart =
            correct.timeIntervalSince(naive) / (365.25 * 24 * 60 * 60)
        XCTAssertEqual(yearsApart, 31.0, accuracy: 0.1)

        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(calendar.component(.year, from: correct), 2026)
        XCTAssertEqual(calendar.component(.year, from: naive), 1995)
    }

    // MARK: - --since parsing

    func testParsesSinceDate() throws {
        let parsed = try XCTUnwrap(HistoryCommand.parseSinceDate("2026-01-01"))
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(calendar.component(.year, from: parsed), 2026)
        XCTAssertEqual(calendar.component(.month, from: parsed), 1)
        XCTAssertEqual(calendar.component(.day, from: parsed), 1)
    }

    func testRejectsMalformedSinceDate() {
        XCTAssertNil(HistoryCommand.parseSinceDate("01/01/2026"))
        XCTAssertNil(HistoryCommand.parseSinceDate("yesterday"))
        XCTAssertNil(HistoryCommand.parseSinceDate(""))
    }

    // MARK: - Text row formatting

    func testTextRowKeepsStdoutParseable() {
        let row = HistoryVisit(
            url: "https://example.com/page",
            title: "Example Page",
            visitTime: Date(timeIntervalSince1970: 1_767_225_600),
            visitCount: 3)

        let line = HistoryCommand.formatRow(index: 1, visit: row, timeZone: TimeZone(identifier: "UTC")!)

        XCTAssertTrue(line.hasPrefix("[1]"), "index prefix follows the documents convention")
        XCTAssertTrue(line.contains("https://example.com/page"))
        XCTAssertTrue(line.contains("Example Page"))
        XCTAssertFalse(line.contains("\n"), "a row must stay on one line so line-oriented tools work")
    }

    func testTextRowHandlesMissingTitle() {
        let row = HistoryVisit(
            url: "https://example.com/",
            title: nil,
            visitTime: Date(timeIntervalSince1970: 1_767_225_600),
            visitCount: 1)

        let line = HistoryCommand.formatRow(index: 2, visit: row, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(line.contains("https://example.com/"))
        XCTAssertFalse(line.contains("nil"), "a missing title must not leak the word 'nil'")
    }

    // MARK: - JSON encoding

    func testJSONUsesISO8601WithOffsetAndDocumentedKeys() throws {
        let row = HistoryVisit(
            url: "https://example.com/",
            title: "Example",
            visitTime: Date(timeIntervalSince1970: 1_767_225_600),
            visitCount: 7)

        let data = try HistoryCommand.encodeJSON([row])
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(Set(parsed[0].keys), ["url", "title", "visit_time", "visit_count"])
        XCTAssertEqual(parsed[0]["visit_count"] as? Int, 7)

        let stamp = try XCTUnwrap(parsed[0]["visit_time"] as? String)
        XCTAssertNotNil(
            ISO8601DateFormatter().date(from: stamp),
            "\(stamp) must parse as ISO 8601")
        XCTAssertTrue(
            stamp.hasSuffix("Z") || stamp.contains("+") || stamp.dropFirst(1).contains("-"),
            "the spec requires a time zone offset, not a naive local stamp")
    }

    func testEmptyResultEncodesAsEmptyArray() throws {
        let data = try HistoryCommand.encodeJSON([])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[]")
    }
}
