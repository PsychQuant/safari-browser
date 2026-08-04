import XCTest
@testable import SafariBrowser

/// #95: `documents` accounting for windows it cannot list.
///
/// Its stdout is a tab-level, parser-stable list (#46, #53), so a 0-tab window
/// has no row to occupy — which made the one window most likely to be causing
/// trouble the one thing the diagnostic command could not show.
final class TablessWindowNoteTests: XCTestCase {

    private func window(_ index: Int, tabs: Int, profile: String? = nil) -> SafariBridge.WindowInfo {
        SafariBridge.WindowInfo(
            windowIndex: index,
            currentTabIndex: 1,
            tabs: (1...max(tabs, 1)).prefix(tabs).map {
                SafariBridge.TabInWindow(tabIndex: $0, url: "https://w\(index)t\($0)/", title: "", isCurrent: $0 == 1)
            },
            profile: profile,
            windowID: index * 11
        )
    }

    func testSilentWhenEveryWindowHasTabs() {
        // A note on every run would stop being read. Silence is the correct
        // output for the ordinary case.
        let note = DocumentsCommand.tablessWindowNote(
            for: [window(1, tabs: 2), window(2, tabs: 1)], profileFilter: nil)
        XCTAssertNil(note)
    }

    func testNamesTheWindowAndItsSurvivingUse() {
        let note = DocumentsCommand.tablessWindowNote(
            for: [window(1, tabs: 2), window(2, tabs: 0)], profileFilter: nil)
        guard let note else { return XCTFail("a tab-less window must be accounted for") }
        XCTAssertTrue(note.contains("window 2"), "the note must say which window: \(note)")
        XCTAssertTrue(note.contains("--window"),
                      "a window absent from the listing is still targetable — say so: \(note)")
        XCTAssertTrue(note.hasSuffix("\n"))
    }

    func testPluralisesRatherThanReadingAsBroken() {
        let note = DocumentsCommand.tablessWindowNote(
            for: [window(1, tabs: 0), window(2, tabs: 0)], profileFilter: nil)
        guard let note else { return XCTFail("expected a note") }
        XCTAssertTrue(note.contains("window 1, window 2"))
        XCTAssertTrue(note.contains("have"), "two windows must not read as 'window 1, window 2 has': \(note)")
    }

    func testRespectsTheProfileFilter() {
        // `documents --profile X` filters the listing; reporting a window the
        // user just filtered out would contradict the output above it.
        let windows = [window(1, tabs: 1, profile: "個人"), window(2, tabs: 0, profile: "中研院")]
        XCTAssertNil(
            DocumentsCommand.tablessWindowNote(for: windows, profileFilter: "個人"),
            "a window outside the filter must not be reported")
        XCTAssertNotNil(
            DocumentsCommand.tablessWindowNote(for: windows, profileFilter: "中研院"),
            "a tab-less window inside the filter must still be reported")
    }
}
