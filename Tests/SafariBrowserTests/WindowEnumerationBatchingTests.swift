import XCTest
@testable import SafariBrowser

/// #180 (b): `listAllWindowsScript` read every tab's URL and name with two
/// Apple events per tab — ~218 events for 109 tabs, 2.6–4.9 s standalone.
/// `URL of every tab of window w` / `name of every tab of window w` return
/// the same values in two events per window (0.5–1.0 s, identical output).
/// These tests pin the batched shape structurally, the same way
/// `ZeroTabWindowGuardTests` pins the 0-tab guard and the wire format —
/// live execution stays E2E-only.
final class WindowEnumerationBatchingTests: XCTestCase {

    func testEnumerationReadsTabURLsAndNamesInBatchesPerWindow() {
        let s = SafariBridge.listAllWindowsScript
        XCTAssertTrue(s.contains("URL of every tab of window w"),
                      "hot path must read all URLs of a window in one Apple event")
        XCTAssertTrue(s.contains("name of every tab of window w"),
                      "hot path must read all names of a window in one Apple event")
    }

    func testPerTabReadsSurviveOnlyInsideTheErrorFallback() {
        // The batched reads keep a per-tab fallback (a tab mid-load or a
        // ghost tab could make the whole-window read raise). That fallback
        // must be the ONLY place per-tab reads remain: any occurrence before
        // the `on error` would mean the hot path is still O(tabs).
        let s = SafariBridge.listAllWindowsScript
        guard let onError = s.range(of: "if not stable then") else {
            return XCTFail("batched reads need a fallback to the per-tab loop when no stable batch was read")
        }
        for needle in ["URL of tab t of window w", "name of tab t of window w"] {
            var occurrences = 0
            var cursor = s.startIndex
            while let found = s.range(of: needle, range: cursor..<s.endIndex) {
                occurrences += 1
                XCTAssertTrue(found.lowerBound > onError.lowerBound,
                              "`\(needle)` appears before the fallback — hot path is still per-tab")
                cursor = found.upperBound
            }
            XCTAssertEqual(occurrences, 1, "expected exactly one fallback read of `\(needle)`, got \(occurrences)")
        }
    }

    func testBatchedReadFallsBackWhenListLengthDisagreesWithTabCount() {
        // A tab closed between `count of tabs` and `every tab` shortens the
        // list; indexing `item t` past its end would raise mid-enumeration.
        // The script must detect the mismatch and refill per tab (which then
        // fails on the exact tab, as it did before #180) rather than trust
        // a list that no longer lines up with `tabCount`.
        let s = SafariBridge.listAllWindowsScript
        XCTAssertTrue(s.contains("count of urls"), "no length check against tabCount for the batched URL list")
        XCTAssertTrue(s.contains("count of names"), "no length check against tabCount for the batched name list")
    }

    func testEmissionStillComesFromASingleSiteOverTheLists() {
        // The fallback must refill the SAME lists, not add a second emission
        // loop — ZeroTabWindowGuardTests pins exactly two emission sites
        // (window record + shell record) as the script↔decoder contract.
        // #355: the window record carries the batched lists themselves; no
        // per-tab loop builds anything out of a tab's URL or name.
        let s = SafariBridge.listAllWindowsScript
        let emissions = s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("set end of output to {w,") }
        XCTAssertEqual(emissions.count, 2)
        XCTAssertTrue(emissions.contains("set end of output to {w, winID, winName, currentIdx, urls, names}"),
                      "the window record must carry the batched URL and name lists: \(emissions)")
        XCTAssertFalse(s.contains("item t of urls") || s.contains("item t of names"),
                       "#355: no per-tab step may read a tab's URL or name out of the lists")
    }

    func testThePageTextIsNeverJoinedOrTouchedCharacterByCharacter() {
        // #355: titles, window names and URLs travel only as AppleScript text
        // values inside the returned list. No separator characters, no
        // concatenation into an output string, no per-character handler.
        let s = SafariBridge.listAllWindowsScript
        for needle in ["character id", "text item delimiters", "& GS &", "& RS", "ignoring diacriticals", "set output to output"] {
            XCTAssertFalse(s.contains(needle), "the enumeration script must not contain `\(needle)`")
        }
        XCTAssertTrue(s.contains("set output to {}"), "the result is a list that starts empty (no windows → {})")
        XCTAssertTrue(s.contains("return output"))
        XCTAssertFalse(s.contains("return \"\""), "no windows must be `{}`, not an empty text")
    }

    func testBatchedURLsAreReReadSoAReorderCannotPairAURLWithAnotherTabsTitle() {
        // Verify R2: URLs and names come from two Apple events. A same-count
        // change between them (close one tab, open another; drag a tab) passes
        // a length check but pairs a URL with a different tab's title. The URL
        // list is read again after the names and must match the first read.
        let s = SafariBridge.listAllWindowsScript
        XCTAssertTrue(s.contains("set urls2 to URL of every tab of window w"), s)
        XCTAssertTrue(s.contains("urls = urls2"), "the re-read must be compared with the first read")
        XCTAssertTrue(s.contains("considering case"), "URL comparison must be case-sensitive")
    }

    func testTheEnumerationScriptCompiles() {
        // Compile only (no Safari is asked for anything): catches a record
        // literal or `set end of` that AppleScript would reject.
        var error: NSDictionary?
        let ok = NSAppleScript(source: SafariBridge.listAllWindowsScript)?.compileAndReturnError(&error) ?? false
        XCTAssertTrue(ok, "listAllWindowsScript does not compile: \(String(describing: error))")
    }
}
