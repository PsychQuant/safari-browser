import XCTest
@testable import SafariBrowser

/// #355: `decodeWindowEnumeration` turns the enumeration's source form text into windows, or fails
/// the command with `windowEnumerationCorrupt`. Inputs are hand-written source form; expected
/// values are written out, not derived from the decoder.
final class WindowEnumerationDecoderTests: XCTestCase {

    private typealias Tab = SafariBridge.TabInWindow
    private typealias Window = SafariBridge.WindowInfo

    func testAWellFormedListDecodes() throws {
        let text = #"""
            {{1, 4711, "個人 — Example", 2, {"https://a/", "https://b/", missing value}, {"A", "B \"q\" \\", missing value}}, \#
            {2, missing value, missing value, 0, {}, {}}, \#
            {3, 99, "Plain", 1, {"https://c/"}, {"C"}}}
            """#
        let windows = try SafariBridge.decodeWindowEnumeration(text)
        XCTAssertEqual(windows, [
            Window(windowIndex: 1, currentTabIndex: 2, tabs: [
                Tab(tabIndex: 1, url: "https://a/", title: "A", isCurrent: false),
                Tab(tabIndex: 2, url: "https://b/", title: "B \"q\" \\", isCurrent: true),
                Tab(tabIndex: 3, url: "", title: "", isCurrent: false),
            ], profile: "個人", windowID: 4711),
            Window(windowIndex: 2, currentTabIndex: 1, tabs: [], profile: nil, windowID: nil),
            Window(windowIndex: 3, currentTabIndex: 1, tabs: [
                Tab(tabIndex: 1, url: "https://c/", title: "C", isCurrent: true),
            ], profile: nil, windowID: 99),
        ])
    }

    func testAnEmptyListIsNoWindows() throws {
        XCTAssertEqual(try SafariBridge.decodeWindowEnumeration("{}"), [])
        XCTAssertEqual(try SafariBridge.decodeWindowEnumeration("{}\n"), [])
    }

    func testAnEmptyTextIsNotNoWindows() {
        // A daemon path that returned a list's `stringValue` (nil → "") must not read as "no windows".
        assertCorrupt("")
        assertCorrupt("  \n")
    }

    func testRejectedShapes() {
        let rejected: [(String, String)] = [
            (#"{{1, 7, "w", 1, {"u"}, {"t"}, 9}}"#, "seven elements"),
            (#"{{1, 7, "w", 1, {"u"}}}"#, "five elements"),
            (#"{{2, 7, "w", 1, {"u"}, {"t"}}}"#, "first window numbered 2"),
            (#"{{1, 7, "w", 1, {"u"}, {"t"}}, {1, 8, "w", 1, {"u"}, {"t"}}}"#, "window number repeated"),
            (#"{{1, 3.5, "w", 1, {"u"}, {"t"}}}"#, "window id not an integer"),
            (#"{{1, "7", "w", 1, {"u"}, {"t"}}}"#, "window id is text"),
            (#"{{1, 7, 5, 1, {"u"}, {"t"}}}"#, "window name not text"),
            (#"{{1, 7, "w", "1", {"u"}, {"t"}}}"#, "current tab not an integer"),
            (#"{{1, 7, "w", 1, {}, {}}}"#, "no tabs but current tab 1"),
            (#"{{1, 7, "w", 1, {"u", "v"}, {"t"}}}"#, "unequal lists"),
            (#"{{1, 7, "w", 1, {"u"}, {"t", "s"}}}"#, "fewer URLs than titles"),
            (#"{{1, 7, "w", 1, "u", {"t"}}}"#, "URLs not a list"),
            (#"{{1, 7, "w", 1, {1}, {"t"}}}"#, "URL not text"),
            (#"{{1, 7, "w", 1, {"u"}, {{"t"}}}}"#, "title is a list"),
            (#"{{1, 7, "w", 1, {"u"}, {"t"}}, {2, 7, "x", 1, {"v"}, {"s"}}}"#, "duplicate window id"),
            (#"{1, 7, "w", 1, {"u"}, {"t"}}"#, "items not lists"),
            (#""text""#, "not a list"),
            (#"{{1, 7, "w", 1, {"u"}, {"t"}}"#, "unterminated"),
        ]
        for (text, why) in rejected {
            assertCorrupt(text, why)
        }
    }

    func testAReasonNamesNoStringContent() {
        let texts = [
            #"{{1, 7, "SECRET", 1, {"SECRET", "SECRET"}, {"SECRET"}}}"#,
            #"{{1, 7, "SECRET", 3, {}, {}}}"#,
            #"{{1, SECRET, "SECRET", 1, {"SECRET"}, {"SECRET"}}}"#,
            #"{{1, 7, "SECRET", 1, {"SECRET"}, {SECRET}}}"#,
            #"{{1, 7, "SECRET\x", 1, {"SECRET"}, {"SECRET"}}}"#,
        ]
        for text in texts {
            do {
                _ = try SafariBridge.decodeWindowEnumeration(text)
                XCTFail("expected a failure for \(text)")
            } catch {
                let message = "\(error) \(error.localizedDescription)"
                XCTAssertFalse(message.contains("SECRET"), message)
            }
        }
    }

    func testTwoWindowsWithoutAnIDAreNotDuplicates() throws {
        let windows = try SafariBridge.decodeWindowEnumeration(
            #"{{1, missing value, "", 0, {}, {}}, {2, missing value, "", 0, {}, {}}}"#)
        XCTAssertEqual(windows.map(\.windowIndex), [1, 2])
        XCTAssertEqual(windows.map(\.windowID), [nil, nil])
    }

    private func assertCorrupt(_ text: String, _ why: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SafariBridge.decodeWindowEnumeration(text), why, file: file, line: line) { error in
            guard case SafariBrowserError.windowEnumerationCorrupt = error else {
                return XCTFail("\(why): expected windowEnumerationCorrupt, got \(error)", file: file, line: line)
            }
        }
    }

    /// A tab opened and made current between `count of tabs` and `index of current tab` leaves
    /// the current index one past the tabs the per-tab fallback read (#355 verify round 2). The
    /// window keeps its rows with no tab current, as before #355; `currentTabIndex` is 0 so no
    /// resolver mistakes tab 1 for the current tab and skips the tab switch.
    func testACurrentTabOutsideTheTabsMarksNoTabCurrent() throws {
        for current in [2, 9] {
            let windows = try SafariBridge.decodeWindowEnumeration(
                "{{1, 7, \"w\", \(current), {\"https://a/\"}, {\"A\"}}}")
            XCTAssertEqual(windows, [Window(windowIndex: 1, currentTabIndex: 0, tabs: [
                Tab(tabIndex: 1, url: "https://a/", title: "A", isCurrent: false),
            ], profile: nil, windowID: 7)], "current \(current)")
        }
    }

    func testAWindowWithoutACurrentTabStillResolvesAndListsWithoutAMarker() throws {
        let windows = try SafariBridge.decodeWindowEnumeration(
            #"{{1, 7, "w", 3, {"https://a/", "https://b/"}, {"A", "B"}}}"#)
        // `--window-id 7 --tab-in-window 1` must switch to tab 1, not assume it is current.
        let byID = try SafariBridge.pickNativeTarget(.windowID(7, tabInWindow: 1), in: windows)
        XCTAssertEqual(byID.tabIndexInWindow, 1)
        let byPosition = try SafariBridge.pickNativeTarget(.windowTab(window: 1, tabInWindow: 1), in: windows)
        XCTAssertEqual(byPosition.tabIndexInWindow, 1)
        let byURL = try SafariBridge.pickNativeTarget(.urlMatch(.contains("https://a/")), in: windows)
        XCTAssertEqual(byURL.tabIndexInWindow, 1)
        // `--window 1` alone still names the window (its current tab at each Apple event).
        XCTAssertNoThrow(try SafariBridge.pickNativeTarget(.windowIndex(1), in: windows))

        let documents = SafariBridge.flattenWindowsToDocuments(windows)
        let rows = DocumentsCommand.jsonRows(documents, observation: .unavailable(reason: "test"))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.compactMap { $0["is_current"] as? Bool }, [false, false])
        let text = DocumentsCommand.formatText(documents, observation: .unavailable(reason: "test")).joined(separator: "\n")
        XCTAssertFalse(text.contains("*"), text)
    }

    /// Only an index past the tabs comes from the race; `index of current tab` is never below 1 on
    /// a window with tabs, so such an index is a list the script cannot produce (#355 verify round 3).
    func testACurrentTabBelowOneOnAWindowWithTabsStillFails() {
        for current in [0, -1] {
            XCTAssertThrowsError(try SafariBridge.decodeWindowEnumeration(
                "{{1, 7, \"w\", \(current), {\"https://a/\"}, {\"A\"}}}"), "current \(current)") { error in
                guard case SafariBrowserError.windowEnumerationCorrupt = error else {
                    return XCTFail("expected windowEnumerationCorrupt, got \(error)")
                }
            }
        }
    }

    /// `--window-id W --profile P` with W not one of P's windows lists P's windows by their current
    /// tab. A window with tabs but none current (read while a tab opened) is "(unknown)", not
    /// "(0 tabs)"; only a window without tabs is "(0 tabs)" (#355 verify round 3).
    func testAWindowIDMissListsAWindowWithoutACurrentTabAsUnknown() throws {
        let windows = try SafariBridge.decodeWindowEnumeration(
            #"{{1, 7, "Work — A", 3, {"https://a/", "https://b/"}, {"A", "B"}}, {2, 8, "Work — x", 0, {}, {}}}"#)
        XCTAssertThrowsError(try SafariBridge.checkWindowID(99, profile: "Work", in: windows)) { error in
            guard case SafariBrowserError.documentNotFound(_, let entries) = error else {
                return XCTFail("expected documentNotFound, got \(error)")
            }
            XCTAssertEqual(entries, ["window id 7: (unknown)", "window id 8: (0 tabs)"])
        }
    }

    /// The message depends on why the list was rejected (#355 verify round 3): two windows with one
    /// id happen when a window opens or is raised mid-read, so running the command again helps; a
    /// window id that is not an AppleScript integer (an id of 2^29 or more arrives as a real) will
    /// not go away on a rerun; anything else is a list the script cannot produce.
    func testTheMessageMatchesTheReason() {
        func message(_ text: String) -> String {
            do {
                _ = try SafariBridge.decodeWindowEnumeration(text)
                return "decoded"
            } catch {
                return error.localizedDescription
            }
        }
        let duplicate = message(#"{{1, 7, "w", 1, {"u"}, {"t"}}, {2, 7, "x", 1, {"v"}, {"s"}}}"#)
        XCTAssertTrue(duplicate.contains("changed while"), duplicate)
        XCTAssertTrue(duplicate.contains("run the command again"), duplicate)
        XCTAssertFalse(duplicate.contains("report it"), duplicate)

        // A real number (both spellings: osascript's and the daemon conversion's), including the
        // spec's 3.5 example, gets the 2^29 explanation and no rerun advice.
        for real in ["5.36870912E+8", "3.5", "«class doub»"] {
            let largeID = message("{{1, \(real), \"w\", 1, {\"u\"}, {\"t\"}}}")
            XCTAssertTrue(largeID.contains("536,870,911"), largeID)
            XCTAssertFalse(largeID.contains("run the command again"), largeID)
            XCTAssertFalse(largeID.contains("changed while"), largeID)
        }

        // Every other kind of window id is a shape problem: a boolean, raw data, a class, text, a list.
        for shape in [#"{{1, 7, "w", 1, {"u", "v"}, {"t"}}}"#, "", #"{{1, "7", "w", 1, {"u"}, {"t"}}}"#,
                      #"{{1, true, "w", 1, {"u"}, {"t"}}}"#, #"{{1, «data long05000000», "w", 1, {"u"}, {"t"}}}"#,
                      #"{{1, «class ????», "w", 1, {"u"}, {"t"}}}"#, #"{{1, {7}, "w", 1, {"u"}, {"t"}}}"#] {
            let text = message(shape)
            XCTAssertTrue(text.contains("could not be read") || text.contains("Could not read"), text)
            XCTAssertTrue(text.contains("run the command again") && text.contains("report it"), text)
            XCTAssertFalse(text.contains("changed while"), text)
        }
    }
}

