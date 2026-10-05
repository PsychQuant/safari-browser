/// #76: eval-free wrapper forms for the `js` command.
///
/// Strict-CSP pages (script-src without 'unsafe-eval' — facebook.com,
/// claude.ai, most modern sites) refuse page-context `eval()`. AppleScript
/// `do JavaScript` itself runs as UA-privileged script and is exempt from
/// the page CSP, so inlining user code directly into the injected string
/// works everywhere the old `eval(...)` wrapper was refused.
///
/// Two forms are needed because expressions and statement sequences cannot
/// share one wrapper: an expression inlined as `'' + (code)` preserves its
/// value (`js "1+1"` → "2"), while a statement sequence only parses as a
/// function body (`return` yields the value). `JSSyntaxHint` compiles the code
/// locally and JSCommand sends the one form that compiles; only when neither
/// does are both tried (a form Safari did not parse cannot have run, but "does not compile here" does not prove that).
///
/// Parse-failure detection: `do JavaScript` swallows SyntaxError silently
/// (returns no value at all and throws nothing — verified live), so a wrapper that parsed
/// and ran answers with a reply that starts with `inlinePrefix`, and any
/// other reply means it never ran (`parseInline`). Since #255 that reply IS
/// the outcome (value, error, or a marker that a large result is parked in
/// `window.__sbLen` / `window.__sbResult`), so a successful run is a single
/// `do JavaScript`. Before, the outcome went through page globals that were
/// preset, read back twice and cleaned up — four more round trips. Coercion is
/// `'' + x`, NOT `String(x)`, whose `window.String` binding page/user code can
/// reassign.
enum JSWrapper {

    /// The large path reads `'' + window.__sbResultLen` after injection and
    /// gets this when the wrapper never executed (parse failure of the whole string).
    static let lenUnsetSentinel = "undefined"

    /// Preset for the large path's protocol globals (doJavaScriptLarge
    /// uses __sbResult / __sbResultLen; __sbLargeErr carries runtime
    /// errors in-band — `do JavaScript` swallows uncaught runtime throws
    /// just as silently as SyntaxErrors, so without this capture a
    /// runtime error would misread as a parse failure).
    static let presetLargeProtocolGlobals =
        "window.__sbResult = void 0; window.__sbResultLen = void 0; window.__sbLargeErr = void 0"

    /// Large-path expression form. doJavaScriptLarge wraps its argument as
    /// `'' + (code)`, so this stays an expression: an IIFE with try/catch
    /// that records runtime errors to __sbLargeErr in-band (uncaught
    /// throws vanish silently in `do JavaScript`) and newline-guards the
    /// user code against trailing comments.
    static func largeExpression(_ code: String) -> String {
        "(function(){ try { return ('' + (\n\(code)\n)); } catch(e) { window.__sbLargeErr = e.message; return ''; } })()"
    }

    /// Large-path statement form: user code runs as a function body (use
    /// `return` for a value), same in-band runtime-error capture.
    static func largeStatement(_ code: String) -> String {
        "(function(){ try { return ('' + (function(){\n\(code)\n})()); } catch(e) { window.__sbLargeErr = e.message; return ''; } })()"
    }

    // MARK: - One-call protocol (#255)

    /// Every reply of the inline wrappers starts with this. Anything that does not is
    /// "the wrapper never ran" (see `parseInline`).
    static let inlinePrefix = "SB1:"

    /// Results longer than this (UTF-16 units) are not returned inline: the wrapper
    /// stores them under `window.__sbLen` / `window.__sbResult` and returns a marker, and
    /// `JSCommand` reads them with the existing read / chunked read / cleanup. The existing
    /// chunked read already moves 256 KiB per `do JavaScript` return, so this stays well
    /// inside what Safari is known to hand back.
    static let inlineResultLimit = 131_072

    /// What an inline wrapper's reply means.
    enum InlineOutcome: Equatable {
        /// The wrapper ran and the result is the payload.
        case value(String)
        /// The user's code threw; the message is the payload.
        case error(String)
        /// The result is larger than `inlineResultLimit` and sits in the page's globals.
        case stored(length: Int)
        /// The wrapper ran (it announced its length) but the payload that arrived is not that
        /// long: the reply was cut or altered on its way back. Never returned as a value, never
        /// a reason to run the code again.
        case damaged(expected: Int, actual: Int)
        /// No recognisable reply: a SyntaxError (Safari's `do JavaScript` swallows it and
        /// returns nothing), a navigation that lost the reply, or anything unexpected.
        /// Never read as a value; the caller decides between the navigation check, the other
        /// form and a "no reply" error (see `JSCommand.runNonLargePath`).
        case notRun
    }

    /// Expression form of the one-call protocol: the outcome is the wrapper's own return
    /// value (before #255 it was two page globals, preset and read back in later calls), so a
    /// successful run needs no preset, no read-back and no cleanup.
    static func inlineExpression(_ code: String) -> String {
        """
        (function(){ try { var r = '' + (
        \(code)
        ); \(inlineTail) } \(inlineCatch) })()
        """
    }

    /// Statement form of the one-call protocol (user code as a function body).
    static func inlineStatement(_ code: String) -> String {
        """
        (function(){ try { var r = '' + (function(){
        \(code)
        })(); \(inlineTail) } \(inlineCatch) })()
        """
    }

    /// Report what the user's code threw. Turning the thrown value into text can itself throw
    /// (`throw Symbol('x')` has no implicit string conversion, `throw Object.create(null)` has
    /// no `toString`), and an exception escaping the `catch` would be swallowed by `do
    /// JavaScript` like a SyntaxError and read as "no reply", so the conversion is guarded in
    /// two steps. No global names are used (page code can reassign `window.String`, #76).
    private static var inlineCatch: String {
        "catch(e) { var m; try { m = '' + (e && e.message !== undefined ? e.message : e); } catch(x) { try { m = e.toString(); } catch(y) { m = 'unprintable exception'; } } return 'SB1:ERR:' + m; }"
    }

    /// Shared tail: return the result inline, or park it in the globals the slow path reads.
    /// `toWellFormed()` first: a lone surrogate (`'😀'.slice(0, 1)`) is not text osascript can
    /// print, and it silently drops it, so the reply would arrive shorter than it says. Replaced
    /// by U+FFFD it is the same length and survives; the dropped character was lost either way.
    private static var inlineTail: String {
        "if (typeof r.toWellFormed === 'function') { r = r.toWellFormed(); } if (r.length > \(inlineResultLimit)) { window.__sbLen = r.length; window.__sbResult = r; return 'SB1:BIG:' + r.length + ':'; } return 'SB1:OK:' + r.length + ':' + r + '\\u001e';"
    }

    /// Closes an `OK` reply. It is not whitespace, so it keeps the end of the result away from
    /// what happens to the end of osascript's output: the runner removes trailing newlines
    /// (including the result's own last one, and with CRLF quirks), and the daemon path trims ALL
    /// trailing whitespace. With it, the payload arrives byte for byte and its length can be
    /// compared exactly; without it, a cut reply and a trimmed one look alike.
    static let inlineTerminator: Unicode.Scalar = "\u{1E}"

    /// Parse an inline wrapper's reply. Only the status and the length are parsed; the
    /// rest of the reply is the payload, whatever it contains.
    ///
    /// Everything here walks Unicode SCALARS, never Characters. A payload that starts with a
    /// combining mark, a variation selector or a joiner (`'\u{FE0F}x'`, an NFD string sliced
    /// after its base letter) fuses with the `:` before it into ONE Character, so a
    /// Character-based search for the separator finds none and a reply that did arrive reads as
    /// "no reply". That would run the code again with the other form.
    static func parseInline(_ raw: String) -> InlineOutcome {
        guard let rest = removing(inlinePrefix, from: raw.unicodeScalars[...]) else { return .notRun }
        if let message = removing("ERR:", from: rest) {
            return .error(String(message))
        }
        if let body = removing("OK:", from: rest) {
            guard let (length, tail) = splitLength(body) else { return .notRun }
            // The reply must end with the terminator and carry exactly `length` UTF-16 units
            // before it; anything else was cut or altered on the way back.
            guard tail.last == inlineTerminator else {
                return .damaged(expected: length, actual: String(tail).utf16.count)
            }
            let payload = String(tail.dropLast())
            let actual = payload.utf16.count
            guard actual == length else { return .damaged(expected: length, actual: actual) }
            return .value(droppingOneTrailingNewline(payload))
        }
        if let body = removing("BIG:", from: rest) {
            guard let (length, _) = splitLength(body) else { return .notRun }
            return .stored(length: length)
        }
        return .notRun
    }

    /// What `js` has always printed: the stateless runner removed the result's own last newline
    /// along with the one osascript adds, so a result of `"x\n"` printed as `x`. The reply now
    /// carries the result intact, and this keeps the output byte for byte what it was.
    private static func droppingOneTrailingNewline(_ text: String) -> String {
        var scalars = text.unicodeScalars
        if scalars.last == "\n" { scalars.removeLast() }
        return String(scalars)
    }

    /// `rest` without `prefix`, or `nil` when it does not start with it (scalar-wise).
    private static func removing(
        _ prefix: String, from rest: Substring.UnicodeScalarView
    ) -> Substring.UnicodeScalarView? {
        var index = rest.startIndex
        for scalar in prefix.unicodeScalars {
            guard index < rest.endIndex, rest[index] == scalar else { return nil }
            index = rest.index(after: index)
        }
        return rest[index...]
    }

    /// `<digits>:<payload>` -> (digits as an Int, payload). The digits must be 1-9 ASCII digits.
    private static func splitLength(
        _ body: Substring.UnicodeScalarView
    ) -> (Int, Substring.UnicodeScalarView)? {
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let digits = body[..<colon]
        guard (1...9).contains(digits.count),
              digits.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
              let length = Int(String(digits)) else { return nil }
        return (length, body[body.index(after: colon)...])
    }

    /// The AppleScript that runs the inline wrapper reads the tab's URL first and answers
    /// `URL GS reply` (`SafariBridge.doJavaScript(captureURL:)`). Split at the first GS only:
    /// the reply may itself contain the separator. `url` is `nil` only when there is no
    /// separator at all (the output did not come from a capturing script); a tab with no URL
    /// reads as `""`, which is a real answer — a blank tab that the code then navigates away
    /// from is still a navigation.
    static func splitCapturedURL(_ raw: String) -> (url: String?, output: String) {
        let scalars = raw.unicodeScalars
        guard let gs = scalars.firstIndex(of: "\u{1D}") else { return (nil, raw) }
        return (String(scalars[..<gs]), String(scalars[scalars.index(after: gs)...]))
    }

    /// Detects a CSP eval refusal in a JS error message and returns an
    /// actionable hint. After #76 the `js` wrapper itself is eval-free, so
    /// this only fires when the *user-provided* code calls eval()/new
    /// Function() on a strict-CSP page. Requires a CSP marker alongside
    /// the refusal phrase so user-authored errors that merely contain
    /// "Refused to evaluate" don't get a misleading hint.
    static func cspEvalHint(for message: String) -> String? {
        guard message.contains("Refused to evaluate"),
              message.contains("unsafe-eval") || message.contains("Content Security Policy")
        else { return nil }
        return """


        Hint: this page's Content-Security-Policy blocks eval() ('unsafe-eval'). \
        safari-browser itself no longer needs eval — this refusal comes from \
        eval()/new Function() inside the provided JavaScript. Rewrite the code \
        to avoid runtime string evaluation.
        """
    }
}
