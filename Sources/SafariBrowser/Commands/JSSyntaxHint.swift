import JavaScriptCore

/// #255: which of `js`'s two wrapper forms to run.
///
/// The expression form (`'' + (code)`) and the statement form (code as a function body) differ
/// only in what parses, and Safari's `do JavaScript` swallows a SyntaxError and returns nothing.
/// Trying the expression form and falling back to the statement form therefore costs a whole
/// extra osascript round trip for statement code, and, worse, cannot tell "this form did not
/// parse" from "this form ran and its reply never came back" (a navigation, an undecodable
/// result). Re-running on the second reading runs the user's code twice.
///
/// JavaScriptCore is the engine Safari itself uses, so compiling the code here says which form
/// parses before anything is sent:
/// - the expression form compiles -> only it is sent; else the statement form compiles -> only
///   it is sent. If its reply never comes back the code parsed, so it most likely ran (or the
///   page navigated); the other form is not tried.
/// - neither compiles (a genuine SyntaxError, or syntax this process's engine does not know),
///   the input is over `maxHintedLength`, or no JSContext can be made -> both are tried,
///   expression first, which is what `js` always did. Only a genuine SyntaxError guarantees
///   that the silent form did not run; otherwise a lost reply with an unchanged URL can still
///   run the code twice (see `JSCommand.navigatedAwayURL`).
///
/// The probe is `new Function(body)`, which compiles without running `body`: the user's code
/// is never executed in this process. A different engine build in this process than in Safari
/// is the expected way the hint is wrong: a form it accepts and Safari rejects ends in a "no
/// reply" error, not a re-run; if it rejects both while Safari accepts one, both forms are tried
/// and the re-run risk above applies.
enum JSSyntaxHint {
    enum Form: Equatable {
        case expression
        case statement
    }

    /// Above this many UTF-16 units the hint is skipped (both forms are tried).
    static let maxHintedLength = 1_000_000

    /// Each `js` call that reaches this builds a `JSContext` (a JavaScript VM): milliseconds,
    /// against the ~120 ms floor of the osascript round trip it can save.
    static func formsToTry(for code: String) -> [Form] {
        let unknown: [Form] = [.expression, .statement]
        guard code.utf16.count <= maxHintedLength, let context = JSContext() else { return unknown }
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
        case "E": return [.expression]
        case "S": return [.statement]
        default: return unknown
        }
    }
}
