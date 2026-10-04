import XCTest

@testable import SafariBrowser

/// #76: `js` must not route user code through page-context `eval()` —
/// strict-CSP pages (script-src without 'unsafe-eval') refuse it, while
/// AppleScript `do JavaScript` itself runs as UA-privileged script and is
/// NOT subject to the page CSP. These tests pin the eval-free wrapper
/// forms and the CSP-refusal hint detector.
final class JSWrapperTests: XCTestCase {

    // MARK: - inlineExpression (#255; the properties #76 pinned on the old expression wrapper)

    func testInlineExpression_containsNoEval() {
        let wrapper = JSWrapper.inlineExpression("1 + 1")
        XCTAssertFalse(wrapper.contains("eval("))
        XCTAssertFalse(wrapper.contains("new Function"))
    }

    func testInlineExpression_inlinesCodeVerbatim() {
        let code = "document.querySelector('.msg').scrollTop"
        XCTAssertTrue(JSWrapper.inlineExpression(code).contains(code))
    }

    func testInlineExpression_reportsThroughItsOwnReply() {
        // The success and the catch(e) runtime-error branch both answer with the prefixed reply
        // JSCommand parses; the large-result branch parks the value for the slow path.
        let wrapper = JSWrapper.inlineExpression("1")
        XCTAssertTrue(wrapper.contains("'SB1:OK:' + r.length + ':' + r"))
        XCTAssertTrue(wrapper.contains("'SB1:ERR:' + m"))
        XCTAssertTrue(wrapper.contains("m = '' + (e && e.message !== undefined ? e.message : e)"),
                      "the thrown value is turned into text inside its own try, so the catch cannot throw")
        XCTAssertTrue(wrapper.contains("catch"))
    }

    func testInlineExpression_newlineGuardsAroundCode() {
        // A trailing line comment in user code must not swallow the closing
        // paren: `('' + (1+1 // c))` is a SyntaxError, `('' + (1+1 // c\n))`
        // is fine. Guard = newline between code and the closing paren.
        let wrapper = JSWrapper.inlineExpression("1+1 // trailing comment")
        XCTAssertTrue(wrapper.contains("1+1 // trailing comment\n"))
    }

    // MARK: - inlineStatement

    func testInlineStatement_containsNoEval() {
        let wrapper = JSWrapper.inlineStatement("var a = 2; a + 3;")
        XCTAssertFalse(wrapper.contains("eval("))
        XCTAssertFalse(wrapper.contains("new Function"))
    }

    func testInlineStatement_wrapsCodeAsFunctionBody() {
        // Statements run as a function body so `return` yields a value.
        let code = "var a = 2;\nreturn a + 3;"
        let wrapper = JSWrapper.inlineStatement(code)
        XCTAssertTrue(wrapper.contains(code))
        XCTAssertTrue(wrapper.contains("function"))
        XCTAssertTrue(wrapper.contains("'SB1:OK:' + r.length + ':' + r"))
        XCTAssertTrue(wrapper.contains("'SB1:ERR:' + m"))
    }

    func testInlineStatement_newlineGuardsAroundCode() {
        let wrapper = JSWrapper.inlineStatement("doWork() // done")
        XCTAssertTrue(wrapper.contains("doWork() // done\n"))
    }

    // MARK: - large-path forms

    func testLargeExpression_capturesRuntimeErrorsInBand() {
        // `do JavaScript` swallows uncaught runtime throws silently, so the
        // large forms must record them in the call's own slot in-band; user code
        // stays newline-guarded against trailing comments.
        let slot = ResultSlot.make()
        let form = JSWrapper.largeExpression("1+1 // c", slot: slot)
        XCTAssertTrue(form.contains("(\n1+1 // c\n)"))
        XCTAssertTrue(form.contains("var s = window.\(slot.key); if (s) { s.err = e.message; }"), form)
        XCTAssertTrue(form.contains("catch"))
        XCTAssertFalse(form.contains("eval("))
        XCTAssertFalse(form.contains("new Function"))
        XCTAssertFalse(form.contains("__sbLargeErr"), "a name every call shares (#190)")
    }

    func testLargeStatement_isFunctionBodyWithErrorCapture() {
        let slot = ResultSlot.make()
        let form = JSWrapper.largeStatement("var a = 1;\nreturn a;", slot: slot)
        XCTAssertTrue(form.contains("(function(){\nvar a = 1;\nreturn a;\n})()"))
        XCTAssertTrue(form.contains("s.err = e.message"), form)
        XCTAssertTrue(form.contains(slot.key))
        XCTAssertFalse(form.contains("eval("))
        XCTAssertFalse(form.contains("__sbLargeErr"))
    }

    func testLargeFormsRecordTheirErrorInTheSlotTheyWereGiven() {
        // run for real: the error ends up where `ResultSlot.errorScript` reads it
        let forms: [(ResultSlot) -> String] = [
            { JSWrapper.largeExpression("(function(){ throw new Error('boom') })()", slot: $0) },
            { JSWrapper.largeStatement("throw new Error('boom')", slot: $0) },
        ]
        for form in forms {
            let page = FakePage()
            let slot = ResultSlot.make()
            _ = page.evaluate(slot.presetScript)
            _ = page.evaluate(slot.storeScript(form(slot)))
            XCTAssertEqual(page.evaluate(slot.errorScript), "boom")
            XCTAssertEqual(page.evaluate(slot.lengthScript), "0", "the wrapper returned '' after recording: a length of 0, not the sentinel")
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

    // MARK: - parse-failure sentinel

    func testLenUnsetSentinel_matchesStringifiedUndefined() {
        // `do JavaScript` swallows SyntaxError silently (returns empty, no
        // error), so parse failure is detected by presetting the protocol
        // globals to undefined and reading back `'' + window.__sbLen`
        // (ToString coercion — immune to window.String reassignment):
        // "undefined" == the wrapper never ran.
        XCTAssertEqual(JSWrapper.lenUnsetSentinel, "undefined")
    }
}
