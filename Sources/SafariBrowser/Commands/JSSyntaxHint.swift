import JavaScriptCore

/// #255: which of `js`'s two wrapper forms to try first.
///
/// `JSCommand` tries the expression form and, when Safari's `do JavaScript` swallows the
/// SyntaxError (it returns nothing), falls back to the statement form. For statement code
/// that costs a whole extra osascript round trip (and a navigation check) before the form
/// that works. JavaScriptCore is the engine Safari itself uses, so compiling the code here
/// tells us in microseconds which form will parse.
///
/// This only ORDERS the attempts. It never rejects code and never replaces Safari as the
/// judge: when neither form compiles here, or the input is too large to bother, the order is
/// the one `js` always had (expression first), and a hint that turned out wrong costs the
/// same extra round trip it cost before.
///
/// The probe is `new Function(body)`, which compiles without running `body`. The user's code
/// is never executed in this process.
enum JSSyntaxHint {
    enum Form: Equatable {
        case expression
        case statement
    }

    /// Above this many UTF-16 units the hint is skipped.
    static let maxHintedLength = 1_000_000

    static func preferredOrder(for code: String) -> [Form] {
        let existing: [Form] = [.expression, .statement]
        guard code.utf16.count <= maxHintedLength, let context = JSContext() else { return existing }
        context.exceptionHandler = { _, _ in }
        context.setObject(code, forKeyedSubscript: "__sbcode" as NSString)
        // The two bodies are the ones the wrappers in `JSWrapper` build around the code.
        let probe = """
        (function(){
          try { new Function("var r = '' + (\\n" + __sbcode + "\\n);"); return 'E'; } catch (e) {}
          try { new Function("var r = '' + (function(){\\n" + __sbcode + "\\n})();"); return 'S'; } catch (e) {}
          return 'N';
        })()
        """
        switch context.evaluateScript(probe)?.toString() {
        case "S": return [.statement, .expression]
        default: return existing
        }
    }
}
