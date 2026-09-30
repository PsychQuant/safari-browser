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

    /// Whether `input` holds a `$name` reference that `substitute` would replace (a `\\$` is a
    /// literal). Used by the exec pre-flight (#220): the arguments it judges are the ones written
    /// in the script, and a step whose arguments depend on a variable has no shape until it runs.
    static func hasReference(_ input: String) -> Bool {
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "$" { i += 2; continue }
            if chars[i] == "$", i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1] == "_" { return true }
            i += 1
        }
        return false
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
    /// #220: the command is supported in-process, but the step's arguments are not a shape the
    /// in-process dispatcher runs exactly as the CLI command would.
    case unsupportedArguments(String)

    var code: String {
        switch self {
        case .undefinedVariable: return "undefinedVariable"
        case .invalidCondition: return "invalidCondition"
        case .unsupportedInExec: return "unsupportedInExec"
        case .unsupportedArguments: return "unsupportedArguments"
        }
    }

    var message: String {
        switch self {
        case .undefinedVariable(let name): return "$\(name) is not bound"
        case .invalidCondition(let msg): return msg
        case .unsupportedInExec(let cmd):
            return "command '\(cmd)' is not yet available in exec scripts"
        case .unsupportedArguments(let cmd):
            return "step '\(cmd)' has arguments the in-process dispatcher does not run exactly as the CLI command would; "
                + "run the script without the daemon (the same script then runs each step as its own command)"
        }
    }
}
