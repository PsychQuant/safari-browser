import XCTest
@testable import SafariBrowser

/// #69 — `SafariBrowser.gluedFlagHint` turns a confusing "Unknown option
/// '--url report'" failure (a flag and value glued into one argv element via
/// the zsh `LOCK="--url X"; cmd $LOCK` footgun, or a user-quoted
/// `cmd "--url report"`) into a self-explaining hint. Pure-function coverage;
/// the `main()` wiring that prints it is exercised by the live CLI.
final class GluedFlagHintTests: XCTestCase {

    func testHintForGluedUrlFlag() {
        let hint = SafariBrowser.gluedFlagHint(forErrorMessage: "Unknown option '--url report'")
        guard let hint else { return XCTFail("expected a hint for a glued --url value") }
        XCTAssertTrue(hint.contains("--url report"), "hint should echo the inlined two-word form")
        XCTAssertTrue(hint.contains("zsh"), "hint should mention the zsh array workaround")
        XCTAssertTrue(hint.contains("LOCK=(--url report)"), "hint should show the array fix")
    }

    func testHintForGluedWindowFlag() {
        XCTAssertNotNil(SafariBrowser.gluedFlagHint(forErrorMessage: "Unknown option '--window 2'"))
    }

    func testHintForGluedProfileFlag() {
        // --profile joined targetFlagNames in #60, so it's covered too.
        XCTAssertNotNil(SafariBrowser.gluedFlagHint(forErrorMessage: "Unknown option '--profile work'"))
    }

    func testHintAppearsWithinFullArgumentParserMessage() {
        // ArgumentParser's full message wraps the line with extra usage text;
        // detection must still find the embedded "Unknown option '…'" clause.
        let full = "Error: Unknown option '--url report'\nUsage: safari-browser snapshot ..."
        XCTAssertNotNil(SafariBrowser.gluedFlagHint(forErrorMessage: full))
    }

    func testNoHintForGenuinelyUnknownFlagWithoutValue() {
        XCTAssertNil(SafariBrowser.gluedFlagHint(forErrorMessage: "Unknown option '--frobnicate'"))
    }

    func testNoHintWhenLeadingTokenIsNotAKnownTargetingFlag() {
        // A space-containing unknown option whose head isn't a real flag must
        // NOT produce a misleading "inline them" hint.
        XCTAssertNil(SafariBrowser.gluedFlagHint(forErrorMessage: "Unknown option '--bogus value'"))
    }

    func testNoHintForUnrelatedParserError() {
        XCTAssertNil(SafariBrowser.gluedFlagHint(forErrorMessage: "Missing expected argument '<url>'"))
    }
}
