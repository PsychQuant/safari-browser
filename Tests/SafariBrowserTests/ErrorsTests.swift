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

    // #30: the error message was enriched from a one-liner to a
    // multi-hint guide because click/fill/screenshot/etc. all throw
    // this case and the richer hints help every caller. Assertions
    // check the selector verbatim appears plus common recovery hints
    // (wait-for-load, Shadow DOM, iframe) — the caller doesn't need
    // to know `--element` specifically.
    func testElementNotFound() {
        let error = SafariBrowserError.elementNotFound("#login-btn")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("#login-btn"),
                      "Expected selector verbatim, got: \(description)")
        XCTAssertTrue(description.contains("querySelectorAll"),
                      "Expected JS API mention for clarity, got: \(description)")
        XCTAssertTrue(description.contains("Shadow DOM"),
                      "Expected Shadow DOM hint, got: \(description)")
        XCTAssertTrue(description.contains("iframe"),
                      "Expected iframe hint, got: \(description)")
        XCTAssertTrue(description.contains("wait --js"),
                      "Expected wait-for-load recovery hint, got: \(description)")
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

    // MARK: - #30 element error cases

    // Rich ambiguous error is the core of #30's disambiguation UX —
    // users see each match's rect + attrs + text so they can pick the
    // right selector refinement or --element-index in one shot, rather
    // than trial-and-error.
    func testElementAmbiguous() {
        let matches = [
            ElementMatch(
                rect: CGRect(x: 50, y: 100, width: 300, height: 200),
                attributes: "div.card.featured",
                textSnippet: "Launch Sale"
            ),
            ElementMatch(
                rect: CGRect(x: 50, y: 320, width: 300, height: 200),
                attributes: "div.card",
                textSnippet: "Summer Deal"
            ),
            ElementMatch(
                rect: CGRect(x: 50, y: 540, width: 300, height: 200),
                attributes: "div.card",
                textSnippet: nil
            ),
        ]
        let error = SafariBrowserError.elementAmbiguous(selector: ".card", matches: matches)
        let description = error.errorDescription ?? ""
        // Selector verbatim
        XCTAssertTrue(description.contains(".card"),
                      "Expected selector in description, got: \(description)")
        // All three matches' attributes must surface so the user can
        // differentiate and refine.
        XCTAssertTrue(description.contains("div.card.featured"),
                      "Expected first match attrs, got: \(description)")
        // Rect coordinates must appear for spatial context.
        XCTAssertTrue(description.contains("x:50") && description.contains("y:320"),
                      "Expected rect coords in description, got: \(description)")
        // Text snippets present when non-nil, absent or blank when nil.
        XCTAssertTrue(description.contains("Launch Sale"),
                      "Expected first match text snippet, got: \(description)")
        XCTAssertTrue(description.contains("Summer Deal"),
                      "Expected second match text snippet, got: \(description)")
        // Recovery hints: both disambiguation paths must be suggested.
        XCTAssertTrue(description.contains("--element-index"),
                      "Expected --element-index disambiguation hint, got: \(description)")
        XCTAssertTrue(description.contains("Refine selector") || description.contains(":nth-of-type"),
                      "Expected selector-refinement hint, got: \(description)")
    }

    func testElementIndexOutOfRange() {
        let error = SafariBrowserError.elementIndexOutOfRange(
            selector: ".card", index: 5, matchCount: 3
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains(".card"),
                      "Expected selector in description, got: \(description)")
        XCTAssertTrue(description.contains("5") && description.contains("3"),
                      "Expected both index and matchCount in description, got: \(description)")
        // Valid range must be stated so the user knows what to change to.
        XCTAssertTrue(description.contains("1 to 3") || description.contains("Valid range"),
                      "Expected valid-range hint, got: \(description)")
    }

    func testElementZeroSize() {
        let error = SafariBrowserError.elementZeroSize(selector: "#hidden")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("#hidden"),
                      "Expected selector in description, got: \(description)")
        XCTAssertTrue(description.contains("display: none") || description.contains("visibility: hidden"),
                      "Expected display/visibility hint, got: \(description)")
        // Must give a diagnostic command so users can investigate.
        XCTAssertTrue(description.contains("getComputedStyle"),
                      "Expected diagnostic command hint, got: \(description)")
    }

    func testElementOutsideViewport() {
        let error = SafariBrowserError.elementOutsideViewport(
            selector: "#below-fold",
            rect: CGRect(x: 0, y: 5000, width: 100, height: 100),
            viewport: CGSize(width: 1920, height: 1080)
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("#below-fold"),
                      "Expected selector in description, got: \(description)")
        // Coordinates provide context.
        XCTAssertTrue(description.contains("5000"),
                      "Expected element y-coord in description, got: \(description)")
        XCTAssertTrue(description.contains("1920") || description.contains("1080"),
                      "Expected viewport dims in description, got: \(description)")
        // Recovery paths: scrollIntoView, --full, or future --scroll-into-view.
        XCTAssertTrue(description.contains("scrollIntoView"),
                      "Expected scrollIntoView hint, got: \(description)")
        XCTAssertTrue(description.contains("--full"),
                      "Expected --full alternative, got: \(description)")
    }

    func testElementSelectorInvalid() {
        let error = SafariBrowserError.elementSelectorInvalid(
            selector: "div[unclosed",
            reason: "SyntaxError: The string did not match the expected pattern."
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("div[unclosed"),
                      "Expected selector verbatim, got: \(description)")
        XCTAssertTrue(description.contains("SyntaxError"),
                      "Expected JS error reason verbatim, got: \(description)")
    }

    // MARK: - #30 accessibilityRequired flag customization

    // Same error case, different flag → different alternative guidance.
    // --content-only can fall back by dropping the flag; --element
    // cannot, so its alternative points to external tooling.
    func testAccessibilityRequiredForElement() {
        let error = SafariBrowserError.accessibilityRequired(flag: "--element")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("--element"),
                      "Expected flag name in description, got: \(description)")
        XCTAssertTrue(description.contains("System Settings") && description.contains("Accessibility"),
                      "Expected System Settings path, got: \(description)")
        // --element's alternative is external crop, not drop-the-flag.
        XCTAssertTrue(description.contains("--window") || description.contains("--url"),
                      "Expected --window/--url capture hint, got: \(description)")
        XCTAssertTrue(description.contains("ImageMagick") || description.contains("sips"),
                      "Expected external crop tool mention, got: \(description)")
    }

    func testAccessibilityRequiredForContentOnlyUnchanged() {
        let error = SafariBrowserError.accessibilityRequired(flag: "--content-only")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("--content-only"),
                      "Expected flag name in description, got: \(description)")
        // --content-only alternative is drop-the-flag (original #29 behavior).
        XCTAssertTrue(description.contains("without") && description.contains("--content-only"),
                      "Expected 'run without --content-only' alternative, got: \(description)")
        // Must NOT accidentally slip --element-only guidance into the --content-only path.
        XCTAssertFalse(description.contains("ImageMagick"),
                       "ImageMagick hint leaked into --content-only path: \(description)")
    }

    func testAccessibilityRequiredForUnknownFlagFallsBackToGeneric() {
        let error = SafariBrowserError.accessibilityRequired(flag: "--hypothetical-future-flag")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("--hypothetical-future-flag"),
                      "Expected flag name in description, got: \(description)")
        // Generic fallback: "re-run without --hypothetical-future-flag"
        XCTAssertTrue(description.contains("without") && description.contains("--hypothetical-future-flag"),
                      "Expected generic 'run without <flag>' fallback, got: \(description)")
    }

    // #29 legacy test — superseded by #30's flag-specific tests above
    // (testAccessibilityRequiredForContentOnlyUnchanged).
    // Kept to assert the shared invariant: System Settings path must
    // always be in the message regardless of flag.
    func testAccessibilityRequired() {
        let error = SafariBrowserError.accessibilityRequired(flag: "--content-only")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("System Settings") && description.contains("Accessibility"),
            "Expected System Settings → Accessibility path, got: \(description)"
        )
    }

    // #29: webAreaNotFound is the second failure mode for --content-only
    // — AX is granted but the AXWebArea can't be located (private
    // window, PDF preview, etc.). Different recovery than
    // accessibilityRequired, so it needs its own error case.
    func testWebAreaNotFound() {
        let error = SafariBrowserError.webAreaNotFound(reason: "no AXWebArea within depth 3")
        let description = error.errorDescription ?? ""
        // The reason parameter must appear verbatim so the message
        // explains which specific failure mode triggered.
        XCTAssertTrue(
            description.contains("no AXWebArea within depth 3"),
            "Expected reason string verbatim in description, got: \(description)"
        )
        // The recovery must point at the flag-free alternative — this
        // error usually means the page state is exotic (PDF, private),
        // and the only realistic recovery is to accept chrome in the
        // screenshot.
        XCTAssertTrue(
            description.contains("without") && description.contains("--content-only"),
            "Expected 'run without --content-only' recovery, got: \(description)"
        )
    }

    // MARK: - #31 save-image error cases

    func testElementHasNoSrc() {
        let error = SafariBrowserError.elementHasNoSrc(selector: "#empty", tagName: "img")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("#empty"),
                      "Expected selector verbatim, got: \(description)")
        XCTAssertTrue(description.contains("<img>"),
                      "Expected tagName in description, got: \(description)")
        // Must explain which attribute was checked so users know the
        // element was resolved but its resource URL is missing.
        XCTAssertTrue(description.contains("currentSrc") || description.contains("src"),
                      "Expected src-attribute hint, got: \(description)")
    }

    func testUnsupportedElement() {
        let error = SafariBrowserError.unsupportedElement(selector: "#card", tagName: "div")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("#card"),
                      "Expected selector verbatim, got: \(description)")
        XCTAssertTrue(description.contains("<div>"),
                      "Expected tagName in description, got: \(description)")
        // Supported tags must be enumerated so users know what to try.
        XCTAssertTrue(description.contains("<img>") && description.contains("<video>") && description.contains("<svg>"),
                      "Expected supported-tag list, got: \(description)")
        // Common wrong-element cases need redirect hints.
        XCTAssertTrue(description.contains("screenshot --element") || description.contains("canvas"),
                      "Expected canvas redirect hint, got: \(description)")
    }

    func testDownloadFailedWithStatusCode() {
        let error = SafariBrowserError.downloadFailed(
            url: "https://cdn.example.com/img.jpg",
            statusCode: 404,
            reason: "Not Found"
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("https://cdn.example.com/img.jpg"),
                      "Expected URL verbatim, got: \(description)")
        XCTAssertTrue(description.contains("404"),
                      "Expected status code, got: \(description)")
        // 401/403 are the auth-related hint trigger; must mention the
        // --with-cookies fallback so users know the next step.
        XCTAssertTrue(description.contains("--with-cookies"),
                      "Expected --with-cookies hint for auth failures, got: \(description)")
    }

    func testDownloadFailedNetworkError() {
        let error = SafariBrowserError.downloadFailed(
            url: "https://unreachable.example",
            statusCode: nil,
            reason: "DNS resolution failed"
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("network error"),
                      "Expected 'network error' label when statusCode is nil, got: \(description)")
        XCTAssertTrue(description.contains("DNS resolution failed"),
                      "Expected reason verbatim, got: \(description)")
    }

    func testDownloadSizeCapExceeded() {
        let error = SafariBrowserError.downloadSizeCapExceeded(
            url: "https://big.example.com/video.mp4",
            capBytes: 10_485_760,  // 10 MB
            actualBytes: 15_728_640  // 15 MB
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("https://big.example.com/video.mp4"),
                      "Expected URL verbatim, got: \(description)")
        XCTAssertTrue(description.contains("10") && description.contains("MB"),
                      "Expected cap size in MB, got: \(description)")
        XCTAssertTrue(description.contains("15"),
                      "Expected actual size, got: \(description)")
        // Recovery hint: drop --with-cookies when resource is not authenticated.
        XCTAssertTrue(description.contains("drop `--with-cookies`") || description.contains("without `--with-cookies`") || description.contains("default URLSession"),
                      "Expected drop-flag recovery hint, got: \(description)")
    }

    func testUnsupportedURLScheme() {
        let error = SafariBrowserError.unsupportedURLScheme(
            url: "blob:https://example.com/abc-123",
            scheme: "blob"
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("blob"),
                      "Expected scheme verbatim, got: \(description)")
        XCTAssertTrue(description.contains("blob:https://example.com/abc-123"),
                      "Expected URL verbatim, got: \(description)")
        // Supported schemes must be listed so users know the boundary.
        XCTAssertTrue(description.contains("https://") && description.contains("data:"),
                      "Expected supported-scheme list, got: \(description)")
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
