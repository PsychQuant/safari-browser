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
        guard let onError = s.range(of: "on error") else {
            return XCTFail("batched reads need an `on error` fallback to the per-tab loop")
        }
        for needle in ["URL of tab t of window w", "name of tab t of window w"] {
            var occurrences = 0
            var cursor = s.startIndex
            while let found = s.range(of: needle, range: cursor..<s.endIndex) {
                occurrences += 1
                XCTAssertTrue(found.lowerBound > onError.lowerBound,
                              "`\(needle)` appears before the `on error` fallback — hot path is still per-tab")
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
        // (tab record + shell record) as the script↔parser contract.
        let s = SafariBridge.listAllWindowsScript
        let emissions = s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("set output to output & w & GS &") }
        XCTAssertEqual(emissions.count, 2)
        XCTAssertTrue(s.contains("item t of urls"), "tab record must read its URL from the batched list")
        XCTAssertTrue(s.contains("item t of names"), "tab record must read its name from the batched list")
    }
}
