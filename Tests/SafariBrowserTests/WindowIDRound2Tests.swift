import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #352 verify round 1: commands and error paths the first implementation missed. Same fake Safari as
/// `WindowIDCommandTests` (window 101 in 個人 with `own.example/1…3`, window 202 in Work with `work.example/1…2`).
final class WindowIDRound2Tests: XCTestCase, @unchecked Sendable {
    typealias Fake = WindowIDCommandTests.TwoProfileFake

    private func run<C: AsyncParsableCommand>(_ type: C.Type, _ args: [String], on fake: Fake) async throws {
        var command = try C.parse(args)
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        try await DaemonRequestContext.$current.withValue(context) {
            try await WindowDialogObservation.$provider.withValue({ WindowDialogObservation.unavailable(reason: "test") }) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                    try await command.run()
                }
            }
        }
    }

    private func acting(_ fake: Fake) -> [String] { fake.scripts.filter { !$0.contains("set windowCount") } }
    private func transcript(_ fake: Fake) -> String { fake.scripts.joined(separator: "\n---\n") }

    // MARK: finding 1 — `tab <N>` / `tab new`

    func testTabSwitchUsesTheWindowByID() async throws {
        let fake = Fake()
        try await run(TabSwitchCommand.self, ["2", "--window-id", "202"], on: fake)
        let sent = acting(fake)
        XCTAssertEqual(sent.count, 1, transcript(fake))
        XCTAssertTrue(sent[0].contains("set current tab of window id 202 to tab 2 of window id 202"), transcript(fake))
        XCTAssertFalse(fake.scripts.contains { $0.contains("front window") }, transcript(fake))
    }

    /// Like `open --new-tab --window-id`: no `activate`, the new tab is still made current.
    func testTabNewUsesTheWindowByIDWithoutActivating() async throws {
        let fake = Fake()
        try await run(TabSwitchCommand.self, ["new", "--window-id", "202"], on: fake)
        let sent = acting(fake)
        XCTAssertEqual(sent.count, 1, transcript(fake))
        XCTAssertTrue(sent[0].contains("tell window id 202"), transcript(fake))
        XCTAssertTrue(sent[0].contains("set current tab to newTab"), transcript(fake))
        XCTAssertFalse(sent[0].contains("activate"), transcript(fake))
        XCTAssertFalse(fake.scripts.contains { $0.contains("front window") }, transcript(fake))
    }

    func testTabFailsClosedForAMissingIDOrAnotherProfilesWindow() async throws {
        for args in [["2", "--window-id", "9999"], ["new", "--window-id", "9999"],
                     ["2", "--window-id", "202", "--profile", "個人"], ["new", "--window-id", "202", "--profile", "個人"]] {
            let fake = Fake()
            do {
                try await run(TabSwitchCommand.self, args, on: fake)
                XCTFail("\(args) must fail")
            } catch SafariBrowserError.documentNotFound {}
            XCTAssertEqual(acting(fake), [], "\(args): nothing may be switched or opened:\n\(transcript(fake))")
        }
    }

    /// `tab --profile P` used to act on a window position looked up again in a later Apple event (the #351 class); it
    /// now uses the id the enumeration read.
    func testTabWithAProfileUsesTheEnumerationsWindowID() async throws {
        for args in [["2", "--profile", "Work"], ["new", "--profile", "Work"]] {
            let fake = Fake()
            try await run(TabSwitchCommand.self, args, on: fake)
            let sent = acting(fake)
            XCTAssertEqual(sent.count, 1, transcript(fake))
            XCTAssertTrue(sent[0].contains("window id 202"), "\(args):\n\(transcript(fake))")
            XCTAssertFalse(sent[0].contains("front window"), "\(args):\n\(transcript(fake))")
        }
    }

    func testTabRejectsTheFlagsThatNameATab() {
        for args in [["--url", "x"], ["--url-exact", "https://x/"], ["--url-endswith", "/x"], ["--url-regex", "x"],
                     ["--tab", "1"], ["--document", "1"], ["--window", "1", "--tab-in-window", "1"]] {
            XCTAssertThrowsError(try TabSwitchCommand.parse(["2"] + args), "\(args)") { error in
                XCTAssertTrue(TabSwitchCommand.message(for: error).contains("--window-id"), "\(args)")
            }
        }
    }

    /// `tab focus` switched by the window's z-order position after resolving it; now by the resolved id.
    func testTabFocusSwitchesByTheResolvedWindowID() async throws {
        let fake = Fake()
        try await run(TabFocusCommand.self, ["--window-id", "101", "--tab-in-window", "2"], on: fake)
        let switches = fake.scripts.filter { $0.contains("set current tab of") }
        XCTAssertEqual(switches.count, 1, transcript(fake))
        XCTAssertTrue(switches[0].contains("set current tab of window id 101 to tab 2 of window id 101"), transcript(fake))
    }

    // MARK: findings 2, 3 — `open` with a missing id

    func testOpenNewTabWithAMissingIDIsATargetingMiss() async throws {
        let fake = Fake()
        do {
            try await run(OpenCommand.self, ["https://n.example/", "--new-tab", "--window-id", "9999"], on: fake)
            XCTFail("a missing window id must fail")
        } catch SafariBrowserError.documentNotFound {}
        XCTAssertFalse(fake.scripts.contains { $0.contains("make new tab") }, transcript(fake))
    }

    /// With no window open, the navigation script made a new window; a window id names a window that must exist.
    func testOpenWithAWindowIDNeverMakesANewWindow() async throws {
        let fake = Fake()
        try await run(OpenCommand.self, ["https://n.example/", "--window-id", "202"], on: fake)
        let navigations = fake.scripts.filter { $0.contains("window.location.href") }
        XCTAssertEqual(navigations.count, 1, transcript(fake))
        XCTAssertFalse(navigations[0].contains("make new document"), transcript(fake))
    }

    // MARK: finding 4 — js / wait target-changed messages

    func testJSTargetChangedNamesTheWindowByID() {
        let changed = SafariBrowserError.appleScriptFailed("execution error: SB_TARGET_CHANGED (9001)")
        let mapped = JSCommand.anchoredFailure(changed, original: .windowID(202),
                                               anchored: .anchoredCurrentTab(windowID: 202, tabInWindow: 1, profile: nil))
        guard case .anchoredTargetChanged(let target) = mapped else { return XCTFail("\(mapped)") }
        XCTAssertTrue(target.contains("window id 202"), target)
        XCTAssertFalse(target.contains("front window"), target)

        // A tab that vanished mid-command: the window was checked at command start.
        let missing = SafariBrowserError.documentNotFound(pattern: "x", availableDocuments: ["https://work.example/1"])
        let tabMapped = JSCommand.anchoredFailure(missing, original: .windowID(202, tabInWindow: 2),
                                                  anchored: .resolvedTab(windowID: 202, tabInWindow: 2, rematch: nil, profile: nil))
        guard case .anchoredTargetChanged(let tabTarget) = tabMapped else { return XCTFail("a vanished tab must not list every tab: \(tabMapped)") }
        XCTAssertTrue(tabTarget.contains("window id 202 tab 2"), tabTarget)
    }

    func testWaitTargetChangedNamesTheWindowByID() {
        let text = WaitCommand.describe(.windowID(202), .anchoredCurrentTab(windowID: 202, tabInWindow: 1, profile: nil))
        XCTAssertTrue(text.contains("window id 202"), text)
    }

    // MARK: finding 5 — profile with no window

    func testAProfileWithNoWindowListsNoOtherProfilesTabs() async throws {
        let fake = Fake()
        do {
            try await run(GetURL.self, ["--window-id", "202", "--profile", "Nobody"], on: fake)
            XCTFail("no window of Nobody is open")
        } catch let error as SafariBrowserError {
            guard case .documentNotFound = error else { return XCTFail("\(error)") }
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("own.example") || text.contains("work.example"), text)
        }
    }

    // MARK: finding 9 — zero-tab window and the tab range on the profile path

    func testAWindowWithNoTabsResolvesWithoutATab() throws {
        let empty = SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1, tabs: [], profile: "個人", windowID: 303)
        let resolved = try SafariBridge.pickNativeTarget(.windowID(303), in: [empty])
        XCTAssertEqual(resolved.windowID, 303)
        XCTAssertNil(resolved.anchorTabIndex)
        XCTAssertNil(resolved.tabIndexInWindow)
    }

    func testATabOutOfRangeOnTheProfilePathFailsWithThatWindowsTabsOnly() async throws {
        let fake = Fake()
        do {
            try await run(GetURL.self, ["--window-id", "101", "--tab-in-window", "9", "--profile", "個人"], on: fake)
            XCTFail("window 101 has three tabs")
        } catch let error as SafariBrowserError {
            guard case .documentNotFound = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains("own.example"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("work.example"), error.localizedDescription)
        }
        XCTAssertEqual(acting(fake), [], transcript(fake))
    }
}
