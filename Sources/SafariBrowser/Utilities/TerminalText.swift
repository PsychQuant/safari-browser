import Foundation

/// Escaping belongs at the text boundary, never in stored values or matching.
/// Limits count rendered Unicode scalars: even a single grapheme with thousands
/// of combining marks cannot make a diagnostic exceed its budget.
enum TerminalText {
    static let truncationMarker = "…[truncated]"
    static let dialogFieldLimit = 256

    static func escaped(_ raw: String, limit: Int? = nil, localField: Bool = false, foldDialogWhitespace: Bool = false) -> String {
        var tokens: [String] = []
        var size = 0
        var previousSpace = false
        let input = foldDialogWhitespace ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw
        for original in input.unicodeScalars {
            let scalar: UnicodeScalar
            if foldDialogWhitespace && [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029].contains(original.value) {
                scalar = " "
            } else {
                scalar = original
            }
            let value = scalar.value
            if foldDialogWhitespace && value == 0x20 && previousSpace { continue }
            let token: String
            switch value {
            case 0x22: token = "\\\""
            case 0x5C: token = "\\\\"
            case 0x09: token = "\\t"
            case 0x0A: token = "\\n"
            case 0x0D: token = "\\r"
            case 0...0x1F, 0x7F...0x9F, 0x2028, 0x2029,
                 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                token = "\\u{\(String(value, radix: 16).uppercased())}"
            case 0x2014 where localField, 0x2190 where localField:
                token = "\\u{\(String(value, radix: 16).uppercased())}"
            case 0x20 where localField && previousSpace:
                token = "\\u{20}"
            default: token = String(scalar)
            }
            let count = token.unicodeScalars.count
            if let limit, size + count > limit {
                let marker = truncationMarker
                while size + marker.unicodeScalars.count > limit, let removed = tokens.popLast() {
                    size -= removed.unicodeScalars.count
                }
                return tokens.joined() + marker
            }
            tokens.append(token)
            size += count
            previousSpace = value == 0x20
        }
        return tokens.joined()
    }

    static func quotedDialogField(_ raw: String, limit: Int = dialogFieldLimit) -> String {
        "\"" + escaped(raw, limit: limit - 2, foldDialogWhitespace: true) + "\""
    }
}
