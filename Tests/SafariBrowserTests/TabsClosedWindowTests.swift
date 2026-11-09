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

    /// #362 verify r2 F (finding 20): a window named by id that closes keeps the miss `--window-id` gives (#352),
    /// which names the id; the rewording for a window resolved from `--window N` or `--profile` does not apply.
    func testTabsWithAWindowIDThatClosesNamesThatID() async throws {
        for (args, expected) in [(["--window-id", "303"], "window id 303"),
                                 (["--window-id", "303", "--profile", "Work"], "window id 303 (profile: \"Work\")")] {
            let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
            fake.closesOnRead = 303
            do {
                try await tabs(args, on: fake)
                XCTFail("\(args): window 303 closed")
            } catch SafariBrowserError.documentNotFound(let pattern, _) {
                XCTAssertEqual(pattern, expected, "\(args)")
            }
        }
    }

    /// No window was named: the front window's list is what was asked for, and an empty Safari has none.
    func testTabsWithNoFlagAndNoWindowsStillPrintsNothing() async throws {
        let fake = FakeSafari(windows: [])
        try await tabs([], on: fake)
    }

    /// Verify F5/F7: with no Safari window, `tabs --window 1` is a miss whose listing is empty, and the hint does
    /// not describe entries that are not there.
    func testTabsWithAWindowNumberAndNoWindowIsAMissThatListsNothing() async throws {
        let fake = FakeSafari(windows: [])
        do {
            try await tabs(["--window", "1", "--json"], on: fake)
            XCTFail("no window is open")
        } catch let error as SafariBrowserError {
            guard case .documentNotFound(let pattern, let entries) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(pattern, "window 1")
            XCTAssertEqual(entries, [])
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("each entry above"), message)
            XCTAssertTrue(message.contains("no Safari documents are currently open"), message)
        }
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

    /// An error that is not "object not found" is not a closed window: it reaches the caller unchanged, for a window
    /// named by number and by id (verify F1), even when the window did close before the read. Only the resolver
    /// enumerates: `--window N` reads the id it names and lists nothing, `--window-id` resolves through one
    /// enumeration.
    func testTabsPassesOtherReadErrorsThrough() async throws {
        let errors: [SafariBrowserError] = [
            .processTimedOut(command: "osascript", seconds: 3),
            .appleScriptFailed("execution error: something went wrong"),
        ]
        for (args, listings) in [(["--window", "2"], 0), (["--window-id", "303"], 1)] {
            for readError in errors {
                let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
                fake.closesOnRead = 303
                fake.readError = readError
                do {
                    try await tabs(args, on: fake)
                    XCTFail("\(args): the read failed")
                } catch let error as SafariBrowserError {
                    XCTAssertEqual("\(error)", "\(readError)", "\(args)")
                }
                XCTAssertEqual(fake.listings, listings, "\(args): \(readError)")
            }
        }
    }

    /// Verify F4: the read failed with object-not-found, and the enumeration that would check whether the window
    /// closed failed too. Nothing then says the window closed, so the caller gets the read error, not the
    /// enumeration's. Each shape lets the resolver's own enumeration succeed and fails the re-check's.
    func testTabsKeepsTheReadErrorWhenTheRecheckCannotListTheWindows() async throws {
        let readError = SafariBrowserError.appleScriptFailed("execution error: Can’t get window id 303. (-1728)")
        for (args, recheck) in [(["--window", "2"], 1), (["--window-id", "303"], 2), (["--profile", "Work"], 2)] {
            let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
            fake.readError = readError
            fake.listingError = SafariBrowserError.processTimedOut(command: "osascript", seconds: 9)
            fake.listingErrorFrom = recheck
            do {
                try await tabs(args, on: fake)
                XCTFail("\(args): the read failed")
            } catch let error as SafariBrowserError {
                XCTAssertEqual("\(error)", "\(readError)", "\(args)")
            }
            XCTAssertEqual(fake.listings, recheck, "\(args)")
        }
    }

    /// A cancelled re-check is a cancellation, not the read error.
    func testACancelledRecheckIsACancellation() async throws {
        let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
        fake.readError = SafariBrowserError.appleScriptFailed("execution error: Can’t get window id 303. (-1728)")
        fake.listingError = CancellationError()
        do {
            try await tabs(["--window", "2"], on: fake)
            XCTFail("the re-check was cancelled")
        } catch is CancellationError {}
    }

    /// After a read that found no tabs there is no read error: a re-check that cannot list the windows reports
    /// its own error.
    func testAnEmptyReadWhoseRecheckFailsReportsTheRecheckError() async throws {
        let fake = FakeSafari(windows: [])
        fake.listingError = SafariBrowserError.processTimedOut(command: "osascript", seconds: 9)
        do {
            try await tabs(["--window", "1"], on: fake)
            XCTFail("the re-check failed")
        } catch SafariBrowserError.processTimedOut {}
    }
}
