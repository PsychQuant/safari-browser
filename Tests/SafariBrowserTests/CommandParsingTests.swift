import XCTest
import ArgumentParser
@testable import SafariBrowser

final class CommandParsingTests: XCTestCase {

    // MARK: - OpenCommand

    func testOpenCommand_basicURL() throws {
        let command = try OpenCommand.parse(["https://example.com"])
        XCTAssertEqual(command.url, "https://example.com")
        XCTAssertFalse(command.newTab)
        XCTAssertFalse(command.newWindow)
    }

    func testOpenCommand_newTab() throws {
        let command = try OpenCommand.parse(["https://example.com", "--new-tab"])
        XCTAssertEqual(command.url, "https://example.com")
        XCTAssertTrue(command.newTab)
        XCTAssertFalse(command.newWindow)
    }

    // MARK: - JSCommand

    func testJSCommand_fileOption() throws {
        let command = try JSCommand.parseAsRoot(["--file", "test.js"])
        XCTAssertTrue(command is JSCommand)
        let jsCommand = command as! JSCommand
        XCTAssertEqual(jsCommand.file, "test.js")
    }

    // MARK: - WaitCommand

    func testWaitCommand_urlAndTimeout() throws {
        let command = try WaitCommand.parse(["--url", "dashboard", "--timeout", "5000"])
        XCTAssertEqual(command.url, "dashboard")
        XCTAssertEqual(command.timeout, 5000)
    }

    func testWaitCommand_milliseconds() throws {
        let command = try WaitCommand.parse(["1000"])
        XCTAssertEqual(command.milliseconds, 1000)
    }

    // MARK: - SnapshotCommand

    func testSnapshotCommand_defaults() throws {
        let command = try SnapshotCommand.parse([])
        XCTAssertFalse(command.page)
        XCTAssertFalse(command.compact)
        XCTAssertFalse(command.json)
        XCTAssertNil(command.selector)
        XCTAssertNil(command.depth)
    }

    func testSnapshotCommand_pageFlag() throws {
        let command = try SnapshotCommand.parse(["--page"])
        XCTAssertTrue(command.page)
        XCTAssertFalse(command.compact)
        XCTAssertFalse(command.json)
    }

    func testSnapshotCommand_pageWithJson() throws {
        let command = try SnapshotCommand.parse(["--page", "--json"])
        XCTAssertTrue(command.page)
        XCTAssertTrue(command.json)
    }

    func testSnapshotCommand_pageWithScope() throws {
        let command = try SnapshotCommand.parse(["--page", "-s", "main"])
        XCTAssertTrue(command.page)
        XCTAssertEqual(command.selector, "main")
    }

    func testSnapshotCommand_pageWithCompact() throws {
        let command = try SnapshotCommand.parse(["--page", "-c"])
        XCTAssertTrue(command.page)
        XCTAssertTrue(command.compact)
    }

    func testSnapshotCommand_pageWithAllFlags() throws {
        let command = try SnapshotCommand.parse(["--page", "--json", "-c", "-s", "form", "-d", "5"])
        XCTAssertTrue(command.page)
        XCTAssertTrue(command.json)
        XCTAssertTrue(command.compact)
        XCTAssertEqual(command.selector, "form")
        XCTAssertEqual(command.depth, 5)
    }

    func testSnapshotCommand_interactiveDefaultUnchanged() throws {
        // Without --page, behavior should be identical to before
        let command = try SnapshotCommand.parse(["-c", "--json"])
        XCTAssertFalse(command.page)
        XCTAssertTrue(command.compact)
        XCTAssertTrue(command.json)
    }

    // MARK: - UploadCommand (#14)

    func testUploadCommand_defaultIsNative() throws {
        // Default (no flags) should use native file dialog
        let command = try UploadCommand.parse(["input", "/tmp/test.txt"])
        XCTAssertFalse(command.js)
        XCTAssertFalse(command.native)
        XCTAssertFalse(command.allowHid)
    }

    func testUploadCommand_jsFlag() throws {
        let command = try UploadCommand.parse(["--js", "input", "/tmp/test.txt"])
        XCTAssertTrue(command.js)
    }

    func testUploadCommand_nativeBackwardCompat() throws {
        // --native still parses (backward compat), same as default
        let command = try UploadCommand.parse(["--native", "input", "/tmp/test.txt"])
        XCTAssertTrue(command.native)
        XCTAssertFalse(command.js)
    }

    func testUploadCommand_allowHidBackwardCompat() throws {
        // --allow-hid still parses (backward compat)
        let command = try UploadCommand.parse(["--allow-hid", "input", "/tmp/test.txt"])
        XCTAssertTrue(command.allowHid)
        XCTAssertFalse(command.js)
    }
}
