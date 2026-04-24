import XCTest
@testable import SafariBrowser

/// Tests that `listAllDocuments` and `pickNativeTarget` observe the
/// same universe of Safari tabs. This is the core invariant behind the
/// `human-emulation` principle's "tab bar as ground truth" requirement
/// and directly addresses issue #28 gap #1 (`documents` and
/// `upload --native` previously disagreed on tab count).
///
/// Both sides are driven by the same `[WindowInfo]` input via the pure
/// functions `flattenWindowsToDocuments` and `pickNativeTarget`, so
/// convergence can be verified without a live Safari.
final class ResolverConvergenceTests: XCTestCase {

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

    // MARK: - Same universe: documents == native resolver view

    func testListAllDocumentsAndUrlContainsSeeSameTabCount_twoPlaudTabs() throws {
        // Front window with two tabs both containing the "plaud"
        // substring. documents should list both; urlContains should
        // ambiguity-error with both in the match list.
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/", isCurrent: true),
                (url: "https://web.plaud.ai/library", isCurrent: false),
            ]),
        ]

        let docs = SafariBridge.flattenWindowsToDocuments(windows)
        let plaudDocs = docs.filter { $0.url.contains("plaud") }
        XCTAssertEqual(plaudDocs.count, 2,
                       "documents must list both plaud tabs")

        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.urlMatch(.contains("plaud")), in: windows)
        ) { error in
            guard case SafariBrowserError.ambiguousWindowMatch(_, let matches) = error else {
                XCTFail("Expected ambiguousWindowMatch, got \(error)")
                return
            }
            XCTAssertEqual(matches.count, 2,
                           "ambiguous error must list both plaud tabs")
        }
    }

    func testDocumentIndexMatchesFlattenedOrder() throws {
        // `--document N` walks windows in spatial order; the global
        // index assigned by flattenWindowsToDocuments must match.
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://a.com", isCurrent: true),
                (url: "https://b.com", isCurrent: false),
            ]),
            makeWindow(index: 2, tabs: [
                (url: "https://c.com", isCurrent: true),
            ]),
        ]
        let docs = SafariBridge.flattenWindowsToDocuments(windows)
        XCTAssertEqual(docs.map { $0.url }, [
            "https://a.com",
            "https://b.com",
            "https://c.com",
        ])

        // `--document 3` should resolve to window 2's tab 1 (c.com).
        let result = try SafariBridge.pickNativeTarget(.documentIndex(3), in: windows)
        XCTAssertEqual(result.windowIndex, 2)
        // c.com is window 2's current tab, so no tab switch needed.
        XCTAssertNil(result.tabIndexInWindow)
    }

    // MARK: - No hidden tabs

    func testDocumentsIncludesBackgroundTabs() {
        // Per human-emulation "tab bar as ground truth": background
        // tabs (i.e. tabs within a window that are not the current
        // tab) must appear in listAllDocuments output.
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://a.com", isCurrent: false),  // background
                (url: "https://b.com", isCurrent: true),   // current
                (url: "https://c.com", isCurrent: false),  // background
            ]),
        ]
        let docs = SafariBridge.flattenWindowsToDocuments(windows)
        XCTAssertEqual(docs.count, 3,
                       "Expected all 3 tabs (2 background + 1 current)")
        XCTAssertEqual(Set(docs.map { $0.url }), [
            "https://a.com", "https://b.com", "https://c.com",
        ])
    }

    func testFlattenPreservesWindowTabCoordinates() {
        // Each DocumentInfo must carry (window, tabInWindow) that
        // round-trips: feeding them back into pickNativeTarget as
        // windowIndex + documentIndex pair should resolve to the same
        // tab.
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://a.com", isCurrent: true),
            ]),
            makeWindow(index: 2, tabs: [
                (url: "https://b.com", isCurrent: false),
                (url: "https://c.com", isCurrent: true),
            ]),
        ]
        let docs = SafariBridge.flattenWindowsToDocuments(windows)
        // docs[1] = (window 2, tab 1, b.com) background
        XCTAssertEqual(docs[1].window, 2)
        XCTAssertEqual(docs[1].tabInWindow, 1)
        XCTAssertEqual(docs[1].isCurrent, false)
        XCTAssertEqual(docs[1].url, "https://b.com")
    }

    // MARK: - Empty / edge cases

    func testEmptyWindowsProducesNoDocuments() {
        XCTAssertEqual(SafariBridge.flattenWindowsToDocuments([]).count, 0)
    }

    func testGlobalIndexIsOneBasedAndContiguous() {
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://a", isCurrent: true)]),
            makeWindow(index: 2, tabs: [
                (url: "https://b", isCurrent: false),
                (url: "https://c", isCurrent: true),
            ]),
        ]
        let docs = SafariBridge.flattenWindowsToDocuments(windows)
        XCTAssertEqual(docs.map { $0.index }, [1, 2, 3])
    }

    // MARK: - findExactMatch (Group 8: Open URL focus-existing default)

    func testFindExactMatchLocatesMatchingTab() {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://a.com", isCurrent: true),
                (url: "https://web.plaud.ai/", isCurrent: false),
            ]),
        ]
        let match = SafariBridge.findExactMatch(url: "https://web.plaud.ai/", in: windows)
        XCTAssertEqual(match?.window, 1)
        XCTAssertEqual(match?.tabInWindow, 2)
        XCTAssertEqual(match?.isCurrent, false)
    }

    func testFindExactMatchRequiresExactURLNotSubstring() {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/library", isCurrent: true),
            ]),
        ]
        // Substring match of "plaud" must not trigger — focus-existing
        // should only activate on exact URL equality to avoid
        // accidentally revealing unrelated pages on the same domain.
        let match = SafariBridge.findExactMatch(url: "https://web.plaud.ai/", in: windows)
        XCTAssertNil(match, "Substring should not be treated as exact match")
    }

    func testFindExactMatchReturnsNilWhenNoMatch() {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://a.com", isCurrent: true),
            ]),
        ]
        XCTAssertNil(SafariBridge.findExactMatch(url: "https://b.com", in: windows))
    }

    func testFindExactMatchAcrossWindowsPrefersLowerWindow() {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://example.com/", isCurrent: true),
            ]),
            makeWindow(index: 2, tabs: [
                (url: "https://example.com/", isCurrent: true),
            ]),
        ]
        // When two windows contain the same URL, enumeration order
        // (window 1 first) determines which is returned — gives
        // focus-existing a deterministic pick, matching first-match
        // ordering used elsewhere in the resolver.
        let match = SafariBridge.findExactMatch(url: "https://example.com/", in: windows)
        XCTAssertEqual(match?.window, 1)
    }

    func testFindExactMatchDetectsCurrentTabMarker() {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://a.com", isCurrent: false),
                (url: "https://web.plaud.ai/", isCurrent: true),
            ]),
        ]
        let match = SafariBridge.findExactMatch(url: "https://web.plaud.ai/", in: windows)
        XCTAssertEqual(match?.isCurrent, true,
                       "Current-tab flag must be preserved so focusExistingTab can short-circuit Layer 1")
    }

    // MARK: - docRefFromResolved (Group 7: Unified urlContains fail-closed)

    func testDocRefFromResolvedWithTabIndexProducesTabOfWindow() {
        let resolved = SafariBridge.ResolvedWindowTarget(windowIndex: 2, tabIndexInWindow: 3)
        XCTAssertEqual(
            SafariBridge.docRefFromResolved(resolved),
            "tab 3 of window 2",
            "Background tab must resolve to explicit `tab T of window N` — the JS-path dispatch uses this reference instead of the silent-first-match AppleScript expression"
        )
    }

    func testDocRefFromResolvedCurrentTabProducesDocumentOfWindow() {
        let resolved = SafariBridge.ResolvedWindowTarget(windowIndex: 1, tabIndexInWindow: nil)
        XCTAssertEqual(
            SafariBridge.docRefFromResolved(resolved),
            "document of window 1",
            "Current-tab target (no switch) uses the document-of-window form"
        )
    }

    // MARK: - parseWindowEnumeration title round-trip

    func testParseWindowEnumerationIncludesTitle() {
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        // 5-field record: window GS tab GS isCurrent GS url GS title RS
        let raw = "1\(gs)1\(gs)1\(gs)https://a.com\(gs)Alpha Page\(rs)"
            + "1\(gs)2\(gs)0\(gs)https://b.com\(gs)Beta Page\(rs)"
        let windows = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].tabs.count, 2)
        XCTAssertEqual(windows[0].tabs[0].title, "Alpha Page")
        XCTAssertEqual(windows[0].tabs[1].title, "Beta Page")
    }

    func testParseWindowEnumerationLegacy4FieldFallback() {
        // Legacy 4-field records (pre-title) must still parse,
        // producing empty title — supports graceful mid-deploy state
        // where the AppleScript may not yet emit titles.
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        let raw = "1\(gs)1\(gs)1\(gs)https://a.com\(rs)"
        let windows = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].tabs[0].title, "")
        XCTAssertEqual(windows[0].tabs[0].url, "https://a.com")
    }
}
