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
}
