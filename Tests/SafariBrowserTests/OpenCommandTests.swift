import XCTest
import ArgumentParser
@testable import SafariBrowser

/// Tests for OpenCommand flag parsing & validation, with emphasis on
/// the new `--replace-tab` opt-in flag introduced by tab-targeting-v2.
final class OpenCommandTests: XCTestCase {

    // MARK: - --replace-tab

    func testReplaceTabParsesAsBooleanFlag() throws {
        let cmd = try OpenCommand.parse([
            "https://example.com",
            "--replace-tab",
        ])
        XCTAssertEqual(cmd.url, "https://example.com")
        XCTAssertTrue(cmd.replaceTab)
        XCTAssertFalse(cmd.newTab)
        XCTAssertFalse(cmd.newWindow)
    }

    func testReplaceTabDefaultFalse() throws {
        let cmd = try OpenCommand.parse(["https://example.com"])
        XCTAssertFalse(cmd.replaceTab)
    }

    func testReplaceTabConflictsWithNewTab() {
        XCTAssertThrowsError(try OpenCommand.parse([
            "https://example.com",
            "--replace-tab",
            "--new-tab",
        ])) { error in
            let msg = "\(error)"
            XCTAssertTrue(
                msg.contains("--replace-tab") || msg.contains("conflicts"),
                "Error must describe the mutual exclusivity, got: \(msg)"
            )
        }
    }

    func testReplaceTabConflictsWithNewWindow() {
        XCTAssertThrowsError(try OpenCommand.parse([
            "https://example.com",
            "--replace-tab",
            "--new-window",
        ]))
    }

    func testReplaceTabCompatibleWithTargetingFlags() throws {
        // --replace-tab may combine with --url (both flags express
        // "navigate this specific target"). This is not a conflict.
        let cmd = try OpenCommand.parse([
            "https://example.com",
            "--replace-tab",
            "--window", "2",
        ])
        XCTAssertTrue(cmd.replaceTab)
        XCTAssertEqual(cmd.target.window, 2)
    }

    // MARK: - Existing validation regression

    func testNewTabRejectsTabInWindow() {
        // Regression guard — tab-targeting-v2 added --tab-in-window, and
        // --new-tab's validator must reject it (creating a new tab
        // makes no sense with a pre-existing tab coordinate).
        XCTAssertThrowsError(try OpenCommand.parse([
            "https://example.com",
            "--new-tab",
            "--window", "1",
            "--tab-in-window", "2",
        ]))
    }
}
