import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #353 / #348: `close` closes the tab the resolution named, in one Apple event that names the window by its
/// id, and never makes another tab current on the way.
final class WindowLevelCloseTests: XCTestCase {

    private typealias Fake = WindowLevelFakeSafari

    /// Runs `close` with `args` and requires it to succeed with exactly one tab closed, by one close script,
    /// with no tab made current.
    @discardableResult
    private func closes(
        _ args: [String], windowID: Int, tab: Int, url: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Fake {
        let fake = Fake()
        let error = await fake.run(CloseCommand.self, args)
        XCTAssertNil(error, "close \(args): \(String(describing: error))\n\(fake.transcript)", file: file, line: line)
        XCTAssertEqual(fake.actions, [.closed(windowID: windowID, tab: tab, url: url)],
                       "close \(args)\n\(fake.transcript)", file: file, line: line)
        XCTAssertEqual(fake.scripts.filter { $0.contains("close ") }.count, 1,
                       "one close script:\n\(fake.transcript)", file: file, line: line)
        XCTAssertFalse(fake.scripts.contains { $0.contains("set current tab") },
                       "close must not switch tabs:\n\(fake.transcript)", file: file, line: line)
        return fake
    }

    // spec-example: navigation / which tab close closes
    func testWhichTabCloseCloses() async {
        await closes([], windowID: 4711, tab: 1, url: "https://home.example/1")
        await closes(["--window", "2"], windowID: 5822, tab: 1, url: "https://work.example/a1")

        // A background tab found by its URL: closed, and the tab the user was looking at stays current (#348).
        let byURL = await closes(["--url", "work.example/a2"], windowID: 5822, tab: 2, url: "https://work.example/a2")
        XCTAssertEqual(byURL.window(id: 5822)?.current, 1)
        XCTAssertEqual(byURL.window(id: 5822)?.tabs, ["https://work.example/a1"])
        XCTAssertTrue(byURL.scripts.last?.contains("set _t to tab 2 of window id 5822") == true, byURL.transcript)

        let byPosition = await closes(["--window-id", "4711", "--tab-in-window", "3"],
                                      windowID: 4711, tab: 3, url: "https://home.example/3")
        XCTAssertEqual(byPosition.window(id: 4711)?.current, 1)

        let byDocument = await closes(["--document", "5"], windowID: 5822, tab: 2, url: "https://work.example/a2")
        XCTAssertEqual(byDocument.window(id: 5822)?.current, 1)

        // The tab found by its URL shows something else by the time the close script runs: nothing closes.
        let moved = Fake()
        moved.after(script: 1) { $0[1].tabs[1] = "https://other.example/" }
        let error = await moved.run(CloseCommand.self, ["--url", "work.example/a2"])
        guard case SafariBrowserError.targetChangedBeforeActing? = error else {
            return XCTFail("expected targetChangedBeforeActing, got \(String(describing: error))\n\(moved.transcript)")
        }
        XCTAssertEqual(moved.actions, [])
        XCTAssertEqual(moved.window(id: 5822)?.current, 1)
        XCTAssertEqual(moved.scripts.count, 2, "one enumeration, one close script, no second resolution:\n\(moved.transcript)")
    }

    /// The scenario of #348 as the old code handled it: the user's current tab was changed and then
    /// "the current tab" was closed. With a tab closing to the left in between, that was another tab.
    func testATabThatSlidIntoThePositionIsNotClosed() async {
        let fake = Fake()
        // After the enumeration, tab 1 of window id 5822 closes, so position 1 now shows a2 and position 2 is gone.
        fake.after(script: 1) { $0[1].tabs.removeFirst() }
        let error = await fake.run(CloseCommand.self, ["--url", "work.example/a2"])
        guard case SafariBrowserError.documentNotFound? = error else {
            return XCTFail("tab 2 is gone: expected documentNotFound, got \(String(describing: error))\n\(fake.transcript)")
        }
        XCTAssertEqual(fake.closed, [], "nothing may close when the position no longer holds the tab")
    }

    // spec-example: document-targeting / close with each targeting flag
    func testCloseWithEachTargetingFlag() async {
        await closes(["--url", "work.example/a2"], windowID: 5822, tab: 2, url: "https://work.example/a2")
        await closes(["--document", "4"], windowID: 5822, tab: 1, url: "https://work.example/a1")
        await closes(["--tab", "6"], windowID: 6933, tab: 1, url: "https://work.example/b1")
        await closes(["--window", "3"], windowID: 6933, tab: 1, url: "https://work.example/b1")
        await closes(["--window-id", "4711", "--tab-in-window", "3"], windowID: 4711, tab: 3, url: "https://home.example/3")
    }

    // spec-example: document-targeting / window-level commands with a window id
    func testWindowLevelCommandsWithAWindowID() async {
        let current = await closes(["--window-id", "5822"], windowID: 5822, tab: 1, url: "https://work.example/a1")
        XCTAssertTrue(current.scripts.last?.contains("close current tab of window id 5822") == true, current.transcript)
        XCTAssertFalse(current.scripts.contains(where: Fake.namesAPosition), current.transcript)

        let second = await closes(["--window-id", "5822", "--tab-in-window", "2"],
                                  windowID: 5822, tab: 2, url: "https://work.example/a2")
        XCTAssertEqual(second.window(id: 5822)?.current, 1)
        XCTAssertTrue(second.scripts.last?.contains("set _t to tab 2 of window id 5822") == true, second.transcript)
        XCTAssertFalse(second.scripts.last?.contains("SB_TARGET_CHANGED") == true, "a position is not checked by URL")
        XCTAssertFalse(second.scripts.contains(where: Fake.namesAPosition), second.transcript)

        for args in [["--window-id", "9999"], ["--window-id", "5822", "--tab-in-window", "9"],
                     ["--window-id", "4711", "--profile", "Work"]] {
            let fake = Fake()
            let error = await fake.run(CloseCommand.self, args)
            guard case SafariBrowserError.documentNotFound? = error else {
                XCTFail("close \(args): expected documentNotFound, got \(String(describing: error))\n\(fake.transcript)")
                continue
            }
            XCTAssertEqual(fake.actions, [], "close \(args) must close nothing")
        }
    }

    func testCloseInAWindowThatHasNoTabSaysSoAndClosesNothing() async {
        var windows = Fake.threeWindows
        windows[1].tabs = []
        let fake = Fake(windows: windows)
        let error = await fake.run(CloseCommand.self, ["--window-id", "5822"])
        guard case SafariBrowserError.appleScriptFailed(let message)? = error else {
            return XCTFail("expected the no-tabs error, got \(String(describing: error))\n\(fake.transcript)")
        }
        XCTAssertTrue(message.contains("window id 5822 has no tabs — nothing to close"), message)
        XCTAssertEqual(fake.actions, [])
    }

    /// The zero-tab check stays in front of the close in the form that names a tab too (#93).
    func testTheTabFormKeepsBothChecksInFrontOfTheClose() throws {
        let script = SafariBridge.closeTabScript(
            windowReference: "window id 5822", tab: 2,
            guardClause: SafariBridge.tabGuardClause(named: .urlMatch(.contains("a2")), matchedURL: "https://work.example/a2"))
        let noWindows = try XCTUnwrap(script.range(of: "if (count of windows) = 0 then"))
        let noTabs = try XCTUnwrap(script.range(of: "if (count of tabs of window id 5822) = 0 then"))
        let bind = try XCTUnwrap(script.range(of: "set _t to tab 2 of window id 5822"))
        let check = try XCTUnwrap(script.range(of: "SB_TARGET_CHANGED"))
        let close = try XCTUnwrap(script.range(of: "close _t"))
        XCTAssertTrue(noWindows.lowerBound < noTabs.lowerBound)
        XCTAssertTrue(noTabs.lowerBound < bind.lowerBound)
        XCTAssertTrue(bind.lowerBound < check.lowerBound)
        XCTAssertTrue(check.lowerBound < close.lowerBound)
        XCTAssertFalse(script.contains("set current tab"))
        // Without a tab it is the script that names the window's current tab, text unchanged.
        XCTAssertEqual(SafariBridge.closeTabScript(windowReference: "window id 5822", tab: nil, guardClause: nil),
                       SafariBridge.closeCurrentTabScript(windowRef: "window id 5822"))
    }
}
