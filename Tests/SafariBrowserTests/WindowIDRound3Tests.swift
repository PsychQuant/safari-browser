import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #352 verify round 2. `--window-id W --tab-in-window T` used to resolve straight to `.resolvedTab`, which every consumer
/// treats as already checked, so a missing window or tab went unnoticed until the first action. Same fake Safari as
/// `WindowIDCommandTests`: window 101 in 個人 with three tabs, window 202 in Work with two.
final class WindowIDRound3Tests: XCTestCase, @unchecked Sendable {
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

    // MARK: finding 1 — `open` with a tab must not make a new window

    func testOpenWithAWindowIDAndATabNeverMakesANewWindow() async throws {
        for extra in [[], ["--replace-tab"]] {
            let fake = Fake()
            try await run(OpenCommand.self, ["https://n.example/", "--window-id", "202", "--tab-in-window", "1"] + extra, on: fake)
            let navigations = fake.scripts.filter { $0.contains("window.location.href") }
            XCTAssertEqual(navigations.count, 1, transcript(fake))
            XCTAssertTrue(navigations[0].contains("tab 1 of window id 202"), transcript(fake))
            XCTAssertFalse(navigations[0].contains("make new document"), transcript(fake))
        }
    }

    /// A command that fails closed must not bring Safari forward first.
    func testOpenWithAWindowIDActivatesOnlyAfterNavigating() async throws {
        let fake = Fake()
        try await run(OpenCommand.self, ["https://n.example/", "--window-id", "202"], on: fake)
        let script = try XCTUnwrap(fake.scripts.first { $0.contains("window.location.href") }, transcript(fake))
        let navigate = try XCTUnwrap(script.range(of: "do JavaScript"), script)
        let activate = try XCTUnwrap(script.range(of: "activate"), script)
        XCTAssertLessThan(navigate.lowerBound, activate.lowerBound, script)
    }

    // MARK: finding 2 — a miss is a targeting miss, not "changed mid-command"

    private func assertTargetingMiss<C: AsyncParsableCommand>(_ type: C.Type, _ args: [String],
                                                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let fake = Fake()
        do {
            try await run(type, args, on: fake)
            XCTFail("\(args) must fail", file: file, line: line)
        } catch let error as SafariBrowserError {
            guard case .documentNotFound = error else { return XCTFail("\(args): \(error)", file: file, line: line) }
            XCTAssertTrue(error.localizedDescription.hasPrefix("No Safari document matches"), error.localizedDescription, file: file, line: line)
        }
        XCTAssertFalse(fake.scripts.contains { $0.contains("do JavaScript") }, transcript(fake), file: file, line: line)
    }

    func testAMissingWindowOrTabIsATargetingMissForJSWaitAndSavePDF() async throws {
        let save = FileManager.default.temporaryDirectory.appendingPathComponent("r3-\(UUID().uuidString).pdf").path
        for target in [["--window-id", "9999", "--tab-in-window", "2"], ["--window-id", "101", "--tab-in-window", "9"]] {
            try await assertTargetingMiss(JSCommand.self, target + ["1"])
            try await assertTargetingMiss(WaitCommand.self, target + ["--for-url", "x", "--timeout", "0"])
            try await assertTargetingMiss(WaitCommand.self, target + ["--js", "1", "--timeout", "0"])
            try await assertTargetingMiss(SavePDFCommand.self, [save] + target)
        }
    }

    func testJSWithAValidTabRunsThere() async throws {
        let fake = Fake()
        do { try await run(JSCommand.self, ["--window-id", "101", "--tab-in-window", "3", "1"], on: fake) } catch {}
        let dispatches = fake.scripts.filter { $0.contains("do JavaScript") }
        XCTAssertFalse(dispatches.isEmpty, transcript(fake))
        XCTAssertTrue(dispatches.allSatisfy { $0.contains("tab 3 of window id 101") }, transcript(fake))
    }

    /// The native resolver checks the range too, so `tab focus` never sends a switch to a tab that does not exist.
    func testTabFocusRejectsATabOutOfRange() async throws {
        let fake = Fake()
        do {
            try await run(TabFocusCommand.self, ["--window-id", "101", "--tab-in-window", "9"], on: fake)
            XCTFail("window 101 has three tabs")
        } catch SafariBrowserError.documentNotFound {}
        XCTAssertFalse(fake.scripts.contains { $0.contains("set current tab") }, transcript(fake))
    }

    // MARK: finding 4 — `--profile` keeps following the current tab

    func testAWindowIDWithAProfileStaysTheWindowsCurrentTab() async throws {
        let fake = Fake()
        try await run(GetURL.self, ["--window-id", "101", "--profile", "個人"], on: fake)
        let reads = acting(fake)
        XCTAssertFalse(reads.isEmpty, transcript(fake))
        XCTAssertTrue(reads.allSatisfy { $0.contains("document of window id 101") }, transcript(fake))
    }

    // MARK: the window closes between the check and the action

    func testAWindowClosedAfterTheCheckIsATargetingMiss() async throws {
        for (type, args) in [(TabSwitchCommand.self as any AsyncParsableCommand.Type, ["2", "--window-id", "202"]),
                             (TabSwitchCommand.self, ["new", "--window-id", "202"]),
                             (OpenCommand.self, ["https://n.example/", "--new-tab", "--window-id", "202"])] {
            let fake = Fake()
            fake.closesAfterFirstListing = 202
            do {
                try await run(type, args, on: fake)
                XCTFail("\(args): window 202 closed")
            } catch SafariBrowserError.documentNotFound {
            } catch {
                XCTFail("\(args): expected documentNotFound, got \(error)")
            }
        }
    }

    /// `tab <N>` still reports a bad number when the window is there.
    func testTabOutOfRangeInAWindowThatExistsIsStillAnInvalidTabIndex() async throws {
        final class Refusing: Fake, @unchecked Sendable {
            override func respond(_ script: String) throws -> String {
                if script.contains("set current tab of") {
                    throw SafariBrowserError.appleScriptFailed("execution error: Can’t get tab 9. Invalid index. (-1719)")
                }
                return try super.respond(script)
            }
        }
        do {
            try await run(TabSwitchCommand.self, ["9", "--window-id", "202"], on: Refusing())
            XCTFail("window 202 has two tabs")
        } catch SafariBrowserError.invalidTabIndex(let index) {
            XCTAssertEqual(index, 9)
        }
    }

    /// The translation of a window lost mid-command stays within `--profile`, on both shapes: `get url` keeps `.windowID`
    /// (a miss lists nothing), and `get text` resolves through `resolveProfileScoped` to `.resolvedTab(profile:)`, whose
    /// listing is filtered.
    func testAWindowClosedAfterTheProfileCheckListsNoOtherProfilesTabs() async throws {
        let args = ["--window-id", "202", "--tab-in-window", "1", "--profile", "Work"]
        for (type, arguments) in [(GetURL.self as any AsyncParsableCommand.Type, args), (GetText.self, ["#sel"] + args)] {
            let fake = Fake()
            fake.closesAfterFirstListing = 202
            do {
                try await run(type, arguments, on: fake)
                XCTFail("\(arguments): window 202 closed")
            } catch let error as SafariBrowserError {
                guard case .documentNotFound = error else { return XCTFail("\(arguments): \(error)") }
                XCTAssertFalse(error.localizedDescription.contains("own.example"), error.localizedDescription)
            }
        }
    }

    // MARK: finding 28 — the hint

    func testAWindowIDMissPointsAtWindowIDsNotPositions() {
        let text = SafariBrowserError.documentNotFound(
            pattern: "window id 4711 (profile: \"Work\")",
            availableDocuments: ["(no window of profile \"Work\" is open)"]).localizedDescription
        XCTAssertTrue(text.contains("--window-id"), text)
        XCTAssertFalse(text.contains("--window N"), text)
        XCTAssertFalse(text.contains(URLText.shortenedNote), "no URL is listed:\n\(text)")
    }
}
