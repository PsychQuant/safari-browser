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
        let result = try SafariBridge.pickNativeTarget(.urlMatch(.contains("plaud")), in: windows)
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
        let result = try SafariBridge.pickNativeTarget(.urlMatch(.contains("plaud")), in: windows)
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
            try SafariBridge.pickNativeTarget(.urlMatch(.contains("xyz")), in: windows)
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
            try SafariBridge.pickNativeTarget(.urlMatch(.contains("plaud")), in: windows)
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
        let result = try SafariBridge.pickNativeTarget(.urlMatch(.contains("file/b")), in: windows)
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
            try SafariBridge.pickNativeTarget(.urlMatch(.contains("plaud")), in: windows)
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

    // MARK: - Profile parsing (Issue #47)
    //
    // Records emitted by `listAllWindows` gained a 6th field for
    // window-level title (which Safari prepends with the active profile
    // name as `<profile> — <title>`). Each tab record in the same window
    // carries the same window-name field — redundant on the wire but
    // simplifies the parser (which groups records by windowIndex anyway).
    //
    // Older 4-field and 5-field records remain valid (backward compat).

    func testParseSixFieldRecordExtractsProfile() {
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        // window 1 = "個人" profile; window-name field = "個人 — Plaud Web"
        let raw = "1\(gs)1\(gs)1\(gs)https://web.plaud.ai/\(gs)Plaud Web\(gs)個人 — Plaud Web\(rs)"
        let result = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].profile, "個人")
        XCTAssertEqual(result[0].tabs[0].title, "Plaud Web")
    }

    func testParseSixFieldRecordWithoutProfileSeparator() {
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        // window-name has no em-dash → profile = nil, no error
        let raw = "1\(gs)1\(gs)1\(gs)https://a.com\(gs)A Title\(gs)A Title\(rs)"
        let result = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].profile)
    }

    func testParseFiveFieldRecordHasNilProfile() {
        // Pre-#47 5-field record (no window-name field) → profile = nil
        // (no breakage; field count tolerance preserved).
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        let raw = "1\(gs)1\(gs)1\(gs)https://a.com\(gs)A Title\(rs)"
        let result = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].profile)
    }

    func testFlattenPropagatesProfileToDocumentInfo() {
        let win = SafariBridge.WindowInfo(
            windowIndex: 1,
            currentTabIndex: 1,
            tabs: [
                SafariBridge.TabInWindow(tabIndex: 1, url: "https://a.com", title: "A", isCurrent: true),
                SafariBridge.TabInWindow(tabIndex: 2, url: "https://b.com", title: "B", isCurrent: false),
            ],
            profile: "工作"
        )
        let docs = SafariBridge.flattenWindowsToDocuments([win])
        XCTAssertEqual(docs.count, 2)
        XCTAssertEqual(docs[0].profile, "工作")
        XCTAssertEqual(docs[1].profile, "工作")
    }

    func testFlattenWindowWithoutProfileGivesNilDocumentProfile() {
        let win = SafariBridge.WindowInfo(
            windowIndex: 1,
            currentTabIndex: 1,
            tabs: [
                SafariBridge.TabInWindow(tabIndex: 1, url: "https://a.com", title: "A", isCurrent: true),
            ],
            profile: nil
        )
        let docs = SafariBridge.flattenWindowsToDocuments([win])
        XCTAssertNil(docs[0].profile)
    }

    // MARK: - pickNativeTarget profile filter (Issue #47)

    /// Helper builds a multi-window fixture across two profiles.
    private func makeProfileFixture() -> [SafariBridge.WindowInfo] {
        return [
            SafariBridge.WindowInfo(
                windowIndex: 1,
                currentTabIndex: 1,
                tabs: [SafariBridge.TabInWindow(tabIndex: 1, url: "https://a.com", title: "A", isCurrent: true)],
                profile: "個人"
            ),
            SafariBridge.WindowInfo(
                windowIndex: 2,
                currentTabIndex: 1,
                tabs: [SafariBridge.TabInWindow(tabIndex: 1, url: "https://a.com", title: "A", isCurrent: true)],
                profile: "工作"
            ),
            SafariBridge.WindowInfo(
                windowIndex: 3,
                currentTabIndex: 1,
                tabs: [SafariBridge.TabInWindow(tabIndex: 1, url: "https://b.com", title: "B", isCurrent: true)],
                profile: nil
            ),
        ]
    }

    func testProfileFilterDropsNonMatchingWindows() throws {
        // Same URL exists in 2 profiles. With profile=工作 we expect
        // only window 2 to be a candidate, so the URL match becomes
        // unambiguous and resolves to that window.
        let windows = makeProfileFixture()
        let target = SafariBridge.TargetDocument.urlMatch(.contains("a.com"))
        let result = try SafariBridge.pickNativeTarget(target, in: windows, profile: "工作")
        XCTAssertEqual(result.windowIndex, 2)
    }

    func testProfileFilterEmptyMatchThrowsHelpfulError() {
        let windows = makeProfileFixture()
        let target = SafariBridge.TargetDocument.urlMatch(.contains("a.com"))
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(target, in: windows, profile: "Nonexistent")
        ) { error in
            guard case SafariBrowserError.documentNotFound(let pattern, _) = error else {
                XCTFail("Expected documentNotFound, got \(error)")
                return
            }
            XCTAssertTrue(pattern.contains("Nonexistent"),
                          "Error pattern should mention the filter value")
            XCTAssertTrue(pattern.contains("profile"),
                          "Error pattern should mention 'profile' for clarity")
        }
    }

    func testProfileFilterNilEqualsLegacyBehavior() throws {
        // profile=nil is the default and must reproduce pre-#47 behavior:
        // multi-window URL match goes ambiguous, single-window resolves.
        let windows = [
            SafariBridge.WindowInfo(
                windowIndex: 1,
                currentTabIndex: 1,
                tabs: [SafariBridge.TabInWindow(tabIndex: 1, url: "https://a.com", title: "A", isCurrent: true)],
                profile: "X"
            ),
        ]
        let result = try SafariBridge.pickNativeTarget(.windowIndex(1), in: windows)
        XCTAssertEqual(result.windowIndex, 1)
    }

    func testProfileFilterMatchesWindowsWithNilProfile() {
        // profile filter is exact-match: filter="個人" must NOT match a
        // window with profile=nil. This is the correct semantics —
        // "individual default" and "no profile detected" are different.
        let windows = makeProfileFixture()
        // Targeting window 3 (profile: nil) with filter "個人" → empty
        // candidate set → throws documentNotFound.
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.windowIndex(1), in: [windows[2]], profile: "個人")
        )
    }

    // MARK: - Profile filter index-redirect (Issue #47, verify-found P1)
    //
    // Bug surfaced by /idd-verify #47 on PR #50: when --profile shrinks
    // the candidate window list, --window N / .frontWindow / .windowTab
    // were returning user-supplied indices LITERALLY instead of the
    // filtered candidate's actual Safari windowIndex. Result: the
    // resolved target points at Safari's actual window N (likely WRONG
    // profile), not at profile X's first/Nth window.
    //
    // These tests ensure the resolved windowIndex matches the filtered
    // candidate's `WindowInfo.windowIndex`, not the user-supplied index.

    func testProfileFilterRedirectsWindowIndexToFilteredCandidate() throws {
        // 3 windows;只有 windows[1] (Safari W2) profile=工作
        // --window 1 --profile 工作 應 resolve 到 Safari W2,
        // 不該誤回 Safari W1
        let windows = makeProfileFixture()  // [W1=個人, W2=工作, W3=nil]
        let result = try SafariBridge.pickNativeTarget(
            .windowIndex(1),
            in: windows,
            profile: "工作"
        )
        XCTAssertEqual(
            result.windowIndex, 2,
            "Filter shrunk to 1 candidate (Safari W2). --window 1 must resolve to Safari W2, not W1."
        )
    }

    func testProfileFilterRedirectsFrontWindowToFilteredCandidate() throws {
        // .frontWindow 在沒 profile 時 = windowIndex 1 (Safari front)
        // 但 profile 過濾後應指向 candidate 中的第一個
        let windows = makeProfileFixture()  // [W1=個人, W2=工作, W3=nil]
        let result = try SafariBridge.pickNativeTarget(
            .frontWindow,
            in: windows,
            profile: "工作"
        )
        XCTAssertEqual(
            result.windowIndex, 2,
            ".frontWindow under filter must point at filtered candidate's actual Safari index"
        )
    }

    func testProfileFilterRedirectsWindowTabToFilteredCandidate() throws {
        // 加 multi-tab 的 window 進去做 .windowTab 測試
        let multiTabWindows = [
            SafariBridge.WindowInfo(
                windowIndex: 5,  // Safari W5 (not 1!)
                currentTabIndex: 1,
                tabs: [
                    SafariBridge.TabInWindow(tabIndex: 7, url: "https://a", title: "A", isCurrent: true),
                    SafariBridge.TabInWindow(tabIndex: 9, url: "https://b", title: "B", isCurrent: false),
                ],
                profile: "工作"
            ),
            SafariBridge.WindowInfo(
                windowIndex: 1,  // Safari W1 = different profile
                currentTabIndex: 1,
                tabs: [SafariBridge.TabInWindow(tabIndex: 1, url: "https://c", title: "C", isCurrent: true)],
                profile: "個人"
            ),
        ]
        // --window 1 --tab-in-window 2 --profile 工作 → 應落在
        //   Safari window 5(filtered candidate 0)的 tab 9(該 window
        //   的第 2 個 tab,實際 tabIndex 是 9 不是 2)
        let result = try SafariBridge.pickNativeTarget(
            .windowTab(window: 1, tabInWindow: 2),
            in: multiTabWindows,
            profile: "工作"
        )
        XCTAssertEqual(result.windowIndex, 5, "filtered candidate's actual windowIndex, not user-supplied 1")
        XCTAssertEqual(result.tabIndexInWindow, 9, "the 2nd tab of the filtered window has actual tabIndex 9")
    }

    func testProfileFilterNilLegacyWindowIndexBitExact() throws {
        // 沒 profile 過濾時行為要跟 pre-#47 完全一致 ——
        // .windowIndex(2) 應回 windowIndex: 2(因為 windows[1].windowIndex == 2,
        // 在 fixture 裡剛好相等,但這個測試要確保 nil-profile 路徑沒被
        // 上面的 fix 不小心改到)
        let windows = makeProfileFixture()
        let result = try SafariBridge.pickNativeTarget(.windowIndex(2), in: windows)
        XCTAssertEqual(result.windowIndex, 2, "nil-profile must preserve legacy bit-exact behavior")
    }
}
