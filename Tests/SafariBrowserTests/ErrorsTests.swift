import XCTest
@testable import SafariBrowser

final class ErrorsTests: XCTestCase {

    func testAppleScriptFailed() {
        let error = SafariBrowserError.appleScriptFailed("script timeout")
        XCTAssertEqual(error.errorDescription, "AppleScript error: script timeout")
    }

    func testFileNotFound() {
        let error = SafariBrowserError.fileNotFound("/tmp/missing.js")
        XCTAssertEqual(error.errorDescription, "File not found: /tmp/missing.js")
    }

    func testInvalidTabIndex() {
        let error = SafariBrowserError.invalidTabIndex(99)
        XCTAssertEqual(error.errorDescription, "Invalid tab index: 99")
    }

    func testTimeout() {
        let error = SafariBrowserError.timeout(seconds: 30)
        XCTAssertEqual(error.errorDescription, "Timeout after 30 seconds")
    }

    func testNoSafariWindow() {
        let error = SafariBrowserError.noSafariWindow
        XCTAssertEqual(error.errorDescription, "No Safari window found")
    }

    func testElementNotFound() {
        let error = SafariBrowserError.elementNotFound("#login-btn")
        XCTAssertEqual(error.errorDescription, "Element not found: #login-btn")
    }

    func testProcessTimedOut() {
        let error = SafariBrowserError.processTimedOut(command: "/usr/bin/osascript -e ...", seconds: 30)
        XCTAssertEqual(
            error.errorDescription,
            "Process timed out after 30 seconds: /usr/bin/osascript -e ..."
        )
    }
}
