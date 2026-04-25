import Foundation

/// Evaluator for the tiny `if:` expression language defined in
/// Requirement: Conditional step execution via `if:` expressions.
///
/// Grammar (whitespace-tolerant):
///
///     expr    ::= "$" name (op " " literal)?
///     name    ::= [A-Za-z_][A-Za-z0-9_]*
///     op      ::= "contains" | "equals" | "exists"
///     literal ::= '"' chars '"'
///
/// Boolean combinators (`and`, `or`, `&&`, `||`, `!`), parens, arithmetic,
/// and function calls are explicitly rejected — host-language compound
/// logic should generate multiple steps with separate `if:` clauses.
enum ExpressionEvaluator {
    static func evaluate(
        _ expression: String,
        store: VariableStore
    ) async throws -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        try rejectBannedTokens(in: trimmed)

        guard trimmed.hasPrefix("$") else {
            throw ScriptDispatchError.invalidCondition(
                "expression must start with a variable reference (e.g., '$url contains \"foo\"')"
            )
        }

        let afterDollar = String(trimmed.dropFirst())
        let (name, rest) = splitIdentifier(afterDollar)
        guard !name.isEmpty else {
            throw ScriptDispatchError.invalidCondition(
                "expected variable name after '$'"
            )
        }

        let restTrimmed = rest.trimmingCharacters(in: .whitespaces)
        if restTrimmed == "exists" {
            return await store.contains(name: name)
        }

        // For `contains` and `equals` we need: <op> <literal>
        let (op, literal) = try splitOpLiteral(restTrimmed)
        let value = await store.lookup(name: name) ?? ""

        switch op {
        case "contains": return value.contains(literal)
        case "equals":   return value == literal
        default:
            throw ScriptDispatchError.invalidCondition(
                "unknown operator '\(op)' (supported: contains, equals, exists)"
            )
        }
    }

    private static let bannedTokens: [String] = [
        " and ", " or ", " not ", "&&", "||", "!=", "==", "(", ")",
    ]

    private static func rejectBannedTokens(in expression: String) throws {
        let lower = " " + expression.lowercased() + " "
        for token in bannedTokens where lower.contains(token) {
            throw ScriptDispatchError.invalidCondition(
                "boolean combinators / parens / equality operators are not supported (got '\(token.trimmingCharacters(in: .whitespaces))')"
            )
        }
        if expression.lowercased().hasPrefix("not ") {
            throw ScriptDispatchError.invalidCondition(
                "'not' is not supported"
            )
        }
    }

    private static func splitIdentifier(_ input: String) -> (String, String) {
        var name = ""
        var i = input.startIndex
        while i < input.endIndex, input[i].isLetter || input[i].isNumber || input[i] == "_" {
            name.append(input[i])
            i = input.index(after: i)
        }
        return (name, String(input[i..<input.endIndex]))
    }

    /// Parses `<op> "<literal>"` from the remainder. Both `op` and the
    /// literal must be present, with the literal delimited by double quotes.
    private static func splitOpLiteral(_ input: String) throws -> (op: String, literal: String) {
        guard !input.isEmpty else {
            throw ScriptDispatchError.invalidCondition(
                "expected operator after variable (one of: contains, equals, exists)"
            )
        }
        var i = input.startIndex
        var op = ""
        while i < input.endIndex, !input[i].isWhitespace {
            op.append(input[i])
            i = input.index(after: i)
        }
        let rest = input[i..<input.endIndex].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 else {
            throw ScriptDispatchError.invalidCondition(
                "operand must be a quoted string literal (got '\(rest)')"
            )
        }
        let literal = String(rest.dropFirst().dropLast())
        return (op: op, literal: literal)
    }
}
