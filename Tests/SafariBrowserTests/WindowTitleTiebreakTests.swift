import XCTest
@testable import SafariBrowser

/// #91: separating Safari windows that share bounds.
///
/// Maximized windows have identical bounds, which is the normal state on a
/// multi-profile machine — so the bounds check could never separate them and
/// `screenshot --url` was structurally unavailable in exactly the sessions
/// where seeing the screen mattered. Titles do separate them, but only when
/// they actually prove something.
final class WindowTitleTiebreakTests: XCTestCase {

    func testPicksTheOneWindowCarryingTheTitle() {
        let idx = SafariBridge.uniqueTitleMatchIndex(
            titles: ["個人 — Gmail", "中研院 — Report", "個人 — Docs"],
            target: "中研院 — Report")
        XCTAssertEqual(idx, 1)
    }

    func testRefusesWhenTwoWindowsShareTheTitle() {
        // Two windows on the same page: bounds tie, titles tie. Guessing here
        // would screenshot the wrong window, which is worse than failing.
        XCTAssertNil(SafariBridge.uniqueTitleMatchIndex(
            titles: ["個人 — Gmail", "個人 — Gmail"],
            target: "個人 — Gmail"))
    }

    func testAnUnknownTitleIsNotEvidence() {
        // AppleScript could not read the title. That is an absence of
        // information, not a match against the windows that also have none.
        XCTAssertNil(SafariBridge.uniqueTitleMatchIndex(
            titles: ["", "個人 — Gmail"], target: ""))
    }

    func testBlankCandidateTitlesAreNeverMatched() {
        // Symmetric to the above: an unreadable candidate must not be selected
        // just because the target is unreadable too.
        XCTAssertNil(SafariBridge.uniqueTitleMatchIndex(
            titles: ["", ""], target: ""))
        XCTAssertNil(SafariBridge.uniqueTitleMatchIndex(
            titles: ["", "x"], target: "  "))
    }

    func testNoMatchAtAllIsRefusedRatherThanApproximated() {
        XCTAssertNil(SafariBridge.uniqueTitleMatchIndex(
            titles: ["個人 — Gmail", "中研院 — Report"],
            target: "個人 — Gm"))
    }
}
