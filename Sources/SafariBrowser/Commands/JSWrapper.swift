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
/// function body (`return` yields the value). JSCommand tries one form and
/// falls back to the other when the injected wrapper never ran
/// (`JSSyntaxHint` decides which goes first).
///
/// Parse-failure detection: `do JavaScript` swallows SyntaxError silently
/// (returns empty, throws nothing — verified live), so a wrapper that parsed
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
        /// No recognisable reply: a SyntaxError (Safari's `do JavaScript` swallows it and
        /// returns nothing), a navigation that lost the reply, or anything unexpected.
        /// Never read as a value; the caller falls back to the navigation / retry path.
        case notRun
    }

    /// Expression form of the one-call protocol. Same shape as `expressionWrapper`, but
    /// the outcome is the wrapper's own return value instead of two page globals read back
    /// in later calls, so a successful run needs no preset, no read-back and no cleanup.
    static func inlineExpression(_ code: String) -> String {
        """
        (function(){ try { var r = '' + (
        \(code)
        ); \(inlineTail) } catch(e) { return 'SB1:ERR:' + (e && e.message !== undefined ? e.message : e); } })()
        """
    }

    /// Statement form of the one-call protocol (user code as a function body).
    static func inlineStatement(_ code: String) -> String {
        """
        (function(){ try { var r = '' + (function(){
        \(code)
        })(); \(inlineTail) } catch(e) { return 'SB1:ERR:' + (e && e.message !== undefined ? e.message : e); } })()
        """
    }

    /// Shared tail: return the result inline, or park it in the globals the slow path reads.
    private static var inlineTail: String {
        "if (r.length > \(inlineResultLimit)) { window.__sbLen = r.length; window.__sbResult = r; return 'SB1:BIG:' + r.length + ':'; } return 'SB1:OK:' + r.length + ':' + r;"
    }

    /// Parse an inline wrapper's reply. Only the status and the length are parsed; the
    /// rest of the reply is the payload, whatever it contains.
    static func parseInline(_ raw: String) -> InlineOutcome {
        guard raw.hasPrefix(inlinePrefix) else { return .notRun }
        let rest = raw.dropFirst(inlinePrefix.count)
        if rest.hasPrefix("ERR:") {
            return .error(String(rest.dropFirst("ERR:".count)))
        }
        if rest.hasPrefix("OK:") {
            let body = rest.dropFirst("OK:".count)
            guard let colon = body.firstIndex(of: ":"), Int(body[..<colon]) != nil else { return .notRun }
            return .value(String(body[body.index(after: colon)...]))
        }
        if rest.hasPrefix("BIG:") {
            let body = rest.dropFirst("BIG:".count)
            guard let colon = body.firstIndex(of: ":"), let length = Int(body[..<colon]), length >= 0
            else { return .notRun }
            return .stored(length: length)
        }
        return .notRun
    }

    /// The AppleScript that runs the inline wrapper reads the tab's URL first and answers
    /// `URL GS reply` (`SafariBridge.doJavaScript(captureURL:)`). Split at the first GS only:
    /// the reply may itself contain the separator. An empty or missing URL is `nil`.
    static func splitCapturedURL(_ raw: String) -> (url: String?, output: String) {
        guard let gs = raw.firstIndex(of: "\u{1D}") else { return (nil, raw) }
        let url = String(raw[..<gs])
        return (url.isEmpty ? nil : url, String(raw[raw.index(after: gs)...]))
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
