/// Eval-free JavaScript wrappers with per-invocation result ownership.
/// User code is kept verbatim with newline guards for trailing comments.
enum JSWrapper {
    static func invocationWrapper(_ code: String, key: String, token: String, statement: Bool) -> String {
        let value = statement ? "(function(){\n\(code)\n})()" : "(\n\(code)\n)"
        // Common names such as `s` would shadow page variables in expressions.
        // These identifiers derive from the same generated ASCII UUID as key.
        let state = "__sbState_" + token
        let error = "__sbError_" + token
        return """
        (function(){var \(state)=window.\(key);if(!\(state)||\(state).token!=='\(token)'||\(state).phase!=='prepared')return '';
        \(state).phase='running';try{\(state).text=''+\(value);\(state).phase='done';}
        catch(\(error)){try{\(state).text=(\(error)&&typeof \(error).message==='string')?\(error).message:''+\(error);}catch(_){\(state).text='JavaScript exception';}\(state).phase='error';}
        return '\(token):executed';})()
        """
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
