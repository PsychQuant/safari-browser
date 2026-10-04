import JavaScriptCore
import XCTest
@testable import SafariBrowser

/// #255: the pure halves of `js`'s one-call protocol. The round-trip bound
/// itself (two AppleScripts on the success path) is pinned in
/// `JSCommandRoundTripTests`, against a fake Safari.
final class JSInlineProtocolTests: XCTestCase {

    // MARK: - parseInline

    func testAValueComesBackWithItsPayloadIntact() {
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:5:hello"), .value("hello"))
    }

    func testAnEmptyResultIsAValueNotANonRun() {
        // A legitimately empty result must stay distinguishable from "the wrapper never ran".
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:0:"), .value(""))
    }

    func testThePayloadMayContainColonsNewlinesAndTheFieldSeparator() {
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:19:a:b:c\nSB1:ERR:x\u{1D}y"),
                       .value("a:b:c\nSB1:ERR:x\u{1D}y"),
                       "only the status and the length are parsed; everything after is the payload")
    }

    func testAnErrorCarriesItsMessage() {
        XCTAssertEqual(JSWrapper.parseInline("SB1:ERR:boom: it broke"), .error("boom: it broke"))
    }

    func testAnOversizedResultIsReportedAsStored() {
        XCTAssertEqual(JSWrapper.parseInline("SB1:BIG:200000:"), .stored(length: 200000))
    }

    func testAnythingElseMeansTheWrapperDidNotRun() {
        // Safari's `do JavaScript` swallows a SyntaxError and returns nothing; a navigation
        // can lose the reply. Both must fall through to the existing slow path, never be
        // read as a value.
        for raw in ["", "undefined", "missing value", "5.0", "SB1:", "SB1:OK:", "SB1:OK:x:oops",
                    "SB1:BIG:x:", "SB1:WAT:1:y", "sb1:OK:1:y", " SB1:OK:1:y"] {
            XCTAssertEqual(JSWrapper.parseInline(raw), .notRun, "\(raw.debugDescription)")
        }
    }

    // MARK: - splitCapturedURL

    func testTheURLReadInTheSameScriptIsSplitOffTheReply() {
        let split = JSWrapper.splitCapturedURL("https://a.example/p?q=1#f\u{1D}SB1:OK:2:hi")
        XCTAssertEqual(split.url, "https://a.example/p?q=1#f")
        XCTAssertEqual(split.output, "SB1:OK:2:hi")
    }

    func testOnlyTheFirstFieldSeparatorSplits() {
        let split = JSWrapper.splitCapturedURL("https://a.example/\u{1D}SB1:OK:3:a\u{1D}b")
        XCTAssertEqual(split.url, "https://a.example/")
        XCTAssertEqual(split.output, "SB1:OK:3:a\u{1D}b")
    }

    func testAnEmptyURLIsNilAndAReplyWithoutASeparatorIsAllOutput() {
        XCTAssertNil(JSWrapper.splitCapturedURL("\u{1D}SB1:OK:0:").url)
        let bare = JSWrapper.splitCapturedURL("SB1:OK:0:")
        XCTAssertNil(bare.url)
        XCTAssertEqual(bare.output, "SB1:OK:0:")
    }

    // MARK: - wrapper text

    func testTheInlineWrappersKeepTheUserCodeOnItsOwnLinesAndNeverEval() {
        let code = "1 + 1 // trailing comment"
        for wrapper in [JSWrapper.inlineExpression(code), JSWrapper.inlineStatement(code)] {
            XCTAssertTrue(wrapper.contains("\n\(code)\n"),
                          "a trailing // comment must not swallow the closing paren: \(wrapper)")
            XCTAssertFalse(wrapper.contains("eval("), "strict-CSP pages refuse eval (#76)")
            XCTAssertFalse(wrapper.contains("String("), "page code can reassign window.String (#76)")
            XCTAssertTrue(wrapper.contains("'SB1:OK:'") && wrapper.contains("'SB1:ERR:'") && wrapper.contains("'SB1:BIG:'"))
        }
    }

    func testAnOversizedResultIsStoredUnderTheNamesTheSlowPathReads() {
        let wrapper = JSWrapper.inlineExpression("x")
        XCTAssertTrue(wrapper.contains("window.__sbLen = r.length") && wrapper.contains("window.__sbResult = r"),
                      "the stored branch hands off to the existing read / chunked read / cleanup")
        XCTAssertTrue(wrapper.contains("r.length > \(JSWrapper.inlineResultLimit)"), wrapper)
    }

    func testTheInlineLimitStaysUnderTheChunkSizeTheExistingReadAlreadyProves() {
        XCTAssertLessThanOrEqual(JSWrapper.inlineResultLimit, 262_144)
    }

    // MARK: - JSSyntaxHint

    func testAnExpressionIsTriedAsAnExpressionFirst() {
        for code in ["1 + 1", "document.title", "location.host\n// comment", "({a: 1})", "[1,2,3].map(x => x * 2)"] {
            XCTAssertEqual(JSSyntaxHint.preferredOrder(for: code), [.expression, .statement], code)
        }
    }

    func testStatementsAreTriedAsStatementsFirst() {
        for code in ["var a = 1; a", "return 5", "const x = document.title; return x", "if (a) { b() }\nc()"] {
            XCTAssertEqual(JSSyntaxHint.preferredOrder(for: code), [.statement, .expression], code)
        }
    }

    func testCodeThatParsesNeitherWayKeepsTheExistingOrder() {
        // The hint only orders the attempts; Safari stays the final judge, so an unparseable
        // input must behave exactly as before (expression first, then statements).
        for code in ["1 +", "function (", "}{"] {
            XCTAssertEqual(JSSyntaxHint.preferredOrder(for: code), [.expression, .statement], code)
        }
    }

    func testTheHintCompilesButNeverRunsTheCode() {
        // `new Function(body)` compiles; it must not execute the body. A side effect here would
        // run the user's code in the CLI process.
        let order = JSSyntaxHint.preferredOrder(for: "throw new Error('ran'); var x = 1")
        XCTAssertEqual(order, [.statement, .expression])
        XCTAssertEqual(JSSyntaxHint.preferredOrder(for: "(function(){ throw new Error('ran') })()"),
                       [.expression, .statement])
    }

    func testAHugeInputSkipsTheHintInsteadOfCompilingIt() {
        let huge = String(repeating: "a", count: JSSyntaxHint.maxHintedLength + 1)
        XCTAssertEqual(JSSyntaxHint.preferredOrder(for: huge), [.expression, .statement])
    }
    // MARK: - the wrappers, executed (JavaScriptCore is the engine Safari uses)

    /// Run a wrapper the way `do JavaScript` would: as a script in a page whose global object is
    /// `window`. `nil` = the script threw (Safari's `do JavaScript` swallows that and answers nothing).
    private func execute(_ wrapper: String) -> (reply: String?, window: JSValue) {
        let context = JSContext()!
        var threw = false
        context.exceptionHandler = { _, _ in threw = true }
        context.evaluateScript("var window = this;")
        let value = context.evaluateScript(wrapper)
        let reply = threw ? nil : value?.toString()
        return (reply, context.objectForKeyedSubscript("window"))
    }

    func testExpressionRunsAndReturnsItsValueInline() {
        XCTAssertEqual(execute(JSWrapper.inlineExpression("1 + 1")).reply, "SB1:OK:1:2")
        XCTAssertEqual(execute(JSWrapper.inlineExpression("''")).reply, "SB1:OK:0:")
        XCTAssertEqual(execute(JSWrapper.inlineExpression("'a:b\\nc'")).reply, "SB1:OK:5:a:b\nc")
    }

    func testATrailingCommentCannotSwallowTheClosingParen() {
        XCTAssertEqual(execute(JSWrapper.inlineExpression("'a' + 'b' // trailing")).reply, "SB1:OK:2:ab")
        XCTAssertEqual(execute(JSWrapper.inlineStatement("return 'q' // trailing")).reply, "SB1:OK:1:q")
    }

    func testStatementsRunAsAFunctionBody() {
        XCTAssertEqual(execute(JSWrapper.inlineStatement("var a = 2; return a + 3")).reply, "SB1:OK:1:5")
    }

    func testARuntimeErrorIsAReplyNotAThrow() {
        XCTAssertEqual(execute(JSWrapper.inlineExpression("(function(){ throw new Error('boom') })()")).reply,
                       "SB1:ERR:boom")
        XCTAssertEqual(execute(JSWrapper.inlineStatement("throw new TypeError('bad')")).reply, "SB1:ERR:bad")
    }

    func testAThrownNonErrorIsReportedAsTheThrownValue() {
        XCTAssertEqual(execute(JSWrapper.inlineStatement("throw 'x'")).reply, "SB1:ERR:x")
        XCTAssertEqual(execute(JSWrapper.inlineStatement("throw null")).reply, "SB1:ERR:null")
    }

    func testAnOversizedResultIsParkedInTheGlobalsAndReportedBig() {
        let big = JSWrapper.inlineResultLimit + 1
        let run = execute(JSWrapper.inlineExpression("'x'.repeat(\(big))"))
        XCTAssertEqual(run.reply, "SB1:BIG:\(big):")
        XCTAssertEqual(run.window.forProperty("__sbLen")?.toInt32(), Int32(big))
        XCTAssertEqual(run.window.forProperty("__sbResult")?.toString()?.count, big)
        // exactly at the limit still comes back inline
        XCTAssertEqual(execute(JSWrapper.inlineExpression("'x'.repeat(\(JSWrapper.inlineResultLimit))")).reply?
            .hasPrefix("SB1:OK:\(JSWrapper.inlineResultLimit):"), true)
    }

    func testAnInlineResultLeavesNothingBehindInThePage() {
        let run = execute(JSWrapper.inlineExpression("'hello'"))
        XCTAssertEqual(run.reply, "SB1:OK:5:hello")
        XCTAssertTrue(run.window.forProperty("__sbLen")?.isUndefined ?? false, "no globals on the success path")
        XCTAssertTrue(run.window.forProperty("__sbResult")?.isUndefined ?? false)
    }

    func testACodeSyntaxErrorMakesTheWholeScriptNotRunSoTheReplyIsEmpty() {
        // The wrapper never parses, nothing runs, and Safari answers nothing: `parseInline("")`.
        XCTAssertNil(execute(JSWrapper.inlineExpression("1 +")).reply)
        XCTAssertEqual(JSWrapper.parseInline(""), .notRun)
    }

    func testTheExpressionFormDoesNotParseStatementsAndTheHintAgrees() {
        // The hint compiles the same bodies the wrappers contain, so it predicts what Safari does.
        for code in ["var a = 1; a", "return 5", "if (a) { b() }\nc()"] {
            XCTAssertNil(execute(JSWrapper.inlineExpression(code)).reply, code)
            XCTAssertEqual(JSSyntaxHint.preferredOrder(for: code).first, .statement, code)
        }
        for code in ["1 + 1", "({a: 1})"] {
            XCTAssertNotNil(execute(JSWrapper.inlineExpression(code)).reply, code)
            XCTAssertEqual(JSSyntaxHint.preferredOrder(for: code).first, .expression, code)
        }
    }
    // MARK: - the AppleScript that reads the URL in the same call

    func testWithoutCaptureTheStatementIsTheOriginalOne() {
        XCTAssertEqual(SafariBridge.doJavaScriptStatement("x\"y", in: "tab 3 of _w", captureURL: false),
                       "do JavaScript \"x\\\"y\" in tab 3 of _w")
    }

    func testCaptureReadsTheURLFirstAndSurvivesMissingValues() {
        let s = SafariBridge.doJavaScriptStatement("1", in: "_t", captureURL: true)
        let urlRead = s.range(of: "set _u to URL of _t")
        let run = s.range(of: "set _r to do JavaScript")
        XCTAssertNotNil(urlRead); XCTAssertNotNil(run)
        XCTAssertLessThan(urlRead!.lowerBound, run!.lowerBound, "the URL is the one BEFORE the code runs")
        XCTAssertTrue(s.contains("try\n") && s.contains("end try"), "a tab that cannot answer a URL must not fail the run: \(s)")
        XCTAssertTrue(s.contains("if _u is missing value then set _u to \"\""), "a blank tab has no URL: \(s)")
        XCTAssertTrue(s.contains("if _r is missing value then set _r to \"\""),
                      "a swallowed SyntaxError returns nothing and `&` cannot concatenate it: \(s)")
        XCTAssertTrue(s.contains("return _u & (character id 29) & _r"), s)
    }
}

