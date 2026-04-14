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

    func testDocumentNotFound() {
        let error = SafariBrowserError.documentNotFound(
            pattern: "plud",
            availableDocuments: [
                "https://web.plaud.ai/",
                "https://platform.claude.com/oauth/",
            ]
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("plud"),
            "Expected pattern in description, got: \(description)"
        )
        XCTAssertTrue(
            description.contains("https://web.plaud.ai/"),
            "Expected first available document in description, got: \(description)"
        )
        XCTAssertTrue(
            description.contains("https://platform.claude.com/oauth/"),
            "Expected second available document in description, got: \(description)"
        )
    }

    func testDocumentNotFoundWithEmptyList() {
        let error = SafariBrowserError.documentNotFound(
            pattern: "xyz",
            availableDocuments: []
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("xyz"),
            "Expected pattern in description, got: \(description)"
        )
    }

    // #26: native-url-resolution — ambiguous match fails closed and
    // surfaces every candidate so the user can pick a more specific
    // substring without running a follow-up command.
    func testAmbiguousWindowMatch() {
        let error = SafariBrowserError.ambiguousWindowMatch(
            pattern: "plaud",
            matches: [
                (windowIndex: 1, url: "https://web.plaud.ai/file/a"),
                (windowIndex: 3, url: "https://web.plaud.ai/file/b"),
            ]
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("plaud"),
            "Expected pattern in description, got: \(description)"
        )
        XCTAssertTrue(
            description.contains("https://web.plaud.ai/file/a"),
            "Expected first matching URL in description, got: \(description)"
        )
        XCTAssertTrue(
            description.contains("https://web.plaud.ai/file/b"),
            "Expected second matching URL in description, got: \(description)"
        )
        // Each match must carry its window index so the user can cross-reference
        // with `safari-browser documents` output. The ambiguity resolution path
        // depends on users knowing which window is which.
        XCTAssertTrue(
            description.contains("window 1"),
            "Expected 'window 1' label in description, got: \(description)"
        )
        XCTAssertTrue(
            description.contains("window 3"),
            "Expected 'window 3' label in description, got: \(description)"
        )
        // The error must tell the user how to recover — appending more of the
        // URL path is the canonical disambiguation strategy. Without this hint,
        // users hit the error, don't know what to change, and give up.
        XCTAssertTrue(
            description.contains("more specific") || description.contains("disambiguate"),
            "Expected disambiguation hint in description, got: \(description)"
        )
    }

    // #26 verify P1-2: screenshot refuses to capture a background-tab
    // target and surfaces a recovery-hinted error instead of silently
    // screenshotting the wrong tab's visible pixels.
    func testBackgroundTabNotCapturable() {
        let error = SafariBrowserError.backgroundTabNotCapturable(windowIndex: 2, tabIndex: 3)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("background tab"),
            "Expected 'background tab' in description, got: \(description)"
        )
        XCTAssertTrue(
            description.contains("window 2"),
            "Expected 'window 2' in description, got: \(description)"
        )
        XCTAssertTrue(
            description.contains("tab 3"),
            "Expected 'tab 3' in description, got: \(description)"
        )
        // Recovery hint: the error must point to the two viable
        // workarounds (manual tab switch or document-scoped command).
        XCTAssertTrue(
            description.contains("snapshot") || description.contains("get source"),
            "Expected document-scoped command hint, got: \(description)"
        )
    }

    func testAmbiguousWindowMatchWithEmptyMatches() {
        // Defensive: an empty matches array shouldn't happen (the resolver
        // should throw documentNotFound for zero matches, not
        // ambiguousWindowMatch), but if it does, the description must not
        // crash and must surface the internal-error signal so it gets caught
        // by tests rather than confusing an end user.
        let error = SafariBrowserError.ambiguousWindowMatch(
            pattern: "plaud",
            matches: []
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("plaud"),
            "Expected pattern in description even for empty matches, got: \(description)"
        )
        XCTAssertTrue(
            description.contains("internal error") || description.contains("empty"),
            "Expected internal-error signal for empty matches, got: \(description)"
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
        // #20 F3: the error must also warn about the non-interference side
        // effect so users don't blindly run killall and break their other
        // automation tools.
        XCTAssertTrue(
            description.contains("Keyboard Maestro") || description.contains("interrupt"),
            "Expected non-interference warning in description, got: \(description)"
        )
        // #20 F7: user-facing CLI names, not internal Swift function names.
        XCTAssertFalse(
            description.contains("navigateFileDialog"),
            "Should not leak internal Swift symbol names, got: \(description)"
        )
    }
}
