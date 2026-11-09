import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #362 verify round 2, finding A: `get url`, `get title`, `get source`, `doJavaScript` with a window target and
/// `close` hand the miss translation in `runTargetedAppleScript` a target that does not carry the profile, and pass
/// `--profile` separately. When the tab disappears between resolution and the read, the listing must still be
/// that profile's tabs, labelled with window ids, with the `--window-id` hint.
final class ProfileScopedMissTranslationTests: XCTestCase, @unchecked Sendable {
    private func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Work's windows are Safari windows 2 (id 303) and 3 (id 404); window 404 closes after the resolver's listing.
    private static let workTabsLeft = [
        "window 2 tab 1 (window id 303): https://work.example/a1",
        "window 2 tab 2 (window id 303): https://work.example/a2",
    ]

    private func assertScopedMiss(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                                  _ body: @escaping (FakeSafari) async throws -> Void) async {
        let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
        fake.closesAfterListing = (404, 1)
        do {
            try await body(fake)
            XCTFail("\(what): window 404 closed", file: file, line: line)
        } catch let error as SafariBrowserError {
            guard case .documentNotFound(_, let entries) = error else {
                return XCTFail("\(what): \(error)", file: file, line: line)
            }
            XCTAssertEqual(entries, Self.workTabsLeft, what, file: file, line: line)
            let message = flat(error.localizedDescription)
            XCTAssertFalse(message.contains("home.example"), "\(what): \(message)", file: file, line: line)
            XCTAssertTrue(message.contains("--window-id W"), "\(what): \(message)", file: file, line: line)
            XCTAssertFalse(message.contains("target one with --window N"), "\(what): \(message)", file: file, line: line)
            XCTAssertFalse(message.contains("Or target positionally with --window N"), "\(what): \(message)", file: file, line: line)
        } catch {
            XCTFail("\(what): \(error)", file: file, line: line)
        }
    }

    func testGetURLWithAWindowNumberUnderAProfile() async {
        await assertScopedMiss("get url --window 2 --profile Work") { fake in
            var command = try GetURL.parse(["--window", "2", "--profile", "Work"])
            try await fake.drive { try await command.run() }
        }
    }

    func testGetTitleWithAURLUnderAProfile() async {
        await assertScopedMiss("get title --url b1 --profile Work") { fake in
            var command = try GetTitle.parse(["--url", "b1", "--profile", "Work"])
            try await fake.drive { try await command.run() }
        }
    }

    func testGetSourceWithAWindowNumberUnderAProfile() async {
        await assertScopedMiss("get source --window 2 --profile Work") { fake in
            var command = try GetSource.parse(["--window", "2", "--profile", "Work"])
            try await fake.drive { try await command.run() }
        }
    }

    func testJavaScriptOnAWindowTabUnderAProfile() async {
        await assertScopedMiss("doJavaScript .windowTab(2, 1) --profile Work") { fake in
            _ = try await fake.drive {
                try await SafariBridge.doJavaScript("1", target: .windowTab(window: 2, tabInWindow: 1), profile: "Work")
            }
        }
    }

    func testCloseUnderAProfile() async {
        await assertScopedMiss("close --window 2 --profile Work") { fake in
            var command = try CloseCommand.parse(["--window", "2", "--profile", "Work"])
            try await fake.drive { try await command.run() }
        }
    }

    /// Without `--profile` the translation is unscoped, as before: every window's tabs, no ids.
    func testWithoutAProfileTheTranslationIsUnchanged() async throws {
        let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
        fake.readError = SafariBrowserError.appleScriptFailed("execution error: Can’t get window 3. (-1728)")
        do {
            var command = try CloseCommand.parse(["--window", "3"])
            try await fake.drive { try await command.run() }
            XCTFail("the close failed")
        } catch SafariBrowserError.documentNotFound(let pattern, let entries) {
            XCTAssertEqual(pattern, "window 3")
            XCTAssertEqual(entries, [
                "window 1 tab 1: https://home.example/1",
                "window 2 tab 1: https://work.example/a1",
                "window 2 tab 2: https://work.example/a2",
                "window 3 tab 1: https://work.example/b1",
            ])
        }
    }
}
