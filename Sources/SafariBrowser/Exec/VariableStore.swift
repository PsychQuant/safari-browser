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

    /// Resolves `$name` references in a string. A `$` followed by a letter or `_`, then letters,
    /// digits or `_` (letters and digits as `Character.isLetter` and `isNumber` define them, so
    /// not only ASCII), is a substitution; `\\$` is a literal `$`. Anything else (e.g., `$1`, `$%`)
    /// is left untouched so legitimate dollar usage in shell-like contexts isn't mangled. The
    /// grammar lives in `reference(in:at:)`, which this and the exec pre-flight both use.
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
            if let (name, end) = Self.reference(in: chars, at: i) {
                guard let value = values[name] else {
                    throw ScriptDispatchError.undefinedVariable(name)
                }
                result.append(value)
                i = end
                continue
            }
            result.append(ch)
            i += 1
        }
        return result
    }

    /// The `$name` reference that starts at `index`, if there is one: its name and the index
    /// after it. The scanner `substitute` and the exec pre-flight share. (The expression
    /// evaluator of an `if:` condition has a scanner of its own for the name it reads.)
    static func reference(in chars: [Character], at index: Int) -> (name: String, end: Int)? {
        guard index < chars.count, chars[index] == "$", index + 1 < chars.count, isIdentStart(chars[index + 1]) else { return nil }
        var j = index + 1
        while j < chars.count, isIdentContinue(chars[j]) { j += 1 }
        return (String(chars[(index + 1)..<j]), j)
    }

    /// Whether an argument begins with a `$name` reference (#220). Substitution can turn such an
    /// argument into anything — `-1`, a flag name — so a step that has one has no shape until it
    /// runs, and a refusal then comes after earlier steps have run and cannot fall back: the step
    /// is not sent to the daemon. An argument that begins with anything else keeps its first
    /// character whatever a later reference is replaced by, so the shape rules (a `-` prefix, a
    /// flag's value) cannot change under it. A leading `\\$` is a literal, not a reference.
    static func beginsWithReference(_ input: String) -> Bool {
        reference(in: Array(input), at: 0) != nil
    }

    private static func isIdentStart(_ c: Character) -> Bool {
        c.isLetter || c == "_"
    }

    private static func isIdentContinue(_ c: Character) -> Bool {
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
            return "step '\(cmd)' is not one the in-process dispatcher runs exactly as the CLI command would (its arguments are not a shape it honours); "
                + "run the script without the daemon (the same script then runs each step as its own command)"
        }
    }
}
