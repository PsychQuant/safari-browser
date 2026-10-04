import JavaScriptCore
import XCTest
@testable import SafariBrowser

/// #255: the pure halves of `js`'s one-call protocol. The round-trip bound
/// itself (two AppleScripts on the success path) is pinned in
/// `JSCommandRoundTripTests`, against a fake Safari.
final class JSInlineProtocolTests: XCTestCase {

    // MARK: - parseInline

    func testAValueComesBackWithItsPayloadIntact() {
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:5:hello\u{1E}"), .value("hello"))
    }

    func testAnEmptyResultIsAValueNotANonRun() {
        // A legitimately empty result must stay distinguishable from "the wrapper never ran".
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:0:\u{1E}"), .value(""))
    }

    func testThePayloadMayContainColonsNewlinesAndTheFieldSeparator() {
        let payload = "a:b:c\nSB1:ERR:x\u{1D}y"
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:\(payload.utf16.count):\(payload)\u{1E}"), .value(payload),
                       "only the status and the length are parsed; everything after is the payload")
    }

    func testAnErrorCarriesItsMessage() {
        XCTAssertEqual(JSWrapper.parseInline("SB1:ERR:boom: it broke"), .error("boom: it broke"))
    }

    func testAnOversizedResultIsReportedAsStoredInTheSlotTheReplyNames() throws {
        let slot = try XCTUnwrap(ResultSlot(pageKey: "__sbr_k3j2h1g0abcd"))
        XCTAssertEqual(JSWrapper.parseInline("SB1:BIG:200000:__sbr_k3j2h1g0abcd"), .stored(slot: slot, length: 200000))
    }

    func testAnOversizedResultNamingAnInvalidSlotIsNeverReadAndNeverRunAgain() {
        // the name is pasted into scripts, so only the exact shape is accepted; the code did run, so
        // this is not `.notRun` (which two-form callers answer by running it again)
        for name in ["", "x", "__sbr_", "__sbr_short", "__sbr_k3j2h1g0abcd';alert(1);'", "__SBR_k3j2h1g0abcd",
                     "window.__sbr_k3j2h1g0abcd", "__sbr_k3j2h1g0abcd\n"] {
            XCTAssertEqual(JSWrapper.parseInline("SB1:BIG:200000:\(name)"), .invalidSlot, name.debugDescription)
        }
    }

    func testAPayloadThatStartsWithACombiningScalarStillParses() {
        // `:` followed by U+FE0F / U+0301 / a joiner is ONE Character, so a Character-based
        // parse finds no separator and reads a reply that arrived as "no reply" — and the
        // code would run again with the other form (#255 review).
        for lead in ["\u{FE0F}", "\u{0301}", "\u{200D}", "\u{3099}", "\u{1F3FB}"] {
            let payload = lead + "x"
            let n = payload.utf16.count
            XCTAssertEqual(JSWrapper.parseInline("SB1:OK:\(n):\(payload)\u{1E}"), .value(payload), lead.debugDescription)
            XCTAssertEqual(JSWrapper.parseInline("SB1:ERR:\(payload)"), .error(payload), lead.debugDescription)
        }
        // ...and a combining scalar glued to the `ERR` / `OK` / `BIG` status separators.
        XCTAssertEqual(JSWrapper.parseInline("SB1:ERR:\u{0301}"), .error("\u{0301}"))
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:1:\u{0301}\u{1E}"), .value("\u{0301}"))
        XCTAssertEqual(JSWrapper.parseInline("SB1:BIG:300000:\u{0301}"), .invalidSlot,
                       "a name that starts with a combining mark is not a slot name; it is parsed by scalar and refused")
    }

    func testAReplyWhoseLengthDisagreesWithItsPayloadIsDamagedNotAValue() {
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:10:hello\u{1E}"), .damaged(expected: 10, actual: 5))
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:7:hello\u{1E}"), .damaged(expected: 7, actual: 5))
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:6:hello\u{1E}"), .damaged(expected: 6, actual: 5),
                       "exact: there is no one-unit tolerance any more")
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:2:hello\u{1E}"), .damaged(expected: 2, actual: 5))
        // length is counted in UTF-16 units, as JavaScript counts it
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:2:\u{1F600}\u{1E}"), .value("\u{1F600}"))
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:1:\u{1F600}\u{1E}"), .damaged(expected: 1, actual: 2))
        // a reply whose end marker never arrived was cut, whatever its length says
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:5:hello"), .damaged(expected: 5, actual: 5))
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:9:hel"), .damaged(expected: 9, actual: 3))
    }

    func testTheEndMarkerKeepsTrailingWhitespaceIntactAndOneNewlineIsDroppedAsAlwaysBefore() {
        // Measured on a real Safari (#255): the runner strips the trailing newline osascript adds
        // AND the result's own last one, and the daemon path trims all trailing whitespace. The end
        // marker keeps the payload whole, so the length is compared exactly and a result such as
        // 'a  ' is not mistaken for a cut reply. The value then loses ONE trailing newline, which is
        // what `js` has always printed.
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:2:x\n\u{1E}"), .value("x"))
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:3:a\n\n\u{1E}"), .value("a\n"))
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:1:\n\u{1E}"), .value(""))
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:3:x\r\n\u{1E}"), .value("x\r"))
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:3:a\n\r\u{1E}"), .value("a\n\r"),
                       "the runner's CRLF handling used to delete a newline here")
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:3:a  \u{1E}"), .value("a  "),
                       "trailing spaces survive the daemon's whitespace trimming")
        XCTAssertEqual(JSWrapper.parseInline("SB1:OK:1:\u{1E}\u{1E}"), .value("\u{1E}"),
                       "only the LAST scalar is the end marker")
    }

    func testAnythingElseMeansTheWrapperDidNotRun() {
        // Safari's `do JavaScript` swallows a SyntaxError and returns nothing; a navigation
        // can lose the reply. Both must fall through to the existing slow path, never be
        // read as a value.
        for raw in ["", "undefined", "missing value", "5.0", "SB1:", "SB1:OK:", "SB1:OK:x:oops",
                    "SB1:OK:+5:hello", "SB1:OK:-1:", "SB1:OK:1234567890:x", "SB1:OK: 5:hello",
                    "SB1:BIG:x:__sbr_k3j2h1g0abcd", "SB1:BIG:-3:__sbr_k3j2h1g0abcd", "SB1:WAT:1:y", "sb1:OK:1:y", " SB1:OK:1:y"] {
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

    func testABlankTabsEmptyURLIsStillAnAnswerAndOnlyAMissingSeparatorIsNil() {
        // A blank tab that the code then navigates away from IS a navigation: its URL before the
        // run is "", not "unknown" (the old `try? getCurrentURL` also answered "").
        let blank = JSWrapper.splitCapturedURL("\u{1D}SB1:OK:0:")
        XCTAssertEqual(blank.url, "")
        XCTAssertEqual(blank.output, "SB1:OK:0:")
        let bare = JSWrapper.splitCapturedURL("SB1:OK:0:")
        XCTAssertNil(bare.url)
        XCTAssertEqual(bare.output, "SB1:OK:0:")
    }

    func testAReplyThatStartsWithACombiningScalarKeepsItAfterTheSeparator() {
        let split = JSWrapper.splitCapturedURL("https://a.example/\u{1D}\u{0301}tail")
        XCTAssertEqual(split.url, "https://a.example/")
        XCTAssertEqual(split.output, "\u{0301}tail")
    }

    // MARK: - wrapper text

    func testTheInlineWrappersKeepTheUserCodeOnItsOwnLinesAndNeverEval() {
        let code = "1 + 1 // trailing comment"
        for wrapper in [JSWrapper.inlineExpression(code), JSWrapper.inlineStatement(code)] {
            XCTAssertTrue(wrapper.contains("\n\(code)\n"),
                          "a trailing // comment must not swallow the closing paren: \(wrapper)")
            XCTAssertFalse(wrapper.contains("eval("), "strict-CSP pages refuse eval (#76)")
            XCTAssertNil(wrapper.range(of: #"(^|[^A-Za-z.])String\("#, options: .regularExpression),
                         "page code can reassign window.String (#76); `e.toString()` is a method, not the global")
            XCTAssertTrue(wrapper.contains("'SB1:OK:'") && wrapper.contains("'SB1:ERR:'") && wrapper.contains("'SB1:BIG:'"))
            XCTAssertTrue(wrapper.contains("+ '\\u001e';"), "an OK reply ends with the end marker: \(wrapper)")
        }
    }

    func testAnOversizedResultIsParkedInASlotTheWrapperNames() {
        let wrapper = JSWrapper.inlineExpression("x")
        XCTAssertTrue(wrapper.contains("window[k] = { text: r, len: r.length }"), wrapper)
        XCTAssertTrue(wrapper.contains("'SB1:BIG:' + r.length + ':' + k"), wrapper)
        XCTAssertTrue(wrapper.contains("r.length > \(JSWrapper.inlineResultLimit)"), wrapper)
        for old in ["__sbResult", "__sbLen", "__sbResultLen"] {
            XCTAssertFalse(wrapper.contains(old), "\(old) is shared by every call (#190)")
        }
    }

    func testTheWrapperTextDoesNotDependOnTheCall() {
        // The name is picked by the page. A name picked by the CLI would sit in the text, make every
        // `js` script unique, and the daemon would compile each anew instead of reusing it.
        XCTAssertEqual(JSWrapper.inlineExpression("document.title"), JSWrapper.inlineExpression("document.title"))
        XCTAssertEqual(JSWrapper.inlineStatement("return 1"), JSWrapper.inlineStatement("return 1"))
    }

    func testTheInlineLimitIsNoLargerThanTheChunkTheSlowPathReads() {
        XCTAssertLessThanOrEqual(JSWrapper.inlineResultLimit, 262_144)
    }

    // MARK: - JSSyntaxHint

    func testAnExpressionIsRunAsAnExpressionOnly() {
        for code in ["1 + 1", "document.title", "location.host\n// comment", "({a: 1})", "[1,2,3].map(x => x * 2)"] {
            XCTAssertEqual(JSSyntaxHint.formsToTry(for: code), [.expression], code)
        }
    }

    func testStatementsAreRunAsStatementsOnly() {
        for code in ["var a = 1; a", "return 5", "const x = document.title; return x", "if (a) { b() }\nc()"] {
            XCTAssertEqual(JSSyntaxHint.formsToTry(for: code), [.statement], code)
        }
    }

    func testCodeThatParsesNeitherWayKeepsBothFormsExpressionFirst() {
        // Only here, and for inputs the hint skips, are both forms tried (the old behaviour).
        for code in ["1 +", "function (", "}{"] {
            XCTAssertEqual(JSSyntaxHint.formsToTry(for: code), [.expression, .statement], code)
        }
    }

    func testTheHintCompilesButNeverRunsTheCode() {
        // `new Function(body)` compiles; it must not execute the body. `for(;;){}` is a function
        // body that parses and never returns: if the hint ran it, this call would never come back,
        // which the deadline turns into a failure instead of a hung suite.
        var forms: [JSSyntaxHint.Form]?
        let done = expectation(description: "the hint returns")
        DispatchQueue.global().async {
            forms = JSSyntaxHint.formsToTry(for: "for(;;){}")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(forms, [.statement])
    }

    func testAHugeInputSkipsTheHintInsteadOfCompilingIt() {
        let huge = String(repeating: "a", count: JSSyntaxHint.maxHintedLength + 1)
        XCTAssertEqual(JSSyntaxHint.formsToTry(for: huge), [.expression, .statement])
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
        XCTAssertEqual(execute(JSWrapper.inlineExpression("1 + 1")).reply, "SB1:OK:1:2\u{1E}")
        XCTAssertEqual(execute(JSWrapper.inlineExpression("''")).reply, "SB1:OK:0:\u{1E}")
        XCTAssertEqual(execute(JSWrapper.inlineExpression("'a:b\\nc'")).reply, "SB1:OK:5:a:b\nc\u{1E}")
    }

    func testATrailingCommentCannotSwallowTheClosingParen() {
        XCTAssertEqual(execute(JSWrapper.inlineExpression("'a' + 'b' // trailing")).reply, "SB1:OK:2:ab\u{1E}")
        XCTAssertEqual(execute(JSWrapper.inlineStatement("return 'q' // trailing")).reply, "SB1:OK:1:q\u{1E}")
    }

    func testStatementsRunAsAFunctionBody() {
        XCTAssertEqual(execute(JSWrapper.inlineStatement("var a = 2; return a + 3")).reply, "SB1:OK:1:5\u{1E}")
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

    func testAThrownValueThatCannotBeTurnedIntoTextStillGetsAReply() {
        // Converting the thrown value can itself throw; an exception escaping the `catch` is
        // swallowed by `do JavaScript` like a SyntaxError and would read as "no reply".
        XCTAssertEqual(execute(JSWrapper.inlineStatement("throw Symbol('s')")).reply, "SB1:ERR:Symbol(s)")
        XCTAssertEqual(execute(JSWrapper.inlineStatement("throw Object.create(null)")).reply,
                       "SB1:ERR:unprintable exception")
        XCTAssertEqual(execute(JSWrapper.inlineExpression(
            "(function(){ throw { get message() { throw new Error('nested') } } })()")).reply,
                       "SB1:ERR:[object Object]")
    }

    func testAnOversizedResultIsParkedInItsOwnSlotAndReportedBig() throws {
        let big = JSWrapper.inlineResultLimit + 1
        let run = execute(JSWrapper.inlineExpression("'x'.repeat(\(big))"))
        let reply = try XCTUnwrap(run.reply)
        XCTAssertTrue(reply.hasPrefix("SB1:BIG:\(big):"), String(reply.prefix(60)))
        let name = String(reply.dropFirst("SB1:BIG:\(big):".count))
        let slot = try XCTUnwrap(ResultSlot(pageKey: name), "the name the page picks must be one the CLI accepts: \(name)")
        XCTAssertEqual(run.window.forProperty(slot.key)?.forProperty("len")?.toInt32(), Int32(big))
        XCTAssertEqual(run.window.forProperty(slot.key)?.forProperty("text")?.toString()?.count, big)
        for old in ["__sbLen", "__sbResult", "__sbResultLen"] {
            XCTAssertTrue(run.window.forProperty(old)?.isUndefined ?? false, "\(old) must not be written any more")
        }
        // exactly at the limit still comes back inline
        XCTAssertEqual(execute(JSWrapper.inlineExpression("'x'.repeat(\(JSWrapper.inlineResultLimit))")).reply?
            .hasPrefix("SB1:OK:\(JSWrapper.inlineResultLimit):"), true)
    }

    func testTwoOversizedResultsOnOnePageGetTwoSlots() throws {
        let context = JSContext()!
        context.evaluateScript("var window = this;")
        let big = JSWrapper.inlineResultLimit + 1
        let a = try XCTUnwrap(context.evaluateScript(JSWrapper.inlineExpression("'a'.repeat(\(big))"))?.toString())
        let b = try XCTUnwrap(context.evaluateScript(JSWrapper.inlineExpression("'b'.repeat(\(big))"))?.toString())
        XCTAssertNotEqual(a, b, "the same name would be the shared slot of #190")
        for (reply, letter) in [(a, "a"), (b, "b")] {
            let name = String(reply.dropFirst("SB1:BIG:\(big):".count))
            let slot = try XCTUnwrap(ResultSlot(pageKey: name))
            XCTAssertEqual(context.evaluateScript("window.\(slot.key).text.charAt(0)")?.toString(), letter)
        }
    }

    func testALoneSurrogateIsReplacedSoTheReplyKeepsItsLength() {
        // osascript silently drops a lone surrogate (measured on a real Safari); U+FFFD is the
        // same length and survives. Checked INSIDE JavaScript: bridging a JS string to a Swift
        // String replaces a lone surrogate itself, so a Swift-side comparison cannot tell whether
        // the wrapper did it.
        for (code, units) in [("'ab' + '\\uD83D'", 3), ("'\\uDE00x'", 2), ("'\\uD83D\\uD83D'", 2)] {
            let context = JSContext()!
            context.evaluateScript("var window = this;")
            context.evaluateScript("var __reply = \(JSWrapper.inlineExpression(code));")
            XCTAssertEqual(context.evaluateScript("__reply.isWellFormed()")?.toBool(), true, code)
            XCTAssertEqual(context.evaluateScript("__reply.length")?.toInt32(), Int32("SB1:OK:\(units):".utf16.count + units + 1), code)
        }
        XCTAssertEqual(execute(JSWrapper.inlineExpression("'ab' + '\\uD83D'")).reply, "SB1:OK:3:ab\u{FFFD}\u{1E}")
        XCTAssertEqual(execute(JSWrapper.inlineExpression("'\u{1F600}'")).reply, "SB1:OK:2:\u{1F600}\u{1E}",
                       "a well-formed pair is left alone")
    }

    func testAnInlineResultLeavesNothingBehindInThePage() {
        let run = execute(JSWrapper.inlineExpression("'hello'"))
        XCTAssertEqual(run.reply, "SB1:OK:5:hello\u{1E}")
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
            XCTAssertEqual(JSSyntaxHint.formsToTry(for: code), [.statement], code)
        }
        for code in ["1 + 1", "({a: 1})"] {
            XCTAssertNotNil(execute(JSWrapper.inlineExpression(code)).reply, code)
            XCTAssertEqual(JSSyntaxHint.formsToTry(for: code), [.expression], code)
        }
    }
    // MARK: - the AppleScript that reads the URL in the same call

    func testWithoutCaptureTheStatementIsTheOriginalOne() {
        XCTAssertEqual(SafariBridge.doJavaScriptStatement("x\"y", in: "tab 3 of _w", captureURL: false),
                       "do JavaScript \"x\\\"y\" in tab 3 of _w")
        XCTAssertEqual(SafariBridge.urlCaptureStatement(in: "_t", captureURL: false), "")
    }

    func testCaptureReadsTheURLFirstAndSurvivesMissingValues() {
        let read = SafariBridge.urlCaptureStatement(in: "_t", captureURL: true)
        let run = SafariBridge.doJavaScriptStatement("1", in: "_t", captureURL: true)
        XCTAssertTrue(read.contains("try\n        set _u to URL of _t\n    end try"),
                      "a tab that cannot answer a URL must not fail the run: \(read)")
        XCTAssertTrue(read.contains("if _u is missing value then set _u to \"\""), "a blank tab has no URL: \(read)")
        XCTAssertTrue(run.hasPrefix("set _r to do JavaScript \"1\" in _t"), run)
        XCTAssertTrue(run.contains("return _u & (character id 29) & _r"), run)
    }

    /// Run AppleScript that never talks to an application and return its string result, or the
    /// error number (as `error -N`).
    private func runAppleScript(_ source: String) -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { return "error \(error["NSAppleScriptErrorNumber"] ?? "?")" }
        return result?.stringValue ?? "nil"
    }

    func testAReplyThatNeverCameBackBecomesAnEmptyReplyNotAnUndefinedVariable() {
        // Measured on a real Safari: a SyntaxError makes `do JavaScript` return no value at all and
        // `_r` is then undefined. `delay 0` is a command with no result, which behaves the same.
        let tail = SafariBridge.captureReplyTail
        XCTAssertEqual(runAppleScript("set _u to \"U\"\nset _r to (delay 0)\n" + tail), "U\u{1D}",
                       "no value: an empty reply, never -2753 (a swallowed SyntaxError must reach the retry logic)")
        XCTAssertEqual(runAppleScript("set _u to \"U\"\nset _r to \"ok\"\n" + tail), "U\u{1D}ok")
        XCTAssertEqual(runAppleScript("set _u to \"U\"\nset _r to missing value\n" + tail), "U\u{1D}")
        XCTAssertEqual(runAppleScript("set _u to \"U\"\nset _r to \"\"\n" + tail), "U\u{1D}")
        // the control: without the guard the same script dies with -2753
        XCTAssertEqual(runAppleScript("set _u to \"U\"\nset _r to (delay 0)\nreturn _u & _r"), "error -2753")
    }

    // MARK: - every dispatch shape: order, byte-identity without capture, and it compiles

    /// Quotes, a backslash, AppleScript keywords and a `//` comment: nothing in the user's code
    /// may end the AppleScript string it is embedded in.
    private let hostile = #"'"' + "\\" + 'tell application "System Events"' // end tell"#
    private let urlMatch = SafariBridge.UrlMatcher.contains("plaud")

    private func shapes(_ code: String, capture: Bool) -> [(name: String, script: String)] {
        let cases: [(String, SafariBridge.TargetDocument)] = [
            ("anchoredCurrentTab", .anchoredCurrentTab(windowID: 77, tabInWindow: 4, profile: nil)),
            ("plain", .frontWindow),
            ("resolvedTab without matcher", .resolvedTab(windowID: 77, tabInWindow: 4, rematch: nil, profile: nil)),
            ("resolvedTab with substring guard",
             .resolvedTab(windowID: 77, tabInWindow: 4, rematch: urlMatch, profile: nil)),
            ("resolvedTab with regex matcher (script after the Swift pre-check)",
             .resolvedTab(windowID: 77, tabInWindow: 4,
                          rematch: SafariBridge.UrlMatcher.regex(try! NSRegularExpression(pattern: "p.+d")), profile: nil)),
        ]
        return cases.map { name, target in
            (name, SafariBridge.jsDispatchScript(
                code, docRef: "tab 4 of window id 77", target: target, captureURL: capture))
        }
    }

    func testEveryShapeReadsTheURLBeforeAnyGuardAndRunsTheCodeRightAfterTheGuard() {
        for (name, script) in shapes(hostile, capture: true) {
            let urlRead = script.range(of: "set _u to URL of")
            let guardAt = script.range(of: "SB_TARGET_CHANGED")
            let run = script.range(of: "set _r to do JavaScript")
            XCTAssertNotNil(urlRead, name); XCTAssertNotNil(run, name)
            XCTAssertLessThan(urlRead!.lowerBound, run!.lowerBound, name)
            if let guardAt {
                XCTAssertLessThan(urlRead!.lowerBound, guardAt.lowerBound,
                                  "the URL read must not sit between the guard and the code it protects: \(name)")
                XCTAssertLessThan(guardAt.lowerBound, run!.lowerBound, name)
            }
            XCTAssertEqual(script.components(separatedBy: "set _r to do JavaScript").count, 2, "\(name): the code runs once")
        }
    }

    func testWithoutCaptureEveryShapeIsExactlyTheScriptItWasBeforeThisChange() {
        // No blank line, no `_u`: the stateless commands that share this dispatch are untouched.
        for (name, script) in shapes("1", capture: false) {
            XCTAssertFalse(script.contains("_u"), name)
            XCTAssertTrue(script.split(separator: "\n", omittingEmptySubsequences: false)
                            .allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                          "no blank or whitespace-only line: \(name)\n\(script)")
            XCTAssertTrue(script.hasPrefix("tell application \"Safari\"\n"), name)
            XCTAssertTrue(script.hasSuffix("\nend tell"), name)
            XCTAssertTrue(script.contains("\n    do JavaScript \"1\" in "), name)
        }
    }

    func testEveryShapeCompilesAsAppleScriptEvenWithHostileCode() {
        // Compiling sends no Apple event. A shape that does not compile is a command that cannot
        // run at all, which no fake-Safari test would ever notice.
        for capture in [false, true] {
            for (name, script) in shapes(hostile, capture: capture) {
                var error: NSDictionary?
                let ok = NSAppleScript(source: script)?.compileAndReturnError(&error) ?? false
                XCTAssertTrue(ok, "\(name) capture=\(capture): \(String(describing: error?["NSAppleScriptErrorMessage"]))\n\(script)")
            }
        }
    }
}
