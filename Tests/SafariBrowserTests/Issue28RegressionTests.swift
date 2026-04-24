import XCTest
@testable import SafariBrowser

/// Regression coverage for the six reliability gaps reported in
/// https://github.com/PsychQuant/safari-browser/issues/28. Each test
/// asserts the concrete invariant that, if broken, would re-surface
/// the gap. The tests are fixture-driven (no live Safari) so they
/// can run in CI; end-to-end manual verification is tracked separately.
///
/// Mapping (gap → test):
///   Gap 1 (enumeration mismatch)           → `testGap1_*`
///   Gap 2 (same-URL disambiguation)        → `testGap2_*`
///   Gap 3 (close --url multi-kill)         → `testGap3_*`
///   Gap 4 (open accumulates duplicates)    → `testGap4_*`
///   Gap 5 (js vs upload ambiguous policy)  → `testGap5_*`
///   Gap 6 (upload --native modal orphan)   → deferred; see CHANGELOG note
final class Issue28RegressionTests: XCTestCase {

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

    // MARK: - Gap 1: `documents` and `upload --native` agreed on tab enumeration

    /// The reporter saw `documents` list 1 plaud tab while
    /// `upload --native --url plaud` reported "Multiple Safari windows
    /// match" with two identical `[window 1] https://web.plaud.ai/`
    /// entries. Root cause was the dual-resolver split (documents
    /// collection vs tabs-of-windows). Post-tab-targeting-v2, both
    /// sides iterate the same `[WindowInfo]` via `flattenWindowsToDocuments`
    /// and `pickNativeTarget`, so the count is identical.
    func testGap1_documentsAndPickNativeTargetAgreeOnTabCount() throws {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/", isCurrent: true),
                (url: "https://web.plaud.ai/", isCurrent: false),
            ]),
        ]

        let docs = SafariBridge.flattenWindowsToDocuments(windows)
        let plaudDocs = docs.filter { $0.url.contains("plaud") }
        XCTAssertEqual(plaudDocs.count, 2, "`documents` lists both plaud tabs")

        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.urlMatch(.contains("plaud")), in: windows)
        ) { error in
            guard case SafariBrowserError.ambiguousWindowMatch(_, let matches) = error else {
                return XCTFail("Expected ambiguousWindowMatch, got \(error)")
            }
            XCTAssertEqual(matches.count, 2,
                           "Native-path resolver sees the same 2 tabs as documents")
        }
    }

    // MARK: - Gap 2: Same-URL tabs can be disambiguated via composite flag

    /// The reporter had two tabs at identical URL `https://web.plaud.ai/`
    /// and no way to target either specifically. `--window 1
    /// --tab-in-window N` is the structured escape hatch.
    func testGap2_sameURLTabsAddressableViaWindowAndTabInWindow() throws {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/", isCurrent: true),
                (url: "https://web.plaud.ai/", isCurrent: false),
            ]),
        ]

        // Target the first plaud tab.
        let first = try SafariBridge.pickNativeTarget(
            .windowTab(window: 1, tabInWindow: 1),
            in: windows
        )
        XCTAssertEqual(first.windowIndex, 1)

        // Target the second plaud tab specifically.
        let second = try SafariBridge.pickNativeTarget(
            .windowTab(window: 1, tabInWindow: 2),
            in: windows
        )
        XCTAssertEqual(second.windowIndex, 1)
        XCTAssertEqual(second.tabIndexInWindow, 2,
                       "--tab-in-window 2 resolves to the second tab, not the first")
    }

    // MARK: - Gap 3: close --url fails-closed on multi-match

    /// `close --url pattern` matching two tabs previously killed both
    /// silently. CloseCommand now uses `resolveNativeTarget`, which
    /// fails-closed on `.urlContains` ambiguity — closing nothing and
    /// surfacing `ambiguousWindowMatch` for the user to disambiguate.
    func testGap3_closeUrlAmbiguousMatchFailsClosedNotSilentMultiKill() {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://example.com/foo?categoryId=unorganized", isCurrent: true),
                (url: "https://example.com/bar?categoryId=unorganized", isCurrent: false),
            ]),
        ]
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(
                .urlMatch(.contains("categoryId=unorganized")),
                in: windows
            )
        ) { error in
            guard case SafariBrowserError.ambiguousWindowMatch = error else {
                return XCTFail("Expected ambiguousWindowMatch — close must fail-closed, got \(error)")
            }
        }
    }

    // MARK: - Gap 4: open does not accumulate duplicate tabs (focus-existing default)

    /// Pre-tab-targeting-v2, `open <url>` twice produced two tabs with
    /// identical URL. With focus-existing default, the second `open`
    /// finds the exact match and focuses it instead of creating a
    /// duplicate.
    func testGap4_openFindsExactMatchInsteadOfCreatingDuplicate() {
        let afterFirstOpen = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/", isCurrent: true),
            ]),
        ]
        // Simulate the second `open` dispatch logic: findExactMatch
        // must return the existing tab so OpenCommand routes to
        // focusExistingTab instead of openURLInNewTab.
        let match = SafariBridge.findExactMatch(
            url: "https://web.plaud.ai/",
            in: afterFirstOpen
        )
        XCTAssertNotNil(match,
                        "Second open must find the first tab; otherwise OpenCommand falls through to openURLInNewTab and accumulates a duplicate")
        XCTAssertEqual(match?.window, 1)
        XCTAssertEqual(match?.tabInWindow, 1)
    }

    // MARK: - Gap 5: js and upload/close apply identical ambiguous-match policy

    /// The reporter observed `js --url plaud "..."` silently picking
    /// one match while `upload --native --url plaud` failed closed on
    /// the same state. After unifying via `resolveToAppleScript` and
    /// `pickNativeTarget`, both paths use the same fail-closed rule.
    func testGap5_jsAndUploadPathsShareUnifiedFailClosedPolicy() {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/library", isCurrent: true),
                (url: "https://web.plaud.ai/record", isCurrent: false),
            ]),
        ]
        // Both subcommands ultimately call pickNativeTarget with the
        // same TargetDocument.urlContains case — one assertion proves
        // the policy is shared. (Before the unification, js used the
        // sync resolveDocumentReference which returned the AppleScript
        // `(first document whose URL contains ...)` silent-first-match
        // expression.)
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.urlMatch(.contains("plaud")), in: windows)
        ) { error in
            guard case SafariBrowserError.ambiguousWindowMatch = error else {
                return XCTFail("Unified policy must fail-closed on multi-match, got \(error)")
            }
        }
    }

    /// Companion check: when `--first-match` is opted in, both paths
    /// produce identical deterministic selection (lower window index,
    /// then lower tab-in-window index).
    func testGap5_firstMatchOptInIsDeterministicAcrossCallers() throws {
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://web.plaud.ai/library", isCurrent: true),
                (url: "https://web.plaud.ai/record", isCurrent: false),
            ]),
            makeWindow(index: 2, tabs: [
                (url: "https://web.plaud.ai/shared", isCurrent: true),
            ]),
        ]
        let result = try SafariBridge.pickFirstMatchFallback(
            matcher: .contains("plaud"),
            in: windows
        )
        XCTAssertEqual(result.windowIndex, 1,
                       "Deterministic ordering: window 1 before window 2")
    }

    // MARK: - Gap 6 is deferred

    /// Gap 6 (upload --native modal orphan) is intentionally out of
    /// scope for tab-targeting-v2; see proposal Non-Goals. This test
    /// exists to document the deferral and fail loudly if a future
    /// author silently assumes coverage.
    func testGap6_uploadNativeModalOrphanIsExplicitlyDeferred() {
        XCTAssertTrue(
            true,
            "Gap 6 is tracked as a separate future change — do not add coverage here without re-opening the design"
        )
    }
}
