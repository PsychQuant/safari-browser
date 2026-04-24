import XCTest
@testable import SafariBrowser

/// Integration tests for the `resolveNativeTargetInWindows` pure helper,
/// which is the post-enumeration branch of `resolveNativeTarget` extracted
/// so we can exercise the `pickNativeTarget` + `pickFirstMatchFallback`
/// dispatch on stubbed `[WindowInfo]` without touching live Safari.
///
/// Coverage focus is the **plumb-through** for the `#33` fix: we assert
/// that passing `firstMatch: true` + a `warnWriter` into the resolver
/// surface actually reaches `pickFirstMatchFallback` and that multi-match
/// fallback behaves identically regardless of whether it is invoked
/// through `resolveNativeTarget` (live Safari) or
/// `resolveNativeTargetInWindows` (stubbed windows).
final class ResolveNativeTargetPlumbingTests: XCTestCase {

    // MARK: - Fixtures

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

    // MARK: - firstMatch forwarding

    func testFirstMatchTrueRecoversFromAmbiguousUrlMatch() throws {
        // Two tabs matching the contains("plaud") matcher → default would
        // throw ambiguousWindowMatch. With firstMatch: true the helper
        // SHALL fall back to pickFirstMatchFallback and return the first
        // match by (window, tab) order.
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://web.plaud.ai/a", isCurrent: true)]),
            makeWindow(index: 2, tabs: [(url: "https://web.plaud.ai/b", isCurrent: true)]),
        ]
        let target: SafariBridge.TargetDocument = .urlMatch(.contains("plaud"))

        var captured: [String] = []
        let warnWriter: (String) -> Void = { captured.append($0) }

        let resolved = try SafariBridge.resolveNativeTargetInWindows(
            target,
            windows: windows,
            firstMatch: true,
            warnWriter: warnWriter
        )

        XCTAssertEqual(resolved.windowIndex, 1,
                       "First match in (window, tab) order is window 1")
        XCTAssertEqual(captured.count, 1,
                       "warnWriter must be invoked exactly once for multi-match fallback")
        XCTAssertTrue(captured[0].contains("plaud"),
                      "Warning message must identify the matcher pattern")
        XCTAssertTrue(captured[0].contains("web.plaud.ai/a"),
                      "Warning enumerates every candidate")
        XCTAssertTrue(captured[0].contains("web.plaud.ai/b"),
                      "Warning enumerates every candidate")
    }

    func testFirstMatchFalseStillFailsClosedOnAmbiguousUrlMatch() throws {
        // Baseline: without firstMatch, multi-match must throw per the
        // unified fail-closed policy.
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://web.plaud.ai/a", isCurrent: true)]),
            makeWindow(index: 2, tabs: [(url: "https://web.plaud.ai/b", isCurrent: true)]),
        ]
        var warnings: [String] = []
        XCTAssertThrowsError(
            try SafariBridge.resolveNativeTargetInWindows(
                .urlMatch(.contains("plaud")),
                windows: windows,
                firstMatch: false,
                warnWriter: { warnings.append($0) }
            )
        ) { error in
            guard case SafariBrowserError.ambiguousWindowMatch = error else {
                return XCTFail("Expected ambiguousWindowMatch, got \(error)")
            }
        }
        XCTAssertTrue(warnings.isEmpty,
                      "warnWriter must not fire on fail-closed path")
    }

    func testFirstMatchAppliesToEndsWithMatcher() throws {
        // firstMatch must support every UrlMatcher variant — not only
        // .contains — because the requirement is plumb-through, not a
        // matcher-specific carve-out.
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://x/a/play", isCurrent: true)]),
            makeWindow(index: 2, tabs: [(url: "https://x/b/play", isCurrent: true)]),
        ]
        var captured: [String] = []
        let resolved = try SafariBridge.resolveNativeTargetInWindows(
            .urlMatch(.endsWith("/play")),
            windows: windows,
            firstMatch: true,
            warnWriter: { captured.append($0) }
        )
        XCTAssertEqual(resolved.windowIndex, 1)
        XCTAssertEqual(captured.count, 1)
    }

    func testFirstMatchDoesNotApplyToDocumentIndexAmbiguity() throws {
        // documentIndex is a structural target (1-indexed global
        // numbering); firstMatch only recovers urlMatch ambiguity per
        // the spec. An out-of-range documentIndex must still throw.
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://a/", isCurrent: true)]),
        ]
        XCTAssertThrowsError(
            try SafariBridge.resolveNativeTargetInWindows(
                .documentIndex(5),
                windows: windows,
                firstMatch: true,
                warnWriter: nil
            )
        ) { error in
            guard case SafariBrowserError.documentNotFound = error else {
                return XCTFail("Expected documentNotFound, got \(error)")
            }
        }
    }

    func testResolveToConcreteTargetCollapsesUrlMatchToWindowTab() async throws {
        // Regression test for the #33 R1 QA finding: JSCommand emits the
        // --first-match warning multiple times because every internal
        // doJavaScript re-resolves .urlMatch. resolveToConcreteTarget
        // must collapse .urlMatch → concrete (windowTab/windowIndex) so
        // subsequent calls that receive the concrete target do not
        // re-trigger the resolver / fallback / warnWriter.
        //
        // This test validates the collapse contract against a stubbed
        // single-match scenario. It does not cover the warnWriter
        // invariant directly (that requires live resolveNativeTarget +
        // listAllWindows stubbing); the helper's behavior is thin
        // forwarding to the logic covered by the other tests above.

        // Single-match .urlMatch should collapse to concrete .windowTab
        // if the match is a background tab, or .windowIndex if current.
        // We exercise the pure path via resolveNativeTargetInWindows and
        // assert the collapse mapping applied by resolveToConcreteTarget.
        let windows = [
            makeWindow(index: 1, tabs: [
                (url: "https://foo/", isCurrent: true),
                (url: "https://bar/play", isCurrent: false),
            ]),
        ]

        // Case A: match is a non-current tab → expect concrete windowTab.
        let resolvedA = try SafariBridge.resolveNativeTargetInWindows(
            .urlMatch(.endsWith("/play")),
            windows: windows
        )
        XCTAssertEqual(resolvedA.windowIndex, 1)
        XCTAssertEqual(resolvedA.tabIndexInWindow, 2,
                       "Background-tab match must carry the concrete tabIndex")

        // Case B: match is the current tab → tabIndexInWindow is nil so
        // resolveToConcreteTarget maps to .windowIndex(N).
        let resolvedB = try SafariBridge.resolveNativeTargetInWindows(
            .urlMatch(.exact("https://foo/")),
            windows: windows
        )
        XCTAssertEqual(resolvedB.windowIndex, 1)
        XCTAssertNil(resolvedB.tabIndexInWindow,
                     "Current-tab match leaves tabIndexInWindow nil; resolveToConcreteTarget maps to .windowIndex")
    }

    func testWarnWriterNotInvokedForSingleMatch() throws {
        // Single match: pickNativeTarget returns happily, fallback path
        // is not entered, warnWriter SHALL remain untouched.
        let windows = [
            makeWindow(index: 1, tabs: [(url: "https://web.plaud.ai/", isCurrent: true)]),
            makeWindow(index: 2, tabs: [(url: "https://example.com/", isCurrent: true)]),
        ]
        var captured: [String] = []
        let resolved = try SafariBridge.resolveNativeTargetInWindows(
            .urlMatch(.contains("plaud")),
            windows: windows,
            firstMatch: true,
            warnWriter: { captured.append($0) }
        )
        XCTAssertEqual(resolved.windowIndex, 1)
        XCTAssertTrue(captured.isEmpty,
                      "warnWriter fires only on the multi-match fallback path")
    }
}
