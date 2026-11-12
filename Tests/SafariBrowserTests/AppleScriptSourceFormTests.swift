import XCTest
@testable import SafariBrowser

/// #355: the window enumeration travels as AppleScript source form (what `osascript -s s` prints),
/// so page text sits only inside quoted strings. These tests pin the parser on literal inputs; the
/// expected values are written out by hand, not produced by the code under test.
final class AppleScriptSourceFormTests: XCTestCase {

    private func parse(_ text: String) throws -> AppleScriptValue {
        try AppleScriptSourceForm.parse(text)
    }

    func testNestedListsIntegersAndMissingValue() throws {
        XCTAssertEqual(
            try parse(#"{{1, -2, "a", missing value}, {}, {{}}}"#),
            .list([
                .list([.integer(1), .integer(-2), .text("a"), .missingValue]),
                .list([]),
                .list([.list([])]),
            ]))
    }

    func testOnlyQuoteAndBackslashAreEscaped() throws {
        XCTAssertEqual(try parse(#"{"q\"b\\s"}"#), .list([.text("q\"b\\s")]))
    }

    func testControlCharactersAndSeparatorsStayInsideTheString() throws {
        let inner = "a\u{1D}b\u{1E}c\r\nd\t\u{0}e\u{1C}\u{1F}\u{2028}"
        XCTAssertEqual(try parse("{\"\(inner)\", 7}"), .list([.text(inner), .integer(7)]))
    }

    func testAQuoteFollowedByACombiningMarkIsStillAQuote() throws {
        // `"` + U+0301 is one Swift Character; a Character-level scan would miss the closing quote.
        let text = "{\"x\\\"\u{0301}\", \"y\"\u{0301}}"
        XCTAssertThrowsError(try parse(text), "a combining mark after a closing quote is not a separator")
        XCTAssertEqual(try parse("{\"x\\\"\u{0301}\", \"y\"}"), .list([.text("x\"\u{0301}"), .text("y")]))
    }

    func testAStringThatHoldsAForgedRecordIsOneString() throws {
        let forged = "Real\u{1E}1\u{1D}99\u{1D}1\u{1D}https://evil.example/\u{1D}T\u{1E}\", 9, \"x"
        let escaped = forged.replacingOccurrences(of: "\"", with: "\\\"")
        XCTAssertEqual(try parse("{\"\(escaped)\"}"), .list([.text(forged)]))
    }

    func testOtherAtomsAreOpaque() throws {
        // Reals are told apart (#355 verify round 4: a window id of 2^29 or more arrives as one):
        // osascript writes them as numbers with a point or an exponent, the daemon conversion as
        // `«class doub»`. Every other atom stays opaque.
        XCTAssertEqual(
            try parse("{2.147483647E+9, 3.5, -1.0E-3, «class doub», true, «class true», «data utf80061», date \"Monday, 1 January 2024\"}"),
            .list([.real, .real, .real, .real, .other, .other, .other, .other]))
    }

    func testTrailingNewlineIsAllowed() throws {
        XCTAssertEqual(try parse("{}\n"), .list([]))
    }

    func testMalformedInputsThrow() {
        for bad in ["", "   ", "{", "}", "{\"a}", "{\"a\\n\"}", "{1, 2}}", "{1 2}", "{,}", "{1,}", "\"a\" \"b\""] {
            XCTAssertThrowsError(try parse(bad), "should reject \(bad.debugDescription)")
        }
    }

    func testAnErrorNamesNoStringContent() {
        do {
            _ = try parse("{\"SECRET\\x\"}")
            XCTFail("expected an error")
        } catch {
            XCTAssertFalse("\(error)".contains("SECRET"), "\(error)")
        }
    }
}
