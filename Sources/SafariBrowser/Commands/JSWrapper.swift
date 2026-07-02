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
/// function body (`return` yields the value). JSCommand tries the
/// expression form first and falls back to the statement form when the
/// injected wrapper never ran.
///
/// Parse-failure detection: `do JavaScript` swallows SyntaxError silently
/// (returns empty, throws nothing — verified live), so JSCommand presets
/// the protocol globals to undefined and reads back
/// `String(window.__sbLen)`; `lenUnsetSentinel` means the wrapper failed
/// to parse and the next form should be tried.
enum JSWrapper {

    /// Reading `String(window.__sbLen)` after injection yields this when
    /// the wrapper never executed (parse failure of the whole string).
    static let lenUnsetSentinel = "undefined"

    /// Preset injected before the first attempt so a stale `__sbLen` from
    /// a previous crashed invocation cannot masquerade as a fresh result.
    static let presetProtocolGlobals =
        "window.__sbLen = void 0; window.__sbResult = void 0"

    /// Preset for the large path's protocol globals (doJavaScriptLarge
    /// uses __sbResult / __sbResultLen).
    static let presetLargeProtocolGlobals =
        "window.__sbResult = void 0; window.__sbResultLen = void 0"

    /// Expression form: user code inlined as a parenthesized expression.
    /// Newlines guard both sides so a trailing `// comment` in user code
    /// cannot swallow the closing paren. Runtime errors are caught and
    /// reported through the existing `__sbLen = -1` protocol.
    static func expressionWrapper(_ code: String) -> String {
        """
        (function(){ try { var r = '' + (
        \(code)
        ); window.__sbLen = r.length; window.__sbResult = r; } catch(e) { window.__sbLen = -1; window.__sbResult = e.message; } })()
        """
    }

    /// Statement form: user code runs as a function body, so multi-statement
    /// scripts work and `return` yields the result value.
    static func statementWrapper(_ code: String) -> String {
        """
        (function(){ try { var r = '' + (function(){
        \(code)
        })(); window.__sbLen = r.length; window.__sbResult = r; } catch(e) { window.__sbLen = -1; window.__sbResult = e.message; } })()
        """
    }

    /// Large-path expression form. doJavaScriptLarge already wraps its
    /// argument as `'' + (code)`; this only adds newline-guarded parens.
    static func largeExpression(_ code: String) -> String {
        "(\n\(code)\n)"
    }

    /// Large-path statement form: IIFE over a function body.
    static func largeStatement(_ code: String) -> String {
        "(function(){\n\(code)\n})()"
    }

    /// Detects a CSP eval refusal in a JS error message and returns an
    /// actionable hint. After #76 the `js` wrapper itself is eval-free, so
    /// this only fires when the *user-provided* code calls eval()/new
    /// Function() on a strict-CSP page.
    static func cspEvalHint(for message: String) -> String? {
        guard message.contains("Refused to evaluate") else { return nil }
        return """


        Hint: this page's Content-Security-Policy blocks eval() ('unsafe-eval'). \
        safari-browser itself no longer needs eval — this refusal comes from \
        eval()/new Function() inside the provided JavaScript. Rewrite the code \
        to avoid runtime string evaluation.
        """
    }
}
