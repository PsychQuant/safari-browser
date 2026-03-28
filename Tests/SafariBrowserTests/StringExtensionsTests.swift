import XCTest

@testable import SafariBrowser

final class StringExtensionsTests: XCTestCase {

    // MARK: - escapedForAppleScript

    func testEscapedForAppleScript_doubleQuotes() {
        let input = #"He said "hello""#
        let result = input.escapedForAppleScript
        XCTAssertEqual(result, #"He said \"hello\""#)
    }

    func testEscapedForAppleScript_backslashes() {
        let input = #"path\to\file"#
        let result = input.escapedForAppleScript
        XCTAssertEqual(result, #"path\\to\\file"#)
    }

    func testEscapedForAppleScript_combined() {
        let input = #"say \"hi\""#
        let result = input.escapedForAppleScript
        XCTAssertEqual(result, #"say \\\"hi\\\""#)
    }

    // MARK: - escapedForJS

    func testEscapedForJS_singleQuotes() {
        let input = "it's a test"
        let result = input.escapedForJS
        XCTAssertEqual(result, "it\\'s a test")
    }

    func testEscapedForJS_backslashes() {
        let input = #"path\to\file"#
        let result = input.escapedForJS
        XCTAssertEqual(result, #"path\\to\\file"#)
    }

    // MARK: - resolveRefJS

    func testResolveRefJS_cssSelector() {
        let input = "button.primary"
        let result = input.resolveRefJS
        XCTAssertTrue(result.contains("querySelector"), "CSS selector should use querySelector")
    }

    func testResolveRefJS_refPattern() {
        let input = "@e3"
        let result = input.resolveRefJS
        XCTAssertTrue(result.contains("__sbRefs[2]"), "@e3 should resolve to __sbRefs[2]")
    }

    // MARK: - isRef

    func testIsRef_validRef() {
        XCTAssertTrue("@e1".isRef)
    }

    func testIsRef_zeroIsNotValid() {
        XCTAssertFalse("@e0".isRef, "@e0 should not be a valid ref (indices start at 1)")
    }

    func testIsRef_plainSelector() {
        XCTAssertFalse("button".isRef)
    }

    func testIsRef_nonNumericSuffix() {
        XCTAssertFalse("@eabc".isRef)
    }

    // MARK: - refErrorMessage

    func testRefErrorMessage_ref() {
        let result = "@e1".refErrorMessage
        XCTAssertTrue(result.contains("Invalid ref"), "@e1 error should contain 'Invalid ref'")
    }

    func testRefErrorMessage_selector() {
        let result = "button".refErrorMessage
        XCTAssertTrue(
            result.contains("Element not found"), "selector error should contain 'Element not found'")
    }
}
