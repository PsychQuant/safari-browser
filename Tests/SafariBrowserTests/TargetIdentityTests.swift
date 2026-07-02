import XCTest

@testable import SafariBrowser

/// #79: identity-anchored target resolution.
///
/// AppleScript's `window N` is a z-order index — it dangles the moment the
/// user clicks another Safari window, sending later round-trips of a
/// multi-round-trip command to whatever tab now sits at that position
/// (cross-tab JS injection, silent wrong results). These tests pin the fix:
/// window-id anchoring (`tab T of window id W`), the in-script URL guard,
/// and the bounded re-resolve retry decision logic.
final class TargetIdentityTests: XCTestCase {

    private let gs = "\u{1D}"
    private let rs = "\u{1E}"

    // MARK: - S1: enumeration carries the stable window id

    func testParseWindowEnumeration7FieldCarriesWindowID() {
        // 7-field record: window GS tab GS isCurrent GS url GS title GS winName GS winID RS
        let raw = "1\(gs)1\(gs)1\(gs)https://a.com\(gs)Alpha\(gs)個人 — Alpha\(gs)22510\(rs)"
            + "1\(gs)2\(gs)0\(gs)https://b.com\(gs)Beta\(gs)個人 — Alpha\(gs)22510\(rs)"
            + "2\(gs)1\(gs)1\(gs)https://c.com\(gs)Gamma\(gs)work — Gamma\(gs)30691\(rs)"
        let windows = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].windowID, 22510)
        XCTAssertEqual(windows[1].windowID, 30691)
        // Existing fields keep working alongside the new one.
        XCTAssertEqual(windows[0].profile, "個人")
        XCTAssertEqual(windows[0].tabs.count, 2)
    }

    func testParseWindowEnumerationLegacy6FieldWindowIDNil() {
        // Pre-#79 6-field records (no window id) must still parse —
        // windowID degrades to nil and resolution falls back to the
        // positional form.
        let raw = "1\(gs)1\(gs)1\(gs)https://a.com\(gs)Alpha\(gs)個人 — Alpha\(rs)"
        let windows = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows[0].windowID)
        XCTAssertEqual(windows[0].profile, "個人")
    }

    func testParseWindowEnumerationMalformedWindowIDNil() {
        // A non-numeric id field must not crash the parser or corrupt
        // the record — windowID degrades to nil.
        let raw = "1\(gs)1\(gs)1\(gs)https://a.com\(gs)Alpha\(gs)win\(gs)garbage\(rs)"
        let windows = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows[0].windowID)
        XCTAssertEqual(windows[0].tabs[0].url, "https://a.com")
    }

    // MARK: - S2: identity-anchored references

    private func twoWindowFixture() -> [SafariBridge.WindowInfo] {
        [
            SafariBridge.WindowInfo(
                windowIndex: 1,
                currentTabIndex: 1,
                tabs: [
                    SafariBridge.TabInWindow(tabIndex: 1, url: "https://a.com/x", title: "A", isCurrent: true),
                    SafariBridge.TabInWindow(tabIndex: 2, url: "https://b.com/y", title: "B", isCurrent: false),
                ],
                windowID: 22510
            ),
            SafariBridge.WindowInfo(
                windowIndex: 2,
                currentTabIndex: 1,
                tabs: [
                    SafariBridge.TabInWindow(tabIndex: 1, url: "https://c.com/z", title: "C", isCurrent: true)
                ],
                windowID: 30691
            ),
        ]
    }

    func testPickNativeTargetURLMatchCarriesWindowIDAndAnchor() throws {
        let resolved = try SafariBridge.pickNativeTarget(
            .urlMatch(.contains("b.com")),
            in: twoWindowFixture()
        )
        XCTAssertEqual(resolved.windowID, 22510)
        // Anchor is the concrete matched tab index — set even when the
        // match is a background tab (here) or the current tab.
        XCTAssertEqual(resolved.anchorTabIndex, 2)
    }

    func testPickNativeTargetURLMatchCurrentTabStillAnchored() throws {
        // isCurrent collapses tabIndexInWindow to nil (no switch needed)
        // but the identity anchor must stay concrete.
        let resolved = try SafariBridge.pickNativeTarget(
            .urlMatch(.contains("c.com")),
            in: twoWindowFixture()
        )
        XCTAssertNil(resolved.tabIndexInWindow)
        XCTAssertEqual(resolved.windowID, 30691)
        XCTAssertEqual(resolved.anchorTabIndex, 1)
    }

    func testDocRefFromResolvedUsesWindowIDWhenAnchored() {
        let resolved = SafariBridge.ResolvedWindowTarget(
            windowIndex: 1, tabIndexInWindow: 2, windowID: 22510, anchorTabIndex: 2)
        XCTAssertEqual(
            SafariBridge.docRefFromResolved(resolved),
            "tab 2 of window id 22510"
        )
    }

    func testDocRefFromResolvedFallsBackToPositionalWithoutWindowID() {
        // Legacy enumeration (no id) keeps the pre-#79 positional form.
        let resolved = SafariBridge.ResolvedWindowTarget(windowIndex: 1, tabIndexInWindow: 2)
        XCTAssertEqual(SafariBridge.docRefFromResolved(resolved), "tab 2 of window 1")
    }

    func testDocRefFromResolvedWindowLevelKeepsDocumentForm() {
        // Window-level target (no anchor tab): keep `document of window N`
        // — the #21 modal-sheet bypass depends on document-scoped refs.
        let resolved = SafariBridge.ResolvedWindowTarget(
            windowIndex: 1, tabIndexInWindow: nil, windowID: 22510, anchorTabIndex: nil)
        XCTAssertEqual(SafariBridge.docRefFromResolved(resolved), "document of window 1")
    }

    func testResolveDocumentReferenceResolvedTab() {
        let ref = SafariBridge.resolveDocumentReference(
            .resolvedTab(windowID: 22510, tabInWindow: 3, rematch: nil))
        XCTAssertEqual(ref, "tab 3 of window id 22510")
    }
}
