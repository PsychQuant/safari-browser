import XCTest
@testable import SafariBrowser

/// Tests for the --first-match opt-in behavior exposed through
/// `SafariBridge.pickFirstMatchFallback`. Covers:
/// - Deterministic selection order (lower window → lower tab-in-window)
/// - Warning emission enumerates every match and identifies the chosen one
/// - No warning when there's only a single match (no ambiguity happened)
/// - Zero-match still throws documentNotFound
final class FirstMatchTests: XCTestCase {

    private func makeWindow(
        index: Int,
        tabs: [(url: String, isCurrent: Bool)]
    ) -> SafariBridge.WindowInfo {
        let tabInfos = tabs.enumerated().map { (i, t) in
            SafariBridge.TabInWindow(
                tabIndex: i + 1,
                url: t.url,
                title: "",
                isCurrent: t.isCurrent
            )
        }
        let currentIdx = tabs.firstIndex(where: { $0.isCurrent }).map { $0 + 1 } ?? 1
        return SafariBridge.WindowInfo(
            windowIndex: index,
            currentTabIndex: currentIdx,
            tabs: tabInfos
        )
    }

    // MARK: - Deterministic ordering

    func testFirstMatchPrefersLowerWindowIndex() throws {
        // Two windows both contain a "plaud" tab. First-match must pick
        // the one in the lower-index window.
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://web.plaud.ai/a", isCurrent: true)]),
            makeWindow(index: 2, tabs: [(url: "https://web.plaud.ai/b", isCurrent: true)]),
        ]
        let result = try SafariBridge.pickFirstMatchFallback(
            pattern: "plaud",
            in: windows
        )
        XCTAssertEqual(result.windowIndex, 1)
    }

    func testFirstMatchPrefersLowerTabWithinSameWindow() throws {
        // Same window, two plaud tabs at positions 1 and 2.
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/", isCurrent: false),  // tab 1 background
                (url: "https://web.plaud.ai/", isCurrent: true),   // tab 2 current
            ]),
        ]
        let result = try SafariBridge.pickFirstMatchFallback(
            pattern: "plaud",
            in: windows
        )
        XCTAssertEqual(result.windowIndex, 1)
        XCTAssertEqual(result.tabIndexInWindow, 1,
                       "Background tab 1 comes before current tab 2 in enumeration order")
    }

    // MARK: - Warning emission

    func testFirstMatchWarningEnumeratesAllMatches() throws {
        var captured: [String] = []
        let warnWriter: (String) -> Void = { captured.append($0) }

        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/library", isCurrent: true),
                (url: "https://web.plaud.ai/record", isCurrent: false),
            ]),
        ]
        _ = try SafariBridge.pickFirstMatchFallback(
            pattern: "plaud",
            in: windows,
            warnWriter: warnWriter
        )

        XCTAssertEqual(captured.count, 1, "One warning emitted for ambiguous match")
        let msg = captured[0]
        XCTAssertTrue(msg.contains("plaud"),
                      "Warning mentions the pattern")
        XCTAssertTrue(msg.contains("library"),
                      "Warning enumerates first match URL")
        XCTAssertTrue(msg.contains("record"),
                      "Warning enumerates second match URL")
        XCTAssertTrue(msg.contains("window 1 tab 1"),
                      "Warning identifies which tab was chosen")
    }

    func testFirstMatchSingleMatchEmitsNoWarning() throws {
        var captured: [String] = []
        let warnWriter: (String) -> Void = { captured.append($0) }

        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/", isCurrent: true),
                (url: "https://example.com/", isCurrent: false),
            ]),
        ]
        let result = try SafariBridge.pickFirstMatchFallback(
            pattern: "plaud",
            in: windows,
            warnWriter: warnWriter
        )

        XCTAssertEqual(result.windowIndex, 1)
        XCTAssertTrue(captured.isEmpty,
                      "No warning should fire when only one match exists — no real ambiguity")
    }

    // MARK: - Error paths

    func testFirstMatchZeroMatchThrowsDocumentNotFound() {
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://example.com/", isCurrent: true)]),
        ]
        XCTAssertThrowsError(
            try SafariBridge.pickFirstMatchFallback(pattern: "missing", in: windows)
        ) { error in
            guard case SafariBrowserError.documentNotFound = error else {
                XCTFail("Expected documentNotFound, got \(error)")
                return
            }
        }
    }

    func testFirstMatchOnCurrentTabDoesNotRequestSwitch() throws {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/", isCurrent: true),  // current, single match
            ]),
        ]
        let result = try SafariBridge.pickFirstMatchFallback(
            pattern: "plaud",
            in: windows
        )
        XCTAssertEqual(result.windowIndex, 1)
        XCTAssertNil(result.tabIndexInWindow,
                     "Current tab target must not request a tab switch")
    }

    func testFirstMatchBackgroundTabRequestsSwitch() throws {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://example.com/", isCurrent: true),
                (url: "https://web.plaud.ai/", isCurrent: false),
            ]),
        ]
        let result = try SafariBridge.pickFirstMatchFallback(
            pattern: "plaud",
            in: windows
        )
        XCTAssertEqual(result.windowIndex, 1)
        XCTAssertEqual(result.tabIndexInWindow, 2,
                       "Background match must carry tab-switch index")
    }
}
