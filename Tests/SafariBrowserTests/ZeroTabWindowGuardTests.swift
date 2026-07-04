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
}
