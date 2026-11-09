import XCTest
@testable import SafariBrowser

/// #362 verify F16: the change claims that a listing without `--profile`, and its hint, are byte-identical to what
/// they were before it, apart from the changes it makes on purpose. The first three tests are the exact messages of
/// three such misses; each was rendered on the commit before #362 (ef8cdf7) and on this branch and found identical,
/// and those three tests pass on both. A change to them is a change to the unprofiled messages, and needs its own
/// reason. The fourth test pins one message #362 changed on purpose (verify round 2, finding B), so it fails on
/// ef8cdf7: a URL miss with no tab listed, which there ended with the hint for a listing with entries ("coordinates
/// are shown per entry"). The CHANGELOG entry for #362 lists every unprofiled change.
final class UnprofiledMissGoldenTests: XCTestCase {
    private static func tab(_ index: Int, _ url: String, current: Bool) -> SafariBridge.TabInWindow {
        SafariBridge.TabInWindow(tabIndex: index, url: url, title: "t", isCurrent: current)
    }

    /// Safari window 1 is Home (id 101); windows 2 and 3 are Work (ids 303, 404). One URL has a query, so the
    /// shortened-URL note and marker are pinned too.
    private static let windows = [
        SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1, tabs: [tab(1, "https://home.example/1", current: true)],
                                profile: "Home", windowID: 101),
        SafariBridge.WindowInfo(windowIndex: 2, currentTabIndex: 1,
                                tabs: [tab(1, "https://work.example/a1?q=1", current: true),
                                       tab(2, "https://work.example/a2", current: false)],
                                profile: "Work", windowID: 303),
        SafariBridge.WindowInfo(windowIndex: 3, currentTabIndex: 1, tabs: [tab(1, "https://work.example/b1", current: true)],
                                profile: "Work", windowID: 404),
    ]

    private func message(_ target: SafariBridge.TargetDocument, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try SafariBridge.pickNativeTarget(target, in: Self.windows, profile: nil)
            XCTFail("\(target) must miss", file: file, line: line)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        return ""
    }

    func testAURLMissWithoutAProfileIsUnchanged() {
        XCTAssertEqual(message(.urlMatch(.contains("nothing-matches"))), """
            No Safari document matches "nothing-matches".
            (The flag is supported and did run — this is a targeting miss, not an unknown option.)
            Available documents:
              [1] window 1 tab 1: https://home.example/1
              [2] window 2 tab 1: https://work.example/a1?…
              [3] window 2 tab 2: https://work.example/a2
              [4] window 3 tab 1: https://work.example/b1
            (URLs are shown shortened — a query, fragment, credentials, path parameters or a long tail is replaced by `…`; `safari-browser documents` prints them in full.)
            Hint: --url matches a *substring* of the URL, not the whole URL, and not the title —
                  no tab's URL contained this text. Refine it against the URLs above, if any are listed
                  (shown without their query or fragment — `safari-browser documents` prints them in
                  full). An entry with a `…` marker (`?…`, `#…`, `…@`, `;…`) shows less than the URL
                  and is not itself part of any URL: copy only what precedes its first marker (it can
                  be short, as in `https://…@host`) into --url, and take the whole URL from
                  `safari-browser documents` for --url-exact or --url-endswith. Or target
                  positionally with --window N --tab-in-window M (coordinates are shown per entry;
                  with --profile, N counts only that profile's windows; --document N numbers the
                  tabs as `safari-browser documents` does, which can differ from the [N] shown above).
                  For stricter matching see --url-exact / --url-endswith / --url-regex.
            """)
    }

    func testATabOutOfRangeWithoutAProfileIsUnchanged() {
        XCTAssertEqual(message(.windowTab(window: 2, tabInWindow: 99)), """
            No Safari document matches "window 2 tab 99 (window has 2 tab(s))".
            (The flag is supported and did run — this is a targeting miss, not an unknown option.)
            Available documents:
              [1] window 2 tab 1: https://work.example/a1?…
              [2] window 2 tab 2: https://work.example/a2
            (URLs are shown shortened — a query, fragment, credentials, path parameters or a long tail is replaced by `…`; `safari-browser documents` prints them in full.)
            Hint: each entry above shows its own coordinates — target one with
                  --window N --tab-in-window M. (With --profile, N counts only that
                  profile's windows. --document N numbers the tabs as `safari-browser documents`
                  does, which can differ from the [N] shown above.)
            """)
    }

    func testADocumentOutOfRangeWithoutAProfileIsUnchanged() {
        XCTAssertEqual(message(.documentIndex(99)), """
            No Safari document matches "document 99 (only 4 tab(s) available)".
            (The flag is supported and did run — this is a targeting miss, not an unknown option.)
            Available documents:
              [1] window 1: https://home.example/1 (1 tab(s))
              [2] window 2: https://work.example/a1?… (2 tab(s))
              [3] window 3: https://work.example/b1 (1 tab(s))
            (URLs are shown shortened — a query, fragment, credentials, path parameters or a long tail is replaced by `…`; `safari-browser documents` prints them in full.)
            Hint: each entry above shows its own coordinates — target one with
                  --window N --tab-in-window M. (With --profile, N counts only that
                  profile's windows. --document N numbers the tabs as `safari-browser documents`
                  does, which can differ from the [N] shown above.)
            """)
    }

    func testAURLMissWithNothingOpenWithoutAProfileSaysNoTabIsListed() {
        do {
            _ = try SafariBridge.pickNativeTarget(.urlMatch(.contains("nothing-matches")), in: [], profile: nil)
            XCTFail("must miss")
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, """
            No Safari document matches "nothing-matches".
            (The flag is supported and did run — this is a targeting miss, not an unknown option.)
            Available documents:
              (no Safari documents are currently open)
            Hint: --url matches a *substring* of the URL, not the whole URL, and not the title —
                  no tab's URL contained this text, and no tab is listed above. Run
                  `safari-browser documents` to see the open tabs and their URLs in full, then refine
                  the substring. For stricter matching see --url-exact / --url-endswith / --url-regex.
            """)
        }
    }
}
