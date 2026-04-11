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
        // Error description starts with the human-readable summary. F8 adds a
        // troubleshooting hint line; assert prefix to stay robust to hint wording.
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.hasPrefix("Process timed out after 30 seconds: /usr/bin/osascript -e ..."),
            "Unexpected description: \(description)"
        )
        XCTAssertTrue(description.contains("Console.app") || description.contains("System Events"),
                      "Expected troubleshooting hint in description, got: \(description)")
    }

    func testInvalidTimeout() {
        let error = SafariBrowserError.invalidTimeout(-1.0)
        XCTAssertEqual(
            error.errorDescription,
            "Invalid timeout value: -1.0 (must be a finite number between 0.001 and 86400 seconds)"
        )
    }

    func testSystemEventsNotResponding() {
        let error = SafariBrowserError.systemEventsNotResponding(underlying: "probe timed out after 2 seconds")
        let description = error.errorDescription ?? ""
        // The error must name the failing dependency and echo the underlying detail.
        XCTAssertTrue(
            description.contains("System Events"),
            "Expected 'System Events' in description, got: \(description)"
        )
        XCTAssertTrue(
            description.contains("probe timed out after 2 seconds"),
            "Expected underlying detail in description, got: \(description)"
        )
        // Must surface a user-executable recovery command so CI / non-interactive
        // users aren't left guessing how to fix this.
        XCTAssertTrue(
            description.contains("killall"),
            "Expected 'killall' recovery hint in description, got: \(description)"
        )
    }
}
