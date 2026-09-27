import XCTest
@testable import SafariBrowser

final class JSWrapperTests: XCTestCase {
    func testBothInvocationFormsRemainEvalFreeAndNewlineGuarded() {
        for statement in [false, true] {
            let code = statement ? "var a = 2; return a + 3; // trailing" : "1 + 1 // trailing"
            let wrapper = JSWrapper.invocationWrapper(code, key: "fixtureKey", token: "fixture", statement: statement)
            XCTAssertFalse(wrapper.contains("eval("))
            XCTAssertFalse(wrapper.contains("new Function"))
            XCTAssertTrue(wrapper.contains("\n" + code + "\n"))
        }
    }

    // MARK: - cspEvalHint

    func testCSPEvalHint_detectsUnsafeEvalRefusal() {
        // Verbatim shape observed live on facebook.com / claude.ai (#76).
        let message = "AppleScript error: JavaScript error: Refused to evaluate a string as JavaScript because 'unsafe-eval' or 'trusted-types-eval' is not an allowed source of script in the following Content Security Policy directive: \"script-src 'self'\"."
        let hint = JSWrapper.cspEvalHint(for: message)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("unsafe-eval") ?? false)
    }

    func testCSPEvalHint_detectsCSPMarkerVariants() {
        // Either marker alongside the refusal phrase qualifies.
        XCTAssertNotNil(JSWrapper.cspEvalHint(
            for: "Refused to evaluate a string as JavaScript because 'unsafe-eval' is not allowed"))
        XCTAssertNotNil(JSWrapper.cspEvalHint(
            for: "Refused to evaluate a string as JavaScript — blocked by Content Security Policy"))
    }

    func testCSPEvalHint_nilForCoincidentalRefusalPhrase() {
        // Verify-round finding (#76): user-authored errors that merely contain
        // the refusal phrase must not get the misleading CSP hint.
        XCTAssertNil(JSWrapper.cspEvalHint(for: "Refused to evaluate the submitted form"))
        XCTAssertNil(JSWrapper.cspEvalHint(for: "Refused to evaluate a string as JavaScript"))
    }

    func testCSPEvalHint_nilForUnrelatedErrors() {
        XCTAssertNil(JSWrapper.cspEvalHint(for: "TypeError: undefined is not a function"))
        XCTAssertNil(JSWrapper.cspEvalHint(for: "AppleScript error: -1719"))
        XCTAssertNil(JSWrapper.cspEvalHint(for: ""))
    }

}
