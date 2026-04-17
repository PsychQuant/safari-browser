import XCTest
@testable import SafariBrowser

/// Pure unit tests for the native-path window resolver. All cases
/// operate on pre-constructed `WindowInfo` fixtures, so none of these
/// tests require a live Safari — they cover the full decision tree of
/// `SafariBridge.pickNativeTarget` plus the single-roundtrip parser
/// `parseWindowEnumeration`.
///
/// Integration coverage (actual Safari enumeration, AppleScript
/// roundtrips, tab-switch side effects) lives in the manual verification
/// task 10.1 because spinning up a Safari instance in CI is out of scope.
final class WindowIndexResolverTests: XCTestCase {

    // MARK: - Fixture helpers

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

    // MARK: - .windowTab (composite target — issue #28 gap #2)

    func testPickWindowTabResolvesCompositeTarget() throws {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://a.com", isCurrent: true),
                (url: "https://b.com", isCurrent: false),
            ]),
        ]
        // Target tab 2 of window 1 (background).
        let result = try SafariBridge.pickNativeTarget(
            .windowTab(window: 1, tabInWindow: 2),
            in: windows
        )
        XCTAssertEqual(result.windowIndex, 1)
        XCTAssertEqual(result.tabIndexInWindow, 2,
                       "Background tab target must carry tab-switch index")
    }

    func testPickWindowTabCurrentTabOmitsSwitch() throws {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://a.com", isCurrent: false),
                (url: "https://b.com", isCurrent: true),
            ]),
        ]
        // Target the current tab — no switch needed.
        let result = try SafariBridge.pickNativeTarget(
            .windowTab(window: 1, tabInWindow: 2),
            in: windows
        )
        XCTAssertEqual(result.windowIndex, 1)
        XCTAssertNil(result.tabIndexInWindow,
                     "Current-tab target must not request a tab switch")
    }

    func testPickWindowTabSameURLDuplicateDisambiguation() throws {
        // Issue #28 gap #2 scenario — two tabs share an identical URL.
        // --url cannot disambiguate them; --window + --tab-in-window
        // addresses each individually.
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/", isCurrent: true),
                (url: "https://web.plaud.ai/", isCurrent: false),
            ]),
        ]
        // Target the second plaud tab specifically.
        let result = try SafariBridge.pickNativeTarget(
            .windowTab(window: 1, tabInWindow: 2),
            in: windows
        )
        XCTAssertEqual(result.windowIndex, 1)
        XCTAssertEqual(result.tabIndexInWindow, 2)
    }

    func testPickWindowTabWindowOutOfRangeThrows() {
        let windows = [makeWindow(index: 1, tabs: [(url: "https://a.com", isCurrent: true)])]
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(
                .windowTab(window: 99, tabInWindow: 1),
                in: windows
            )
        ) { error in
            guard case SafariBrowserError.documentNotFound = error else {
                XCTFail("Expected documentNotFound for window out of range, got \(error)")
                return
            }
        }
    }

    func testPickWindowTabTabOutOfRangeThrows() {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://a.com", isCurrent: true),
            ]),
        ]
        // Window exists but tab 5 does not.
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(
                .windowTab(window: 1, tabInWindow: 5),
                in: windows
            )
        ) { error in
            guard case SafariBrowserError.documentNotFound = error else {
                XCTFail("Expected documentNotFound for tab out of range, got \(error)")
                return
            }
        }
    }

    func testPickWindowTabZeroWindowRejected() {
        let windows = [makeWindow(index: 1, tabs: [(url: "https://a.com", isCurrent: true)])]
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(
                .windowTab(window: 0, tabInWindow: 1),
                in: windows
            )
        )
    }

    func testPickWindowTabZeroTabRejected() {
        let windows = [makeWindow(index: 1, tabs: [(url: "https://a.com", isCurrent: true)])]
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(
                .windowTab(window: 1, tabInWindow: 0),
                in: windows
            )
        )
    }

    // MARK: - .frontWindow (short-circuit, no enumeration needed)

    func testPickFrontWindowReturnsWindowOneNoTabSwitch() throws {
        // Even with an empty enumeration, .frontWindow must succeed —
        // it's the fast path that skips AppleScript entirely. The
        // resolver is total over TargetDocument, so an unreachable
        // branch should still behave sensibly.
        let result = try SafariBridge.pickNativeTarget(.frontWindow, in: [])
        XCTAssertEqual(result.windowIndex, 1)
        XCTAssertNil(result.tabIndexInWindow,
                     "frontWindow never requests a tab switch")
    }

    // MARK: - .windowIndex

    func testPickWindowIndexReturnsThatWindow() throws {
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://a.com", isCurrent: true)]),
            makeWindow(index: 2, tabs: [(url: "https://b.com", isCurrent: true)]),
        ]
        let result = try SafariBridge.pickNativeTarget(.windowIndex(2), in: windows)
        XCTAssertEqual(result.windowIndex, 2)
        XCTAssertNil(result.tabIndexInWindow,
                     "--window N targets the window, not a specific tab — no switch")
    }

    func testPickWindowIndexOutOfRangeThrowsDocumentNotFound() {
        let windows = [makeWindow(index: 1, tabs: [(url: "https://a.com", isCurrent: true)])]
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.windowIndex(99), in: windows)
        ) { error in
            guard case SafariBrowserError.documentNotFound = error else {
                XCTFail("Expected documentNotFound, got \(error)")
                return
            }
        }
    }

    func testPickWindowIndexZeroThrowsDocumentNotFound() {
        // Guard against 0-indexed input sneaking through validate().
        // AppleScript would return a misleading error for window 0,
        // so the resolver must reject it up front.
        let windows = [makeWindow(index: 1, tabs: [(url: "https://a.com", isCurrent: true)])]
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.windowIndex(0), in: windows)
        )
    }

    // MARK: - .urlContains (single match — happy path)

    func testPickUrlContainsSingleMatchCurrentTab() throws {
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://github.com", isCurrent: true)]),
            makeWindow(index: 2, tabs: [(url: "https://web.plaud.ai/file/a", isCurrent: true)]),
        ]
        let result = try SafariBridge.pickNativeTarget(.urlContains("plaud"), in: windows)
        XCTAssertEqual(result.windowIndex, 2)
        XCTAssertNil(result.tabIndexInWindow,
                     "Match is already the current tab, no switch needed")
    }

    func testPickUrlContainsSingleMatchBackgroundTab() throws {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://github.com", isCurrent: true),
                (url: "https://web.plaud.ai/file/a", isCurrent: false),
            ]),
        ]
        let result = try SafariBridge.pickNativeTarget(.urlContains("plaud"), in: windows)
        XCTAssertEqual(result.windowIndex, 1)
        XCTAssertEqual(result.tabIndexInWindow, 2,
                       "Match is a background tab — tabIndexInWindow signals switch needed")
    }

    // MARK: - .urlContains (zero matches → documentNotFound)

    func testPickUrlContainsNoMatchThrowsDocumentNotFound() {
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://github.com", isCurrent: true)]),
        ]
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.urlContains("xyz"), in: windows)
        ) { error in
            guard case let SafariBrowserError.documentNotFound(pattern, availableDocuments) = error else {
                XCTFail("Expected documentNotFound, got \(error)")
                return
            }
            XCTAssertEqual(pattern, "xyz")
            // Discoverability: the error must include the URL the user
            // was probably looking for so they can fix their input.
            XCTAssertTrue(availableDocuments.contains(where: { $0.contains("github.com") }))
        }
    }

    // MARK: - .urlContains (multi-match → ambiguousWindowMatch, fail-closed)

    func testPickUrlContainsMultipleMatchesThrowsAmbiguous() {
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://web.plaud.ai/file/a", isCurrent: true)]),
            makeWindow(index: 3, tabs: [(url: "https://web.plaud.ai/file/b", isCurrent: true)]),
        ]
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.urlContains("plaud"), in: windows)
        ) { error in
            guard case let SafariBrowserError.ambiguousWindowMatch(pattern, matches) = error else {
                XCTFail("Expected ambiguousWindowMatch, got \(error)")
                return
            }
            XCTAssertEqual(pattern, "plaud")
            XCTAssertEqual(matches.count, 2)
            XCTAssertTrue(matches.contains(where: { $0.windowIndex == 1 && $0.url == "https://web.plaud.ai/file/a" }))
            XCTAssertTrue(matches.contains(where: { $0.windowIndex == 3 && $0.url == "https://web.plaud.ai/file/b" }))
        }
    }

    func testPickUrlContainsMoreSpecificSubstringDisambiguates() throws {
        // This is the escape hatch for users hit by ambiguity — adding
        // more of the URL path resolves to a single match.
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://web.plaud.ai/file/a", isCurrent: true)]),
            makeWindow(index: 3, tabs: [(url: "https://web.plaud.ai/file/b", isCurrent: true)]),
        ]
        let result = try SafariBridge.pickNativeTarget(.urlContains("file/b"), in: windows)
        XCTAssertEqual(result.windowIndex, 3)
    }

    func testPickUrlContainsSameWindowMultipleMatchesThrowsAmbiguous() {
        // Edge case: two tabs in a single window both match. Even
        // though the window is uniquely identified, the target tab is
        // not, so we fail-closed rather than silently picking one.
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/file/a", isCurrent: true),
                (url: "https://web.plaud.ai/file/b", isCurrent: false),
            ]),
        ]
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.urlContains("plaud"), in: windows)
        ) { error in
            guard case let SafariBrowserError.ambiguousWindowMatch(_, matches) = error else {
                XCTFail("Expected ambiguousWindowMatch, got \(error)")
                return
            }
            XCTAssertEqual(matches.count, 2)
        }
    }

    // MARK: - .documentIndex (flat index → (window, tab) mapping)

    func testPickDocumentIndexMapsToOwningWindow() throws {
        // Window 1 has 2 tabs, window 2 has 1 tab — 3 documents total.
        //   document 1 → window 1, tab 1 (current, no switch)
        //   document 2 → window 1, tab 2 (background, switch needed)
        //   document 3 → window 2, tab 1 (current, no switch)
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://a.com", isCurrent: true),
                (url: "https://b.com", isCurrent: false),
            ]),
            makeWindow(index: 2, tabs: [(url: "https://c.com", isCurrent: true)]),
        ]

        let r1 = try SafariBridge.pickNativeTarget(.documentIndex(1), in: windows)
        XCTAssertEqual(r1.windowIndex, 1)
        XCTAssertNil(r1.tabIndexInWindow, "document 1 is current tab of window 1")

        let r2 = try SafariBridge.pickNativeTarget(.documentIndex(2), in: windows)
        XCTAssertEqual(r2.windowIndex, 1)
        XCTAssertEqual(r2.tabIndexInWindow, 2, "document 2 is background tab of window 1")

        let r3 = try SafariBridge.pickNativeTarget(.documentIndex(3), in: windows)
        XCTAssertEqual(r3.windowIndex, 2)
        XCTAssertNil(r3.tabIndexInWindow, "document 3 is current tab of window 2")
    }

    func testPickDocumentIndexOutOfRangeThrowsDocumentNotFound() {
        let windows = [makeWindow(index: 1, tabs: [(url: "https://a.com", isCurrent: true)])]
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.documentIndex(99), in: windows)
        ) { error in
            guard case SafariBrowserError.documentNotFound = error else {
                XCTFail("Expected documentNotFound, got \(error)")
                return
            }
        }
    }

    /// #26 verify P1-1: `.documentIndex(0)` used to trap on
    /// `window.tabs[-1]` because the for-loop's `remaining <= count`
    /// check was trivially true for `remaining = 0`. CLI is guarded by
    /// `TargetOptions.validate()` (>= 1), but `pickNativeTarget` is a
    /// public pure function that tests and future callers can invoke
    /// directly — so the crash was reachable. The fix adds a `n < 1`
    /// guard that throws `documentNotFound` cleanly.
    func testPickDocumentIndexZeroThrowsDocumentNotFound() {
        let windows = [makeWindow(index: 1, tabs: [(url: "https://a.com", isCurrent: true)])]
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.documentIndex(0), in: windows)
        ) { error in
            guard case SafariBrowserError.documentNotFound = error else {
                XCTFail("Expected documentNotFound, got \(error)")
                return
            }
        }
    }

    func testPickDocumentIndexNegativeThrowsDocumentNotFound() {
        let windows = [makeWindow(index: 1, tabs: [(url: "https://a.com", isCurrent: true)])]
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.documentIndex(-5), in: windows)
        ) { error in
            guard case SafariBrowserError.documentNotFound = error else {
                XCTFail("Expected documentNotFound, got \(error)")
                return
            }
        }
    }

    // MARK: - Parser unit tests

    func testParseEmptyEnumeration() {
        XCTAssertTrue(SafariBridge.parseWindowEnumeration("").isEmpty)
    }

    func testParseSingleWindowSingleTab() {
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        let raw = "1\(gs)1\(gs)1\(gs)https://a.com\(rs)"
        let result = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].windowIndex, 1)
        XCTAssertEqual(result[0].tabs.count, 1)
        XCTAssertEqual(result[0].tabs[0].url, "https://a.com")
        XCTAssertTrue(result[0].tabs[0].isCurrent)
        XCTAssertEqual(result[0].currentTabIndex, 1)
    }

    func testParseMultipleWindowsMultipleTabs() {
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        let raw = [
            "1\(gs)1\(gs)1\(gs)https://a.com",
            "1\(gs)2\(gs)0\(gs)https://b.com",
            "2\(gs)1\(gs)1\(gs)https://c.com",
        ].joined(separator: rs) + rs
        let result = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].windowIndex, 1)
        XCTAssertEqual(result[0].tabs.count, 2)
        XCTAssertEqual(result[0].currentTabIndex, 1)
        XCTAssertEqual(result[0].tabs[0].isCurrent, true)
        XCTAssertEqual(result[0].tabs[1].isCurrent, false)
        XCTAssertEqual(result[1].windowIndex, 2)
        XCTAssertEqual(result[1].tabs.count, 1)
    }

    // MARK: - performTabSwitchIfNeeded no-op path

    func testPerformTabSwitchIfNeededWithNilTabIsNoOp() async {
        // When `tab` is nil, the helper must return immediately without
        // running any AppleScript. We prove this by passing a window
        // index that would be garbage (99) for any typical Safari setup —
        // if the AppleScript ran, it would error. A successful return
        // confirms the nil-guard short-circuited before reaching Safari.
        do {
            try await SafariBridge.performTabSwitchIfNeeded(window: 99, tab: nil)
        } catch {
            XCTFail("Expected no-op for nil tab, got error: \(error)")
        }
    }

    // MARK: - Resolver stateless contract

    func testResolverIsStatelessAcrossPureCalls() throws {
        // The stateless contract (#26 design decision: Stateless
        // resolver — no cache) means two consecutive calls to
        // `pickNativeTarget` with the same arguments return equal
        // results AND mutation of the second call's window list does
        // not affect the first call's result. This also asserts that
        // results are value types (ResolvedWindowTarget: Equatable)
        // rather than references that could leak across calls.
        let windowsA = [
            makeWindow(index: 1, tabs: [(url: "https://a.com", isCurrent: true)]),
        ]
        let resultA = try SafariBridge.pickNativeTarget(.windowIndex(1), in: windowsA)

        let windowsB = [
            makeWindow(index: 1, tabs: [(url: "https://b.com", isCurrent: true)]),
            makeWindow(index: 2, tabs: [(url: "https://c.com", isCurrent: true)]),
        ]
        let resultB = try SafariBridge.pickNativeTarget(.windowIndex(2), in: windowsB)

        XCTAssertEqual(resultA, SafariBridge.ResolvedWindowTarget(windowIndex: 1, tabIndexInWindow: nil))
        XCTAssertEqual(resultB, SafariBridge.ResolvedWindowTarget(windowIndex: 2, tabIndexInWindow: nil))
        XCTAssertNotEqual(resultA, resultB)
    }

    func testParseDroppsMalformedRecords() {
        // Records with wrong field count (not 4) are silently skipped.
        // This is defensive — a well-formed AppleScript loop should
        // never emit malformed records, but a transient Safari state
        // glitch shouldn't crash the parser.
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        let raw = "1\(gs)bogus\(rs)" + "1\(gs)1\(gs)1\(gs)https://a.com\(rs)"
        let result = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].tabs.count, 1)
    }
}
