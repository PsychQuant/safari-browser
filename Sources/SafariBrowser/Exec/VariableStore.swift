import Foundation

/// Per-invocation variable store backing `var:` capture and `$name`
/// substitution per Requirement: Variable capture and substitution.
///
/// Scope is one `exec` invocation only — the store is created on entry to
/// `ExecCommand.run()` and discarded on exit. Nothing persists across CLI
/// calls, preserving the stateless-CLI contract.
///
/// Actor-isolated to make concurrent reads from the daemon path safe; the
/// step loop itself runs serially (steps must observe each other in
/// document order) but the actor barrier costs nothing in the serial case.
actor VariableStore {
    private var values: [String: String] = [:]

    func bind(name: String, value: String) {
        values[name] = value
    }

    func lookup(name: String) -> String? {
        values[name]
    }

    func contains(name: String) -> Bool {
        if let v = values[name] { return !v.isEmpty }
        return false
    }

    /// Resolves `$name` references in a string. Single dollar followed by
    /// `[A-Za-z_][A-Za-z0-9_]*` is a substitution; `\\$` is a literal `$`.
    /// Anything else (e.g., `$1`, `$%`) is left untouched so legitimate
    /// dollar usage in shell-like contexts isn't mangled.
    ///
    /// Throws `ScriptDispatchError.undefinedVariable` when a reference is
    /// well-formed but the name is not bound.
    func substitute(_ input: String) throws -> String {
        var result = ""
        result.reserveCapacity(input.count)

        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                result.append("$")
                i += 2
                continue
            }
            if ch == "$", i + 1 < chars.count, isIdentStart(chars[i + 1]) {
                var j = i + 1
                while j < chars.count, isIdentContinue(chars[j]) {
                    j += 1
                }
                let name = String(chars[(i + 1)..<j])
                guard let value = values[name] else {
                    throw ScriptDispatchError.undefinedVariable(name)
                }
                result.append(value)
                i = j
                continue
            }
            result.append(ch)
            i += 1
        }
        return result
    }

    private func isIdentStart(_ c: Character) -> Bool {
        c.isLetter || c == "_"
    }

    private func isIdentContinue(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}

/// Runtime errors emitted during script dispatch. Distinct from parse-time
/// errors so the result-array writer can format them with the right code.
enum ScriptDispatchError: Error, Equatable {
    case undefinedVariable(String)
    case invalidCondition(String)
    case unsupportedInExec(String)

    var code: String {
        switch self {
        case .undefinedVariable: return "undefinedVariable"
        case .invalidCondition: return "invalidCondition"
        case .unsupportedInExec: return "unsupportedInExec"
        }
    }

    var message: String {
        switch self {
        case .undefinedVariable(let name): return "$\(name) is not bound"
        case .invalidCondition(let msg): return msg
        case .unsupportedInExec(let cmd):
            return "command '\(cmd)' is not yet available in exec scripts"
        }
    }
}
