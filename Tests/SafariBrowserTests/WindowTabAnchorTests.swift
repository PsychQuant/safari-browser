import XCTest
@testable import SafariBrowser

/// #255: `--window N --tab-in-window M` used to cost a full window/tab enumeration
/// (about 0.5 s at 117 tabs) just to learn the window's stable id. One small script that
/// reads the id and the tab count is enough to anchor the target; anything it cannot
/// confirm falls back to the enumeration so every error message stays what it was.
final class WindowTabAnchorTests: XCTestCase {

    func testTheScriptReadsTheIdOnceAndTheCountThroughThatId() {
        let script = SafariBridge.tabAnchorScript(windowIndex: 3)
        XCTAssertTrue(script.contains("set _id to id of window 3"), script)
        XCTAssertTrue(script.contains("count of tabs of window id _id"),
                      "reading both through `window N` would look the window up by z-order twice (#180 R2): \(script)")
        XCTAssertFalse(script.contains("URL of"), "an anchor is not an enumeration: \(script)")
        XCTAssertFalse(script.contains("repeat"), script)
    }

    func testParseAcceptsExactlyTwoPositiveIntegers() {
        XCTAssertEqual(SafariBridge.parseTabAnchor("101\u{1D}96"),
                       SafariBridge.TabAnchor(windowID: 101, tabCount: 96))
        XCTAssertEqual(SafariBridge.parseTabAnchor("  7\u{1D}1\n"),
                       SafariBridge.TabAnchor(windowID: 7, tabCount: 1))
        for raw in ["", "101", "101\u{1D}", "\u{1D}5", "0\u{1D}5", "5\u{1D}0", "-1\u{1D}5", "a\u{1D}5", "1\u{1D}2\u{1D}3"] {
            XCTAssertNil(SafariBridge.parseTabAnchor(raw), raw.debugDescription)
        }
    }

    func testATabInsideTheWindowAnchorsToThatWindowAndTab() {
        let anchor = SafariBridge.TabAnchor(windowID: 101, tabCount: 96)
        XCTAssertEqual(SafariBridge.anchoredWindowTab(tab: 53, anchor: anchor, profile: nil),
                       .resolvedTab(windowID: 101, tabInWindow: 53, rematch: nil, profile: nil))
        XCTAssertEqual(SafariBridge.anchoredWindowTab(tab: 1, anchor: anchor, profile: nil),
                       .resolvedTab(windowID: 101, tabInWindow: 1, rematch: nil, profile: nil))
        XCTAssertEqual(SafariBridge.anchoredWindowTab(tab: 96, anchor: anchor, profile: nil),
                       .resolvedTab(windowID: 101, tabInWindow: 96, rematch: nil, profile: nil))
    }

    func testATabOutsideTheWindowOrNoAnchorStaysUnanchored() {
        let anchor = SafariBridge.TabAnchor(windowID: 101, tabCount: 96)
        XCTAssertNil(SafariBridge.anchoredWindowTab(tab: 97, anchor: anchor, profile: nil),
                     "the enumeration builds the documentNotFound listing for this; do not guess")
        XCTAssertNil(SafariBridge.anchoredWindowTab(tab: 0, anchor: anchor, profile: nil))
        XCTAssertNil(SafariBridge.anchoredWindowTab(tab: 5, anchor: nil, profile: nil))
    }
}
