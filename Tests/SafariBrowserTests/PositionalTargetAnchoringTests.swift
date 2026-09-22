import XCTest
@testable import SafariBrowser

/// #180: `js` re-resolved its target before every AppleScript step because
/// `resolveToConcreteTarget` returned positional targets (`.frontWindow` /
/// `.windowIndex` / `.windowTab`) unchanged, and only `.resolvedTab` takes
/// the no-enumeration shortcut in `resolveScriptTarget`. The pure layer of
/// the fix — mapping a positional target plus a one-round-trip window anchor
/// (stable window id + current tab index) onto `.resolvedTab` — is pinned
/// here. The live orchestration (`resolveToAnchoredTarget`) is covered by
/// `make test-target-identity`.
final class PositionalTargetAnchoringTests: XCTestCase {

    private let gs = "\u{1D}"

    // MARK: - anchoredTarget: positional → identity-anchored

    func testFrontWindowAnchorsToResolvedTab() {
        let anchor = SafariBridge.WindowAnchor(windowID: 42, currentTabIndex: 3)
        let out = SafariBridge.anchoredTarget(.frontWindow, anchor: anchor, profile: nil)
        XCTAssertEqual(out, .resolvedTab(windowID: 42, tabInWindow: 3, rematch: nil, profile: nil))
    }

    func testWindowIndexAnchorsToResolvedTabCarryingProfile() {
        let anchor = SafariBridge.WindowAnchor(windowID: 7, currentTabIndex: 1)
        let out = SafariBridge.anchoredTarget(.windowIndex(2), anchor: anchor, profile: "個人")
        XCTAssertEqual(out, .resolvedTab(windowID: 7, tabInWindow: 1, rematch: nil, profile: "個人"))
    }

    func testNilAnchorLeavesPositionalTargetUnchanged() {
        // A 0-tab window (or no window at all) yields no anchor; the caller
        // must then fall back to the pre-#180 positional target so the
        // existing #87 / #97 error paths stay byte-identical.
        XCTAssertEqual(SafariBridge.anchoredTarget(.frontWindow, anchor: nil, profile: nil), .frontWindow)
        XCTAssertEqual(SafariBridge.anchoredTarget(.windowIndex(4), anchor: nil, profile: nil), .windowIndex(4))
    }

    func testNonPositionalTargetsPassThroughEvenWithAnchor() {
        let anchor = SafariBridge.WindowAnchor(windowID: 42, currentTabIndex: 3)
        let matcher = SafariBridge.UrlMatcher.contains("plaud")
        let already = SafariBridge.TargetDocument.resolvedTab(windowID: 9, tabInWindow: 2, rematch: matcher, profile: nil)
        XCTAssertEqual(SafariBridge.anchoredTarget(.urlMatch(matcher), anchor: anchor, profile: nil), .urlMatch(matcher))
        XCTAssertEqual(SafariBridge.anchoredTarget(.documentIndex(5), anchor: anchor, profile: nil), .documentIndex(5))
        XCTAssertEqual(SafariBridge.anchoredTarget(already, anchor: anchor, profile: nil), already)
        // `.windowTab` is collapsed through the enumeration path
        // (`resolveNativeTarget` + `concreteTarget`), never by a window anchor:
        // the anchor only knows the window's *current* tab, not tab M.
        XCTAssertEqual(SafariBridge.anchoredTarget(.windowTab(window: 1, tabInWindow: 5), anchor: anchor, profile: nil),
                       .windowTab(window: 1, tabInWindow: 5))
    }

    // MARK: - parseWindowAnchor: the one-round-trip script's output

    func testParseWindowAnchorReadsIdAndCurrentIndex() {
        let parsed = SafariBridge.parseWindowAnchor("42\(gs)3\n")
        XCTAssertEqual(parsed?.windowID, 42)
        XCTAssertEqual(parsed?.currentTabIndex, 3)
    }

    func testParseWindowAnchorRejectsMalformedOutput() {
        for raw in ["", "abc", "42", "42\(gs)", "\(gs)3", "42\(gs)0", "0\(gs)3", "-1\(gs)3", "42\(gs)x", "42\(gs)3\(gs)9"] {
            XCTAssertNil(SafariBridge.parseWindowAnchor(raw), "must reject \(raw.debugDescription)")
        }
    }

    // MARK: - windowAnchorScript: shape of the round-trip

    func testWindowAnchorScriptReadsOnlyIdAndCurrentTabIndex() {
        let script = SafariBridge.windowAnchorScript(index: 3)
        XCTAssertTrue(script.contains("id of window 3"), script)
        XCTAssertTrue(script.contains("index of current tab of window 3"), script)
        // It must never grow into an enumeration — that is exactly the cost
        // this anchor exists to avoid.
        XCTAssertFalse(script.contains("every tab"), script)
        XCTAssertFalse(script.contains("URL of"), script)
        XCTAssertFalse(script.contains("name of"), script)
        XCTAssertFalse(script.contains("repeat"), script)
    }

    // MARK: - .windowTab collapses through the enumeration path (pin)

    /// Not a RED test: this pins the existing pure collapse that
    /// `resolveToAnchoredTarget` relies on for `.windowTab` — one enumeration
    /// yields the window id + tab, and `concreteTarget` turns that into the
    /// identity-anchored form. If this ever degrades, `js --window N
    /// --tab-in-window M` silently returns to one enumeration per step.
    func testWindowTabCollapsesToResolvedTabAfterOneEnumeration() throws {
        let windows = [
            SafariBridge.WindowInfo(
                windowIndex: 1, currentTabIndex: 1,
                tabs: [
                    SafariBridge.TabInWindow(tabIndex: 1, url: "https://a/", title: "", isCurrent: true),
                    SafariBridge.TabInWindow(tabIndex: 2, url: "https://b/", title: "", isCurrent: false),
                ],
                windowID: 77)
        ]
        let resolved = try SafariBridge.resolveNativeTargetInWindows(.windowTab(window: 1, tabInWindow: 2), windows: windows)
        let concrete = SafariBridge.concreteTarget(from: resolved, original: .windowTab(window: 1, tabInWindow: 2), profile: nil)
        XCTAssertEqual(concrete, .resolvedTab(windowID: 77, tabInWindow: 2, rematch: nil, profile: nil))
    }
}
