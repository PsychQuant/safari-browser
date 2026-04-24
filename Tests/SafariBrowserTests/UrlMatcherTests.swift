import XCTest
@testable import SafariBrowser

/// Pure unit tests for `SafariBridge.UrlMatcher.matches(_:)` covering the
/// four matching cases (`contains`, `exact`, `endsWith`, `regex`) plus
/// boundary conditions called out in the `document-targeting` spec delta:
/// - no URL canonicalization (trailing slash, host case, query differ = no match for exact)
/// - Unicode URL handling
/// - case sensitivity defaults
/// - unanchored regex by default; anchors honored when present
///
/// These tests are the TDD red phase for tasks 1.1 and 1.2 of the
/// `url-matching-pipeline` change.
final class UrlMatcherTests: XCTestCase {

    // MARK: - contains

    func testContainsMatchesSubstring() {
        let matcher = SafariBridge.UrlMatcher.contains("plaud")
        XCTAssertTrue(matcher.matches("https://web.plaud.ai/"))
    }

    func testContainsReturnsFalseWhenSubstringAbsent() {
        XCTAssertFalse(SafariBridge.UrlMatcher.contains("plaud").matches("https://example.com/"))
    }

    func testContainsIsCaseSensitive() {
        XCTAssertFalse(SafariBridge.UrlMatcher.contains("Plaud").matches("https://web.plaud.ai/"))
    }

    func testContainsEmptyPatternFollowsSwiftSemantics() {
        // Swift `String.contains("")` returns false — there is no empty
        // subrange to locate. The matcher intentionally inherits this
        // semantics: CLI-layer `validate()` should reject empty patterns,
        // but the pure matcher does not second-guess the stdlib.
        XCTAssertFalse(SafariBridge.UrlMatcher.contains("").matches("https://example.com/"))
    }

    // MARK: - exact

    func testExactMatchesOnFullStringEquality() {
        XCTAssertTrue(
            SafariBridge.UrlMatcher.exact("https://web.plaud.ai/")
                .matches("https://web.plaud.ai/")
        )
    }

    func testExactRejectsTrailingSlashDifference() {
        XCTAssertFalse(
            SafariBridge.UrlMatcher.exact("https://web.plaud.ai/")
                .matches("https://web.plaud.ai")
        )
    }

    func testExactRejectsQueryStringDifference() {
        XCTAssertFalse(
            SafariBridge.UrlMatcher.exact("https://example.com/")
                .matches("https://example.com/?q=1")
        )
    }

    func testExactRejectsHostCaseDifference() {
        XCTAssertFalse(
            SafariBridge.UrlMatcher.exact("https://example.com/")
                .matches("https://Example.com/")
        )
    }

    // MARK: - endsWith

    func testEndsWithMatchesSuffix() {
        let url = "https://vod.edupsy.tw/course/a/lesson/b/video/c/auth/d/play"
        XCTAssertTrue(SafariBridge.UrlMatcher.endsWith("/play").matches(url))
    }

    func testEndsWithReturnsFalseWhenSuffixNotAtEnd() {
        XCTAssertFalse(
            SafariBridge.UrlMatcher.endsWith("/play").matches("https://example.com/play/next")
        )
    }

    func testEndsWithIsCaseSensitive() {
        XCTAssertFalse(SafariBridge.UrlMatcher.endsWith("/Play").matches("https://x/play"))
    }

    // MARK: - regex

    func testRegexUnanchoredMatchesSubstring() throws {
        let regex = try NSRegularExpression(pattern: "plaud", options: [])
        XCTAssertTrue(SafariBridge.UrlMatcher.regex(regex).matches("https://web.plaud.ai/"))
    }

    func testRegexAnchoredRejectsNonFullMatch() throws {
        let regex = try NSRegularExpression(pattern: #"^https://plaud\.ai/$"#, options: [])
        XCTAssertFalse(SafariBridge.UrlMatcher.regex(regex).matches("https://web.plaud.ai/"))
    }

    func testRegexAnchoredAcceptsExactMatch() throws {
        let regex = try NSRegularExpression(pattern: #"^https://web\.plaud\.ai/$"#, options: [])
        XCTAssertTrue(SafariBridge.UrlMatcher.regex(regex).matches("https://web.plaud.ai/"))
    }

    func testRegexCapturesDifferentiatingSuffix() throws {
        // Simulates hierarchical-URL disambiguation described in #34.
        let regex = try NSRegularExpression(
            pattern: #"lesson/[a-f0-9-]+$"#,
            options: []
        )
        XCTAssertTrue(regex.let_matches("https://vod.edupsy.tw/x/lesson/7baa5578-e72a"))
        XCTAssertFalse(regex.let_matches("https://vod.edupsy.tw/x/lesson/7baa5578/video/y/play"))
    }

    // MARK: - Unicode / percent-encoding

    func testContainsMatchesPercentEncodedSubstring() {
        // Safari returns percent-encoded URLs; matcher sees raw string as-is.
        let url = "https://www.google.com/maps/dir/%E6%9D%B1%E4%BA%AC"
        XCTAssertTrue(SafariBridge.UrlMatcher.contains("%E6%9D%B1").matches(url))
    }

    func testEndsWithHandlesUnicodeInURL() {
        // Whether Safari gives raw Unicode or percent-encoded, the matcher
        // compares Swift String byte sequences. We test percent-encoded.
        let url = "https://example.com/path/%E6%B8%AC%E8%A9%A6"
        XCTAssertTrue(SafariBridge.UrlMatcher.endsWith("%E8%A9%A6").matches(url))
    }

    // MARK: - Equatable (same case same value → equal; different case → not equal)

    func testEquatableSameCaseSameValueEqual() {
        XCTAssertEqual(
            SafariBridge.UrlMatcher.contains("plaud"),
            SafariBridge.UrlMatcher.contains("plaud")
        )
        XCTAssertEqual(
            SafariBridge.UrlMatcher.exact("https://x/"),
            SafariBridge.UrlMatcher.exact("https://x/")
        )
        XCTAssertEqual(
            SafariBridge.UrlMatcher.endsWith("/play"),
            SafariBridge.UrlMatcher.endsWith("/play")
        )
    }

    func testEquatableDifferentCaseNotEqual() {
        XCTAssertNotEqual(
            SafariBridge.UrlMatcher.contains("plaud"),
            SafariBridge.UrlMatcher.endsWith("plaud")
        )
    }

    func testEquatableRegexSamePatternEqual() throws {
        let a = try NSRegularExpression(pattern: "foo", options: [])
        let b = try NSRegularExpression(pattern: "foo", options: [])
        XCTAssertEqual(SafariBridge.UrlMatcher.regex(a), SafariBridge.UrlMatcher.regex(b))
    }

    func testEquatableRegexDifferentPatternNotEqual() throws {
        let a = try NSRegularExpression(pattern: "foo", options: [])
        let b = try NSRegularExpression(pattern: "bar", options: [])
        XCTAssertNotEqual(SafariBridge.UrlMatcher.regex(a), SafariBridge.UrlMatcher.regex(b))
    }
}

/// Tiny helper so regex-match assertions stay readable in tests above.
private extension NSRegularExpression {
    func let_matches(_ string: String) -> Bool {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return firstMatch(in: string, options: [], range: range) != nil
    }
}
