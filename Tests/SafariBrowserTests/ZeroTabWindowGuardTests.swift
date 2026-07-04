import XCTest
@testable import SafariBrowser

/// Regression guards for the "zero-tab Safari window" family (#85, #86, #87).
///
/// A Safari window with 0 tabs exists but has no `current tab`; AppleScript
/// that reads `current tab` unconditionally raises `-1728`. These tests assert
/// the guard *structure* in the pure AppleScript-string outputs — this repo
/// tests AppleScript at the string level (see DocumentsCommandTests /
/// PreCompiledScriptsTests); live 0-tab execution is covered by E2E, not here.
///
/// Assertion discipline (#88 re-verify): pin the guard *block* (condition +
/// body), not merely textual precedence — a "keyword before read" check passes
/// even when a refactor moves the read outside the guard's `end if`, or inverts
/// the condition, or empties the body. Helpers below extract the guarded region.
final class ZeroTabWindowGuardTests: XCTestCase {

    /// The statements between an AppleScript guard keyword and its next `end if`.
    private func guardBody(_ script: String, after keyword: String) -> Substring? {
        guard let start = script.range(of: keyword),
              let endIf = script.range(of: "end if", range: start.upperBound..<script.endIndex)
        else { return nil }
        return script[start.upperBound..<endIf.lowerBound]
    }

    /// The first non-whitespace content immediately after a keyword.
    private func firstStatement(_ script: String, after keyword: String) -> Substring? {
        guard let start = script.range(of: keyword) else { return nil }
        return script[start.upperBound...].drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" })
    }

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
        XCTAssertTrue(
            SafariBridge.listAllWindowsScript.contains("if tabCount > 0"),
            "0-tab windows must be skipped via a tabCount guard (#85)")
    }

    func testListAllWindowsScript_currentTabReadIsFirstStatementInsideGuard() {
        // #88 re-verify L5/L7: prove the read is INSIDE the guard, not merely
        // after the keyword. Moving `set currentIdx` past `end if` (still in the
        // loop but outside the guard) reopens the -1728 crash — this must fail then.
        guard let after = firstStatement(SafariBridge.listAllWindowsScript, after: "if tabCount > 0 then") else {
            return XCTFail("script missing `if tabCount > 0 then` guard")
        }
        XCTAssertTrue(
            after.hasPrefix("set currentIdx to index of current tab of window w"),
            "current-tab read must be the FIRST statement inside the `if tabCount > 0` guard (#85)")
    }

    // MARK: - #86 getWindowIDViaAX existence validation

    func testWindowExistenceValidation_doesNotReadCurrentTab() {
        XCTAssertFalse(
            SafariBridge.windowExistenceValidationScript(windowIndex: 3).contains("current tab"),
            "window existence must not be proven via `current tab` — 0-tab windows exist but have none (#86)")
    }

    func testWindowExistenceValidation_usesThrowingIdProbe() {
        // #88 re-verify L4: pin the throwing `id of window N` probe. A bare
        // `exists window N` fails OPEN (returns false, doesn't throw) unless
        // wrapped as `if not (exists ...) then error`, so don't accept it here.
        XCTAssertTrue(
            SafariBridge.windowExistenceValidationScript(windowIndex: 3).contains("id of window 3"),
            "existence must use the throwing `id of window N` probe, not a fail-open bare `exists` (#86)")
    }

    // MARK: - #87 daemon runJSInCurrentTab

    func testRunJSInCurrentTabTemplate_zeroTabGuardErrorsBeforeDoJavaScript() {
        // #88 re-verify (finding 2): the 0-tab front-window guard must error with
        // an explicit message AND precede the do-JavaScript line.
        guard let tmpl = PreCompiledScripts.known["runJSInCurrentTab"] else {
            return XCTFail("runJSInCurrentTab template missing")
        }
        let s = tmpl.source
        guard let body = guardBody(s, after: "count of tabs of front window") else {
            return XCTFail("front-window tab guard missing or unclosed")
        }
        XCTAssertTrue(
            body.contains("error") && body.contains("front window has no tabs"),
            "0-tab front-window guard must error with an explicit message (#87)")
        guard let tabGuard = s.range(of: "count of tabs of front window"),
              let doJS = s.range(of: "do JavaScript") else {
            return XCTFail("template missing tab guard / do JavaScript")
        }
        XCTAssertLessThan(
            tabGuard.lowerBound, doJS.lowerBound,
            "tab guard must precede `do JavaScript` (#87)")
    }

    func testRunJSInCurrentTabTemplate_zeroWindowsGuardErrorsAndOrdersFirst() {
        // #88 re-verify M1 / finding 6: pin the `= 0` condition + error body, not
        // just ordering. Inverting `= 0`→`> 0` or emptying the guard must fail here.
        guard let tmpl = PreCompiledScripts.known["runJSInCurrentTab"] else {
            return XCTFail("runJSInCurrentTab template missing")
        }
        let s = tmpl.source
        guard let body = guardBody(s, after: "if (count of windows) = 0 then") else {
            return XCTFail("zero-windows `= 0` guard missing or unclosed (#87 M1)")
        }
        XCTAssertTrue(
            body.contains("error") && body.contains("Safari has no windows"),
            "zero-windows guard must error with an explicit message — an empty guard reopens -1728 (#87 M1)")
        guard let winGuard = s.range(of: "if (count of windows) = 0 then"),
              let tabGuard = s.range(of: "count of tabs of front window") else {
            return XCTFail("template missing windows / tab guards")
        }
        XCTAssertLessThan(
            winGuard.lowerBound, tabGuard.lowerBound,
            "zero-windows guard must precede the front-window tab-count guard (#87 M1)")
    }

    // MARK: - Parser behavior

    func testParseWindowEnumeration_emptyStringYieldsNoWindows() {
        // When every window is 0-tab, listAllWindowsScript returns "" (same as
        // 0 windows). The parser must treat that as "no windows" cleanly.
        XCTAssertEqual(SafariBridge.parseWindowEnumeration(""), [])
    }
}
