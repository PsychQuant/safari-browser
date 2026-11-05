import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #352 verify round 3. Same fake Safari as `WindowIDCommandTests`: window 101 in 個人, window 202 in Work.
final class WindowIDRound4Tests: XCTestCase, @unchecked Sendable {
    typealias Fake = WindowIDCommandTests.TwoProfileFake

    private func run<C: AsyncParsableCommand>(_ type: C.Type, _ args: [String], on fake: Fake,
                                              probe: @escaping @Sendable (BlockingDialogGate.WindowKey) -> BlockingDialogState = { _ in .clear }) async throws {
        var command = try C.parse(args)
        let context = DaemonRequestContext(probe: { key in probe(key) }, environment: [:])
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

    // MARK: finding 1 — every command that turns --profile into a window

    /// `concreteTarget` dropped the id the enumeration read, so a later Apple event looked the position up again.
    func testAProfileAloneKeepsTheEnumerationsWindowID() async throws {
        for (type, args) in [(OpenCommand.self as any AsyncParsableCommand.Type, ["https://n.example/", "--profile", "Work"]),
                             (OpenCommand.self, ["https://n.example/", "--replace-tab", "--profile", "Work"]),
                             (GetText.self, ["#sel", "--profile", "Work"]),
                             (GetHTML.self, ["#sel", "--profile", "Work"])] {
            let fake = Fake()
            do { try await run(type, args, on: fake) } catch {}
            XCTAssertFalse(acting(fake).isEmpty, "\(args):\n\(transcript(fake))")
            XCTAssertTrue(acting(fake).allSatisfy { $0.contains("window id 202") }, "\(args):\n\(transcript(fake))")
            XCTAssertFalse(acting(fake).contains { $0.contains("of window 2") }, "\(args):\n\(transcript(fake))")
        }
    }

    func testAWindowNumberWithAProfileKeepsTheEnumerationsWindowID() async throws {
        let fake = Fake()
        do { try await run(GetText.self, ["#sel", "--window", "1", "--profile", "Work"], on: fake) } catch {}
        XCTAssertFalse(acting(fake).isEmpty, transcript(fake))
        XCTAssertTrue(acting(fake).allSatisfy { $0.contains("window id 202") }, transcript(fake))
    }

    // MARK: finding 2 — `open` with a missing id

    func testOpenWithAMissingWindowIDIsATargetingMiss() async throws {
        for args in [["--window-id", "9999"], ["--window-id", "9999", "--tab-in-window", "1"],
                     ["--window-id", "9999", "--replace-tab"]] {
            let fake = Fake()
            do {
                try await run(OpenCommand.self, ["https://n.example/"] + args, on: fake)
                XCTFail("\(args) must fail")
            } catch let error as SafariBrowserError {
                guard case .documentNotFound = error else { return XCTFail("\(args): \(error)") }
            }
            XCTAssertEqual(acting(fake).count, 1, transcript(fake))
            let script = acting(fake)[0]
            let check = try XCTUnwrap(script.range(of: "get name of "), script)
            let navigate = try XCTUnwrap(script.range(of: "do JavaScript"), script)
            XCTAssertLessThan(check.lowerBound, navigate.lowerBound, script)
        }
    }

    /// The reference is what must exist: a window that is there with a tab that is not ends the same way.
    func testOpenWithAMissingTabIsATargetingMiss() async throws {
        for args in [["--window-id", "202", "--tab-in-window", "99"], ["--window-id", "202", "--tab-in-window", "99", "--replace-tab"]] {
            let fake = Fake()
            do {
                try await run(OpenCommand.self, ["https://n.example/"] + args, on: fake)
                XCTFail("\(args) must fail")
            } catch let error as SafariBrowserError {
                guard case .documentNotFound = error else { return XCTFail("\(args): \(error)") }
            }
        }
    }

    /// `--profile` collapses these to `.resolvedTab`; they take the same script as `--window-id`.
    func testOpenWithAProfileAndATabChecksTheTargetAndActivatesLast() async throws {
        for args in [["--url", "work.example/1", "--profile", "Work"], ["--window", "1", "--tab-in-window", "1", "--profile", "Work"]] {
            let fake = Fake()
            try await run(OpenCommand.self, ["https://n.example/"] + args, on: fake)
            let script = try XCTUnwrap(fake.scripts.first { $0.contains("window.location.href") }, transcript(fake))
            XCTAssertFalse(script.contains("make new document"), "\(args):\n\(script)")
            let check = try XCTUnwrap(script.range(of: "get name of "), script)
            let navigate = try XCTUnwrap(script.range(of: "do JavaScript"), script)
            let activate = try XCTUnwrap(script.range(of: "activate"), script)
            XCTAssertLessThan(check.lowerBound, navigate.lowerBound, script)
            XCTAssertLessThan(navigate.lowerBound, activate.lowerBound, script)
        }
    }

    /// With `--profile` the flags have collapsed to `.resolvedTab`; the navigation is the same script.
    func testOpenWithAWindowIDATabAndAProfileNeverMakesANewWindowAndActivatesLast() async throws {
        let fake = Fake()
        try await run(OpenCommand.self, ["https://n.example/", "--window-id", "202", "--tab-in-window", "1", "--profile", "Work"], on: fake)
        let script = try XCTUnwrap(fake.scripts.first { $0.contains("window.location.href") }, transcript(fake))
        XCTAssertFalse(script.contains("make new document"), script)
        let navigate = try XCTUnwrap(script.range(of: "do JavaScript"), script)
        let activate = try XCTUnwrap(script.range(of: "activate"), script)
        XCTAssertLessThan(navigate.lowerBound, activate.lowerBound, script)
    }

    func testOpenWithAURLFlagThatMatchesNothingFails() async throws {
        let fake = Fake()
        do {
            try await run(OpenCommand.self, ["https://n.example/", "--url-exact", "https://nope.example/"], on: fake)
            XCTFail("no tab matches")
        } catch SafariBrowserError.documentNotFound {}
        XCTAssertFalse(fake.scripts.contains { $0.contains("make new tab") }, transcript(fake))
    }

    // MARK: finding 3 — a miss without --profile lists no window

    func testAMissOnTheEnumeratingPathsListsNoOtherWindow() async throws {
        for (type, args) in [(TabsCommand.self as any AsyncParsableCommand.Type, ["--window-id", "9999"]),
                             (TabSwitchCommand.self, ["2", "--window-id", "9999"]),
                             (TabSwitchCommand.self, ["new", "--window-id", "9999"]),
                             (TabFocusCommand.self, ["--window-id", "9999"]),
                             (OpenCommand.self, ["https://n.example/", "--new-tab", "--window-id", "9999"])] {
            let fake = Fake()
            do {
                try await run(type, args, on: fake)
                XCTFail("\(args) must fail")
            } catch let error as SafariBrowserError {
                guard case .documentNotFound = error else { return XCTFail("\(args): \(error)") }
                let text = error.localizedDescription
                XCTAssertFalse(text.contains("own.example") || text.contains("work.example"), "\(args):\n\(text)")
            }
        }
    }

    // MARK: LOW — a window lost after the check

    func testTabFocusReportsAWindowClosedAfterTheCheckAsATargetingMiss() async throws {
        let fake = Fake()
        fake.closesAfterFirstListing = 202
        do {
            try await run(TabFocusCommand.self, ["--window-id", "202", "--tab-in-window", "2"], on: fake)
            XCTFail("window 202 closed")
        } catch SafariBrowserError.documentNotFound {}
    }

    func testTabsReportsAWindowClosedAfterTheCheckAsATargetingMiss() async throws {
        let fake = Fake()
        fake.closesAfterFirstListing = 202
        do {
            try await run(TabsCommand.self, ["--window-id", "202"], on: fake)
            XCTFail("window 202 closed")
        } catch SafariBrowserError.documentNotFound {}
    }

    /// `readTabs` answers "0" when no window is open, which is not "a window with no tabs" for a named window.
    func testTabsReportsTheLastWindowClosingAfterTheCheckAsATargetingMiss() async throws {
        final class Empty: Fake, @unchecked Sendable {
            override func respond(_ script: String) throws -> String {
                if script.contains("count of tabs of window id 202"), !script.contains("set windowCount") { return "0" }
                return try super.respond(script)
            }
        }
        let fake = Empty()
        fake.closesAfterFirstListing = 202
        do {
            try await run(TabsCommand.self, ["--window-id", "202"], on: fake)
            XCTFail("window 202 closed")
        } catch SafariBrowserError.documentNotFound {}
    }

    func testTabsRejectsTabInWindow() {
        XCTAssertThrowsError(try TabsCommand.parse(["--window-id", "202", "--tab-in-window", "1"]))
        XCTAssertThrowsError(try TabsCommand.parse(["--window", "1", "--tab-in-window", "1"]))
    }

    // MARK: LOW — the hint and the dialog probe

    /// A `.resolvedTab` miss is described as `window id W tab T` too, but its listing has coordinates.
    func testTheHintFollowsTheListingNotOnlyThePattern() {
        let coordinates = SafariBrowserError.documentNotFound(
            pattern: "window id 202 tab 1", availableDocuments: ["window 1 tab 1: https://own.example/1"]).localizedDescription
        XCTAssertTrue(coordinates.contains("--window N --tab-in-window M"), coordinates)
        let ids = SafariBrowserError.documentNotFound(
            pattern: "window id 9999 (profile: \"Work\")", availableDocuments: ["window id 202: https://work.example/1"]).localizedDescription
        XCTAssertTrue(ids.contains("--window-id"), ids)
    }

    /// A live window named by id keeps the warning every other target gets: the probe runs before the script, so it
    /// cannot tell a stale id from a live one, and hiding the line for both hid it for the window it was meant for.
    func testAWindowIDKeepsTheProbeWarning() async throws {
        let fake = Fake()
        var command = try GetURL.parse(["--window-id", "101"])
        let context = DaemonRequestContext(probe: { _ in .unprobed }, environment: [:])
        do {
            try await DaemonRequestContext.$current.withValue(context) {
                try await WindowDialogObservation.$provider.withValue({ WindowDialogObservation.unavailable(reason: "test") }) {
                    try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                        try await command.run()
                    }
                }
            }
        } catch {}
        XCTAssertTrue(context.diagnostics.joined().contains("dialog probe"), "\(context.diagnostics)")
    }

    /// The native resolver's listing for a lost `.resolvedTab` stays within the profile it carries.
    func testALostResolvedTabWithNoWindowOfItsProfileSaysSo() {
        let own = SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1,
            tabs: [SafariBridge.TabInWindow(tabIndex: 1, url: "https://own.example/1", title: "t", isCurrent: true)],
            profile: "個人", windowID: 101)
        XCTAssertThrowsError(try SafariBridge.pickNativeTarget(
            .resolvedTab(windowID: 202, tabInWindow: 1, rematch: nil, profile: "Work"), in: [own])) { error in
            let text = (error as? SafariBrowserError)?.localizedDescription ?? ""
            XCTAssertFalse(text.contains("no Safari documents are currently open"), text)
            XCTAssertTrue(text.contains("Work"), text)
        }
    }

    func testALostResolvedTabListsOnlyItsProfile() {
        let own = SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1,
            tabs: [SafariBridge.TabInWindow(tabIndex: 1, url: "https://own.example/1", title: "t", isCurrent: true)],
            profile: "個人", windowID: 101)
        XCTAssertThrowsError(try SafariBridge.pickNativeTarget(
            .resolvedTab(windowID: 202, tabInWindow: 1, rematch: nil, profile: "Work"), in: [own])) { error in
            guard case SafariBrowserError.documentNotFound(_, let available) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(available.joined().contains("own.example"), "\(available)")
        }
    }
}
