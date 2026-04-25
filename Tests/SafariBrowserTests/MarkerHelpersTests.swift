import XCTest
@testable import SafariBrowser

/// Pure-string tests for `MarkerConstants`. The marker is a hardcoded
/// zero-width-space pair (`U+200B` ... `U+200B`) per Requirement: Marker
/// content is hardcoded, no caller input. No live Safari needed.
final class MarkerHelpersTests: XCTestCase {

    private let zwsp = "\u{200B}"

    // MARK: - Constants

    func testPrefix_isZeroWidthSpace() {
        XCTAssertEqual(MarkerConstants.prefix, zwsp)
    }

    func testSuffix_isZeroWidthSpace() {
        XCTAssertEqual(MarkerConstants.suffix, zwsp)
    }

    // MARK: - wrap

    func testWrap_addsPrefixAndSuffix() {
        let wrapped = MarkerConstants.wrap(title: "Dashboard")
        XCTAssertEqual(wrapped, "\(zwsp)Dashboard\(zwsp)")
    }

    func testWrap_isIdempotent_doesNotDoubleWrap() {
        let once = MarkerConstants.wrap(title: "Dashboard")
        let twice = MarkerConstants.wrap(title: once)
        XCTAssertEqual(once, twice, "wrapping an already-marked title should be a no-op")
    }

    func testWrap_handlesEmptyTitle() {
        let wrapped = MarkerConstants.wrap(title: "")
        XCTAssertEqual(wrapped, "\(zwsp)\(zwsp)")
    }

    func testWrap_preservesUnicodeInOriginal() {
        let title = "計算機 — Dashboard 🌐"
        let wrapped = MarkerConstants.wrap(title: title)
        XCTAssertEqual(wrapped, "\(zwsp)\(title)\(zwsp)")
    }

    // MARK: - unwrap

    func testUnwrap_returnsOriginalForMarkedTitle() {
        let wrapped = "\(zwsp)Dashboard\(zwsp)"
        XCTAssertEqual(MarkerConstants.unwrap(title: wrapped), "Dashboard")
    }

    func testUnwrap_returnsNilForUnmarkedTitle() {
        XCTAssertNil(MarkerConstants.unwrap(title: "Dashboard"))
    }

    func testUnwrap_returnsNilForPartialMarker_prefixOnly() {
        XCTAssertNil(MarkerConstants.unwrap(title: "\(zwsp)Dashboard"))
    }

    func testUnwrap_returnsNilForPartialMarker_suffixOnly() {
        XCTAssertNil(MarkerConstants.unwrap(title: "Dashboard\(zwsp)"))
    }

    func testUnwrap_handlesEmptyMarkedTitle() {
        XCTAssertEqual(MarkerConstants.unwrap(title: "\(zwsp)\(zwsp)"), "")
    }

    func testUnwrap_preservesInternalUnicode() {
        let original = "計算機 — Dashboard 🌐"
        let wrapped = MarkerConstants.wrap(title: original)
        XCTAssertEqual(MarkerConstants.unwrap(title: wrapped), original)
    }

    // MARK: - hasMarker

    func testHasMarker_trueForFullyWrappedTitle() {
        XCTAssertTrue(MarkerConstants.hasMarker(title: "\(zwsp)Dashboard\(zwsp)"))
    }

    func testHasMarker_falseForPlainTitle() {
        XCTAssertFalse(MarkerConstants.hasMarker(title: "Dashboard"))
    }

    func testHasMarker_falseForPartiallyWrappedTitle() {
        XCTAssertFalse(MarkerConstants.hasMarker(title: "\(zwsp)Dashboard"))
        XCTAssertFalse(MarkerConstants.hasMarker(title: "Dashboard\(zwsp)"))
    }

    func testHasMarker_trueForEmptyMarkedTitle() {
        XCTAssertTrue(MarkerConstants.hasMarker(title: "\(zwsp)\(zwsp)"))
    }

    // MARK: - Round-trip

    func testRoundTrip_wrapThenUnwrap() {
        let titles = ["", "Dashboard", "title with spaces", "計算機 🌐"]
        for original in titles {
            let wrapped = MarkerConstants.wrap(title: original)
            let unwrapped = MarkerConstants.unwrap(title: wrapped)
            XCTAssertEqual(unwrapped, original, "round-trip failed for: '\(original)'")
        }
    }
}
