import XCTest
@testable import SafariBrowser

/// Regression guards for the "zero-tab Safari window" family (#85, #86, #87).
///
/// A Safari window with 0 tabs exists but has no `current tab`; AppleScript
/// that reads `current tab` unconditionally raises `-1728`. These tests assert
/// the guard *structure* in the pure AppleScript-string outputs — this repo
/// tests AppleScript at the string level (see DocumentsCommandTests /
/// PreCompiledScriptsTests).
///
/// Coverage boundary (#88 re-verify finding 4): there is currently **no** E2E
/// harness exercising a live 0-tab window — these string assertions plus the
/// parser/resolver tests below are the whole safety net. Creating a real 0-tab
/// Safari window on demand is not scriptable without HID, which the
/// non-interference contract forbids; a harness would have to wait for the
/// state to occur naturally. Do not read these tests as live-behavior proof.
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
        // Pin the full `= 0` condition, not just the property read: keying on
        // "count of tabs of front window" alone let an inverted `> 0` guard
        // keep passing (#88 re-verify finding 5, also flagged by Codex).
        guard let body = guardBody(s, after: "if (count of tabs of front window) = 0 then") else {
            return XCTFail("front-window tab guard missing, unclosed, or no longer `= 0`")
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
        // Only Safari-has-no-windows returns "" now — a 0-tab window emits a
        // tab-less shell record (see the density tests below). The parser must
        // still treat the genuinely empty string as "no windows" cleanly.
        XCTAssertEqual(SafariBridge.parseWindowEnumeration(""), [])
    }

    // MARK: - Enumeration density (#88 re-verify findings 1 / 3 / 9)

    /// Build one enumeration record in the 7-field wire format.
    private func record(
        window: Int, tab: Int, isCurrent: Bool = false,
        url: String = "", title: String = "", winName: String = "", winID: String = ""
    ) -> String {
        let gs = "\u{1D}", rs = "\u{1E}"
        return [String(window), String(tab), isCurrent ? "1" : "0",
                url, title, winName, winID].joined(separator: gs) + rs
    }

    func testListAllWindowsScript_emitsShellRecordForZeroTabWindow() {
        // Dropping 0-tab windows entirely made the enumeration sparse, which
        // silently shifted every positional lookup after the hole. The guard
        // must have an else branch that still emits the window's slot.
        let s = SafariBridge.listAllWindowsScript
        guard let shell = s.range(of: "set output to output & w & GS & 0 & GS") else {
            return XCTFail("0-tab windows must emit a tab-less shell record (tab_idx 0), not be skipped")
        }
        guard let guardStart = s.range(of: "if tabCount > 0 then") else {
            return XCTFail("script missing `if tabCount > 0 then` guard")
        }
        // The shell record only runs for 0-tab windows if it sits on the guard's
        // else path. Anchoring on the nearest preceding `else` (rather than the
        // first one in the script) skips the inner is-current branch.
        guard let elseRange = s.range(of: "else", options: .backwards,
                                      range: guardStart.upperBound..<shell.lowerBound) else {
            return XCTFail("shell record is not on the `if tabCount > 0` else path — it would run for every window")
        }
        XCTAssertFalse(
            s[elseRange.upperBound..<shell.lowerBound].contains("current tab"),
            "the shell-record branch must stay free of `current tab` — that read is what raises -1728")
    }

    func testListAllWindowsScript_shellAndTabRecordsShareFieldCount() {
        // The script↔parser contract, pinned structurally. Hand-written
        // fixtures elsewhere in this file cannot catch a change to the script's
        // own emission: dropping the trailing winID field, or the empty title
        // field (which shifts winName into the title slot), both left every
        // test green while silently stripping the window's profile and window
        // id — putting the window back outside `--profile` candidate lists and
        // reopening the sparsity hole this whole fix closes (#88 verify r2).
        let s = SafariBridge.listAllWindowsScript
        let emissions = s
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("set output to output & w & GS &") }
        XCTAssertEqual(emissions.count, 2,
                       "expected exactly two emission sites (tab record + shell record), got \(emissions.count)")
        let separatorCounts = emissions.map { $0.components(separatedBy: "& GS &").count - 1 }
        XCTAssertEqual(
            separatorCounts.first, separatorCounts.last,
            "shell and tab records must carry identical field counts — a shifted field silently drops profile / window id: \(emissions)")
        XCTAssertEqual(
            separatorCounts.first, 6,
            "the wire format is 7 fields (6 GS separators); parseWindowEnumeration reads winName at index 5 and winID at index 6")
        for emission in emissions {
            XCTAssertTrue(emission.hasSuffix("& RS"),
                          "every record must be RS-terminated: \(emission)")
        }
    }

    func testParseWindowEnumeration_ignoresMalformedZeroTabRecord() {
        // A truncated / corrupt record that merely carries tab_idx 0 must NOT
        // register a window — conjuring a phantom candidate shifts every
        // positional lookup after it (Codex r2 finding 1).
        let gs = "\u{1D}", rs = "\u{1E}"
        let legacyFourField = ["2", "0", "0", ""].joined(separator: gs) + rs
        let raw = record(window: 1, tab: 1, isCurrent: true, url: "https://a/", winID: "11")
            + legacyFourField
            + record(window: 3, tab: 1, isCurrent: true, url: "https://c/", winID: "33")
        let windows = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(windows.map(\.windowIndex), [1, 3],
                       "a 4-field record is not a shell record and must not create window 2")
    }

    func testPickNativeTarget_otherTargetKindsUnaffectedByTablessWindow() {
        // Density restored for ordinals must not disturb the target kinds that
        // address tabs directly (Codex r2 finding 2).
        let windows = [
            SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1, tabs: [],
                                    profile: nil, windowID: 11),
            SafariBridge.WindowInfo(windowIndex: 2, currentTabIndex: 1, tabs: [
                SafariBridge.TabInWindow(tabIndex: 1, url: "https://w2a/", title: "", isCurrent: true),
            ], profile: nil, windowID: 22),
        ]

        // .documentIndex counts real tabs only — the tab-less window consumes
        // no document ordinal.
        let doc1 = try? SafariBridge.pickNativeTarget(.documentIndex(1), in: windows)
        XCTAssertEqual(doc1?.windowIndex, 2, "document 1 must be window 2's only tab")

        // .urlMatch scans tabs, so the shell contributes no candidate.
        let byURL = try? SafariBridge.pickNativeTarget(
.urlMatch(.contains("w2a")), in: windows)
        XCTAssertEqual(byURL?.windowIndex, 2)

        // .frontWindow keeps naming the first window even when it has no tabs.
        // Silently skipping ahead to the first *non-empty* window would be a
        // wrong-target resolution dressed up as convenience.
        let front = try? SafariBridge.pickNativeTarget(.frontWindow, in: windows)
        XCTAssertEqual(front?.windowIndex, 1,
                       ".frontWindow must not skip past a tab-less first window")
    }

    func testParseWindowEnumeration_shellRecordYieldsTablessWindow() {
        let raw = record(window: 1, tab: 1, isCurrent: true, url: "https://a/", winID: "11")
            + record(window: 2, tab: 0, winName: "個人 — (untitled)", winID: "22")
            + record(window: 3, tab: 1, isCurrent: true, url: "https://c/", winID: "33")
        let windows = SafariBridge.parseWindowEnumeration(raw)

        XCTAssertEqual(windows.map(\.windowIndex), [1, 2, 3],
                       "the 0-tab window must keep its slot so indices stay dense")
        XCTAssertTrue(windows[1].tabs.isEmpty,
                      "a shell record must not synthesise a phantom tab")
        XCTAssertEqual(windows[1].windowID, 22,
                       "window identity must survive on a tab-less window (#79 interop)")
        XCTAssertEqual(windows[1].profile, "個人",
                       "profile is parsed from the window name, which a 0-tab window still has")
    }

    func testPickNativeTarget_windowTabResolvesByPositionAcrossZeroTabHole() throws {
        // The regression this whole fix exists for: with the 0-tab window
        // present, `--window 3 --tab-in-window 2` must land on Safari window 3
        // — before the density fix it silently resolved to window 4.
        let windows = [
            SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1, tabs: [
                SafariBridge.TabInWindow(tabIndex: 1, url: "https://w1a/", title: "", isCurrent: true),
            ], profile: nil, windowID: 11),
            SafariBridge.WindowInfo(windowIndex: 2, currentTabIndex: 1, tabs: [],
                                    profile: nil, windowID: 22),
            SafariBridge.WindowInfo(windowIndex: 3, currentTabIndex: 1, tabs: [
                SafariBridge.TabInWindow(tabIndex: 1, url: "https://w3a/", title: "", isCurrent: true),
                SafariBridge.TabInWindow(tabIndex: 2, url: "https://w3b/", title: "", isCurrent: false),
            ], profile: nil, windowID: 33),
        ]

        let resolved = try SafariBridge.pickNativeTarget(.windowTab(window: 3, tabInWindow: 2), in: windows)
        XCTAssertEqual(resolved.windowIndex, 3,
                       "must resolve to Safari window 3, not shift past the 0-tab hole")
        XCTAssertEqual(resolved.tabIndexInWindow, 2)

        let byIndex = try SafariBridge.pickNativeTarget(.windowIndex(3), in: windows)
        XCTAssertEqual(byIndex.windowIndex, 3, "--window N must agree with --window N --tab-in-window M")
    }

    func testPickNativeTarget_zeroTabWindowTargetFailsHonestly() {
        // Targeting the 0-tab window itself must say "0 tabs", not claim the
        // window is missing (the old failure mode #86 set out to kill).
        let windows = [
            SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1, tabs: [
                SafariBridge.TabInWindow(tabIndex: 1, url: "https://w1a/", title: "", isCurrent: true),
            ], profile: nil, windowID: 11),
            SafariBridge.WindowInfo(windowIndex: 2, currentTabIndex: 1, tabs: [],
                                    profile: nil, windowID: 22),
        ]
        XCTAssertThrowsError(try SafariBridge.pickNativeTarget(.windowTab(window: 2, tabInWindow: 1), in: windows)) { error in
            guard case SafariBrowserError.documentNotFound(let pattern, _) = error else {
                return XCTFail("expected documentNotFound, got \(error)")
            }
            XCTAssertTrue(pattern.contains("0 tab"),
                          "error must name the real cause (window has 0 tabs), got: \(pattern)")
        }
    }

    func testPickNativeTarget_outOfRangeErrorIsSelfConsistent() {
        // D1: the pattern quotes the ordinal the caller typed, so the available
        // list must be labelled the same way. Printing "window 3 not found"
        // above "window 3: https://…" is a contradiction the user cannot act on.
        let windows = [
            SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1, tabs: [
                SafariBridge.TabInWindow(tabIndex: 1, url: "https://w1a/", title: "", isCurrent: true),
            ], profile: "個人", windowID: 11),
            SafariBridge.WindowInfo(windowIndex: 3, currentTabIndex: 1, tabs: [
                SafariBridge.TabInWindow(tabIndex: 1, url: "https://w3a/", title: "", isCurrent: true),
            ], profile: "個人", windowID: 33),
        ]
        // Profile filtering is the case where ordinal and Safari index legitimately
        // diverge; the summary must disambiguate rather than mix the two.
        XCTAssertThrowsError(
            try SafariBridge.pickNativeTarget(.windowTab(window: 3, tabInWindow: 1), in: windows, profile: "個人")
        ) { error in
            guard case SafariBrowserError.documentNotFound(let pattern, let available) = error else {
                return XCTFail("expected documentNotFound, got \(error)")
            }
            XCTAssertTrue(pattern.contains("window 3"))
            XCTAssertFalse(
                available.contains(where: { $0.hasPrefix("window 3:") }),
                "must not list `window 3` as available while claiming window 3 is not found: \(available)")
            XCTAssertTrue(
                available.contains(where: { $0.contains("Safari window 3") }),
                "the Safari index must still be surfaced for actionability: \(available)")
        }
    }

    // MARK: - #93 closeCurrentTab 0-tab guard

    func testCloseCurrentTabScript_guardsZeroTabsBeforeClosing() {
        // A 0-tab window used to reach `close current tab of window N`, whose
        // -1728 was translated into "window N not found" — the window plainly
        // exists, and that false negative is the one #86 removed from the
        // existence probe. Guard the count first, and say what is actually
        // wrong.
        let s = SafariBridge.closeCurrentTabScript(windowRef: "window 3")
        guard let body = guardBody(s, after: "if (count of tabs of window 3) = 0 then") else {
            return XCTFail("tab-count guard missing, unclosed, or no longer `= 0`")
        }
        XCTAssertTrue(
            body.contains("error") && body.contains("no tabs"),
            "the 0-tab case must fail with its real cause, not a missing-window error")
        guard let tabGuard = s.range(of: "count of tabs of window 3"),
              let close = s.range(of: "close current tab") else {
            return XCTFail("script missing guard / close")
        }
        XCTAssertLessThan(tabGuard.lowerBound, close.lowerBound,
                          "the guard must precede the close, or it guards nothing")
    }

    func testCloseCurrentTabScript_zeroWindowsGuardComesFirst() {
        // With no windows at all, `count of tabs of front window` would itself
        // raise -1728 — the guard has to be reachable to be useful.
        let s = SafariBridge.closeCurrentTabScript(windowRef: "front window")
        guard let winGuard = s.range(of: "if (count of windows) = 0 then"),
              let tabGuard = s.range(of: "count of tabs of front window") else {
            return XCTFail("script missing windows / tab guards")
        }
        XCTAssertLessThan(winGuard.lowerBound, tabGuard.lowerBound,
                          "zero-windows guard must precede the tab-count guard")
    }
}
