import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #362 item 3: `tabs` reports the window it resolved closing during the command as a targeting miss, keyed on the
/// resolved window id rather than on the flag typed.
final class TabsClosedWindowTests: XCTestCase, @unchecked Sendable {
    private func tabs(_ args: [String], on fake: FakeSafari) async throws {
        var command = try TabsCommand.parse(args)
        try await fake.drive { try await command.run() }
    }

    func testTabsReportsTheResolvedWindowClosingAsATargetingMiss() async throws {
        let shapes: [(args: [String], windows: [FakeSafari.Window], closes: Int, typed: String)] = [
            (["--profile", "Work"], [(303, "Work", ["https://work.example/a1"])], 303, "--profile \"Work\""),
            (["--profile", "Work"], FakeSafari.workIsTwoAndThree, 303, "--profile \"Work\""),
            (["--window", "2", "--profile", "Work"], FakeSafari.workIsTwoAndThree, 404, "--window 2 --profile \"Work\""),
            (["--window", "1"], [(303, "Work", ["https://work.example/a1"])], 303, "--window 1"),
            (["--window", "2"], FakeSafari.workIsTwoAndThree, 303, "--window 2"),
        ]
        for shape in shapes {
            let fake = FakeSafari(windows: shape.windows)
            fake.closesOnRead = shape.closes
            do {
                try await tabs(shape.args, on: fake)
                XCTFail("\(shape.args): window \(shape.closes) closed")
            } catch SafariBrowserError.documentNotFound(let pattern, let entries) {
                XCTAssertTrue(pattern.contains("window id \(shape.closes)"), "\(shape.args): \(pattern)")
                XCTAssertTrue(pattern.contains(shape.typed), "\(shape.args): \(pattern)")
                XCTAssertTrue(pattern.contains("closed during the command"), "\(shape.args): \(pattern)")
                XCTAssertFalse(entries.joined().contains("home.example"), "\(shape.args): \(entries)")
            } catch {
                XCTFail("\(shape.args): \(error)")
            }
        }
    }

    /// No window was named: the front window's list is what was asked for, and an empty Safari has none.
    func testTabsWithNoFlagAndNoWindowsStillPrintsNothing() async throws {
        let fake = FakeSafari(windows: [])
        try await tabs([], on: fake)
    }

    func testTabsWithAWindowNumberThatIsNotOpenIsATargetingMiss() async throws {
        let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
        do {
            try await tabs(["--window", "9"], on: fake)
            XCTFail("window 9 is not open")
        } catch SafariBrowserError.documentNotFound(let pattern, _) {
            XCTAssertTrue(pattern.hasPrefix("window 9"), pattern)
        }
    }

    /// An error that is not "object not found" is not a closed window: it reaches the caller unchanged.
    func testTabsPassesOtherReadErrorsThrough() async throws {
        let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
        fake.readError = SafariBrowserError.processTimedOut(command: "osascript", seconds: 3)
        do {
            try await tabs(["--window", "2"], on: fake)
            XCTFail("the read timed out")
        } catch SafariBrowserError.processTimedOut {}
        XCTAssertEqual(fake.listings, 0)
    }
}
