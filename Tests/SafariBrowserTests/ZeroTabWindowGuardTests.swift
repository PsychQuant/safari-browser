import XCTest
@testable import SafariBrowser

/// Regression guards for the "zero-tab Safari window" family (#85, #86, #87).
///
/// A Safari window with 0 tabs exists but has no `current tab`; AppleScript
/// that reads `current tab` unconditionally raises `-1728`. These tests assert
/// the guard *structure* in the pure AppleScript-string outputs — this repo
/// tests AppleScript at the string level (see DocumentsCommandTests /
/// PreCompiledScriptsTests); live 0-tab execution is covered by E2E, not here.
final class ZeroTabWindowGuardTests: XCTestCase {

    // MARK: - #85 listAllWindows enumeration

    func testListAllWindowsScript_countsTabsBeforeReadingCurrentTab() {
        let script = SafariBridge.listAllWindowsScript
        guard let countRange = script.range(of: "count of tabs of window w"),
              let currentRange = script.range(of: "current tab of window w") else {
            return XCTFail("script missing expected tab / current-tab references")
        }
        XCTAssertLessThan(
            countRange.lowerBound, currentRange.lowerBound,
            "must count tabs BEFORE reading current tab so 0-tab windows are skipped (#85)")
    }

    func testListAllWindowsScript_guardsZeroTabWindows() {
        let script = SafariBridge.listAllWindowsScript
        XCTAssertTrue(
            script.contains("if tabCount > 0"),
            "0-tab windows must be skipped via a tabCount guard (#85)")
    }

    // MARK: - #86 getWindowIDViaAX existence validation

    func testWindowExistenceValidation_doesNotReadCurrentTab() {
        let script = SafariBridge.windowExistenceValidationScript(windowIndex: 3)
        XCTAssertFalse(
            script.contains("current tab"),
            "window existence must not be proven via `current tab` — 0-tab windows exist but have none (#86)")
    }

    func testWindowExistenceValidation_usesTabIndependentProbe() {
        let script = SafariBridge.windowExistenceValidationScript(windowIndex: 3)
        XCTAssertTrue(
            script.contains("id of window 3") || script.contains("exists window 3"),
            "existence must use a tab-independent probe (id / exists) (#86)")
    }

    // MARK: - #87 daemon runJSInCurrentTab

    func testRunJSInCurrentTabTemplate_guardsZeroTabFrontWindow() {
        guard let tmpl = PreCompiledScripts.known["runJSInCurrentTab"] else {
            return XCTFail("runJSInCurrentTab template missing")
        }
        XCTAssertTrue(
            tmpl.source.contains("count of tabs of front window"),
            "must guard a 0-tab front window before `do JavaScript in current tab` (#87)")
    }

    func testRunJSInCurrentTabTemplate_guardsZeroWindowsBeforeFrontWindow() {
        // #88 verify M1: with 0 windows, `front window` doesn't exist, so the
        // tab-count guard itself would raise -1728. The windows guard must run first.
        guard let tmpl = PreCompiledScripts.known["runJSInCurrentTab"] else {
            return XCTFail("runJSInCurrentTab template missing")
        }
        guard let winGuard = tmpl.source.range(of: "count of windows"),
              let tabGuard = tmpl.source.range(of: "count of tabs of front window") else {
            return XCTFail("template missing windows / front-window tab guards")
        }
        XCTAssertLessThan(
            winGuard.lowerBound, tabGuard.lowerBound,
            "zero-windows guard must precede the front-window tab-count guard (#87 / #88 M1)")
    }

    // MARK: - #88 verify L5/L11: tighten #85 ordering to pin current-tab INSIDE the guard

    func testListAllWindowsScript_readsCurrentTabInsideTabCountGuard() {
        // Stronger than countsTabsBeforeReadingCurrentTab: the guard keyword must
        // appear BEFORE the current-tab read, proving current tab is read inside
        // `if tabCount > 0` — not merely somewhere after `count of tabs`.
        let script = SafariBridge.listAllWindowsScript
        guard let guardRange = script.range(of: "if tabCount > 0"),
              let currentRange = script.range(of: "current tab of window w") else {
            return XCTFail("script missing guard / current-tab references")
        }
        XCTAssertLessThan(
            guardRange.lowerBound, currentRange.lowerBound,
            "current tab must be read INSIDE the `if tabCount > 0` guard (#85 / #88 L5)")
    }

    // MARK: - #88 verify L4/L7: behavior test for the empty-enumeration path

    func testParseWindowEnumeration_emptyStringYieldsNoWindows() {
        // When every window is 0-tab, listAllWindowsScript returns "" (same as
        // 0 windows). Confirm the parser treats that as "no windows" cleanly,
        // not a parse error — so documents/--url show "no documents" not garbage.
        XCTAssertEqual(SafariBridge.parseWindowEnumeration(""), [])
    }
}
