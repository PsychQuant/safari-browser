import Foundation

/// A value read back from AppleScript source form (#355). Only the shapes the window enumeration
/// uses are distinguished, plus reals (a window id of 2^29 or more arrives as one); every other
/// atom (booleans, `«class …»`, `«data …»`, dates) is `.other`, so a caller can reject it
/// without the atom's text reaching an error message. A record is read differently by the two
/// paths: osascript's `{a:1}` parses as a list of `.other` atoms, the daemon's `«class reco»` as
/// `.other`. The enumeration script builds no records, and no field of it accepts either.
indirect enum AppleScriptValue: Equatable, Sendable {
    case list([AppleScriptValue])
    case text(String)
    case integer(Int)
    /// A real number: osascript writes `3.5` or `5.36870912E+8`, the daemon conversion
    /// `«class doub»`. The value itself is not kept.
    case real
    case missingValue
    case other
}

/// AppleScript source form: the text `osascript -s s` prints for a result.
///
/// #355: Safari's window enumeration used to join page titles, window names and URLs with GS / RS
/// characters, so a page could forge records by putting those characters in its title. The
/// enumeration now returns an AppleScript list and travels in this form, where page text can only
/// appear inside a quoted string. Measured on this machine (openspec change
/// `structured-window-enumeration`, design.md): `osascript -s s` writes a string in double quotes,
/// escapes `"` as `\"` and `\` as `\\`, and writes every other character as itself (TAB, LF, CR,
/// NUL, U+0001–U+001F, U+2028, combining marks, non-BMP characters); lists are `{a, b}`, integers
/// decimal, and `missing value` literally.
///
/// The stateless path gets this text from `osascript -s s`; the daemon converts the result
/// descriptor with `render(_:)`. Both feed `parse(_:)`, so the two paths decode alike.
enum AppleScriptSourceForm {

    /// Why a text is not source form. The cases carry only byte offsets and kinds, never the text
    /// itself, because the text holds page-controlled strings (#227).
    enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unexpectedEnd
        case unexpectedCharacter(offset: Int)
        case invalidEscape(offset: Int)
        case trailingContent(offset: Int)

        var description: String {
            switch self {
            case .empty: return "the output was empty"
            case .unexpectedEnd: return "the output ended in the middle of a value"
            case .unexpectedCharacter(let offset): return "unexpected character at byte \(offset)"
            case .invalidEscape(let offset): return "unknown escape at byte \(offset)"
            case .trailingContent(let offset): return "unexpected content after the value at byte \(offset)"
            }
        }
    }

    /// Parse source form text. The scan works on UTF-8 bytes: `"`, `\`, `{`, `}` and `,` are ASCII
    /// and never occur inside a multi-byte sequence, while a scan by `Character` would read `"`
    /// followed by a combining mark as one grapheme and miss the quote.
    static func parse(_ text: String) throws -> AppleScriptValue {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipSpace()
        guard !parser.atEnd else { throw ParseError.empty }
        let value = try parser.value()
        parser.skipSpace()
        guard parser.atEnd else { throw ParseError.trailingContent(offset: parser.index) }
        return value
    }

    /// Convert a result descriptor into the text `osascript -s s` prints for it (the daemon path).
    ///
    /// Lists, text (`utxt`), AppleScript integers (`typeSInt32`) and `missing value` are written
    /// exactly as osascript writes them (byte-identical; `AppleScriptSourceFormRenderTests` compares
    /// against the real `osascript`). Any other kind becomes `«class xxxx»`. A real becomes
    /// `«class doub»`, which `parse` reads as `.real`, as it reads osascript's `3.5` or
    /// `5.36870912E+8`; every other `«class xxxx»` reads as `.other`, the same value osascript's own
    /// spelling of a boolean or raw `utf8` / `TEXT` data parses to. One exception cannot be closed here: raw data of integer type
    /// (`«data long05000000»`) reaches `NSAppleScript` as the same `typeSInt32` descriptor as the
    /// integer 5, so this path writes `5` where osascript writes the `«data …»` form. The window
    /// enumeration never returns raw data.
    ///
    /// Unpaired UTF-16 surrogates follow osascript too: it splits a string at each `"` and `\` and
    /// cuts each part at its first unpaired surrogate. `NSAppleScript` keeps the surrogate, so
    /// without the same cut the daemon path would decode a different title than the stateless path.
    /// The cut stays inside the quotes, so it cannot open or close a string.
    static func render(_ descriptor: NSAppleEventDescriptor) -> String {
        var out = ""
        render(descriptor, into: &out)
        return out
    }

    private static let missingValueCode: FourCharCode = 0x6D73_6E67 // 'msng'

    private static func render(_ descriptor: NSAppleEventDescriptor, into out: inout String) {
        switch descriptor.descriptorType {
        case typeAEList:
            out += "{"
            let count = descriptor.numberOfItems
            if count > 0 {
                for index in 1...count {
                    if index > 1 { out += ", " }
                    if let item = descriptor.atIndex(index) {
                        render(item, into: &out)
                    } else {
                        out += "«class ????»"
                    }
                }
            }
            out += "}"
        case typeUnicodeText:
            // AppleScript text always comes back as `utxt`. A `utf8` or `TEXT` descriptor is raw
            // data (`«data utf8…»`), which `osascript -s s` prints as such; it falls to the
            // opaque `«class …»` below, so both paths read it as `.other` (#355 verify round 2).
            out += "\""
            out += quotedBody(utf16Units(of: descriptor))
            out += "\""
        case typeSInt32:
            out += String(descriptor.int32Value)
        case typeType where descriptor.typeCodeValue == missingValueCode:
            out += "missing value"
        default:
            out += "«class \(fourCharacters(descriptor.descriptorType))»"
        }
    }

    /// The text's UTF-16 code units as the descriptor holds them, unpaired surrogates included.
    ///
    /// Read from the `utxt` bytes, not through `stringValue`: the Swift `String` made from it already
    /// shows an unpaired surrogate as U+FFFD in its `utf16` and `utf8` views (measured on a 1000-unit
    /// title ending in U+D83D, the shape Safari's title cut produces; #355). Only a round trip back
    /// to the original `NSString` still had the unit, and that depends on the bridge staying lazy.
    private static func utf16Units(of descriptor: NSAppleEventDescriptor) -> [UInt16] {
        let data = descriptor.data
        // Native-endian UTF-16, as AppleScript stores `utxt`. Copied rather than rebound, so the
        // read does not depend on the bytes' alignment.
        var units = [UInt16](repeating: 0, count: data.count / 2)
        _ = units.withUnsafeMutableBufferPointer { data.copyBytes(to: $0) }
        return units
    }

    /// The characters between the quotes: `"` → `\"`, `\` → `\\`, and each run between those cut at
    /// its first unpaired surrogate.
    private static func quotedBody(_ units: [UInt16]) -> String {
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var index = 0
        var runCut = false
        while index < units.count {
            let unit = units[index]
            if unit == 0x22 || unit == 0x5C {
                out.append(0x5C)
                out.append(unit)
                runCut = false
                index += 1
                continue
            }
            if runCut { index += 1; continue }
            if (0xD800...0xDBFF).contains(unit) {
                if index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) {
                    out.append(unit)
                    out.append(units[index + 1])
                    index += 2
                    continue
                }
                runCut = true
                index += 1
                continue
            }
            if (0xDC00...0xDFFF).contains(unit) {
                runCut = true
                index += 1
                continue
            }
            out.append(unit)
            index += 1
        }
        return String(decoding: out, as: UTF16.self)
    }

    private static func fourCharacters(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return bytes.allSatisfy({ (0x20...0x7E).contains($0) })
            ? String(decoding: bytes, as: UTF8.self)
            : String(format: "%08X", code)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        static let quote: UInt8 = 0x22, backslash: UInt8 = 0x5C
        static let open: UInt8 = 0x7B, close: UInt8 = 0x7D, comma: UInt8 = 0x2C

        var atEnd: Bool { index >= bytes.count }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value() throws -> AppleScriptValue {
            skipSpace()
            guard !atEnd else { throw ParseError.unexpectedEnd }
            switch bytes[index] {
            case Self.open: return try list()
            case Self.quote: return try string()
            case Self.close, Self.comma: throw ParseError.unexpectedCharacter(offset: index)
            default: return try atom()
            }
        }

        mutating func list() throws -> AppleScriptValue {
            index += 1
            var items: [AppleScriptValue] = []
            skipSpace()
            if !atEnd, bytes[index] == Self.close {
                index += 1
                return .list(items)
            }
            while true {
                items.append(try value())
                skipSpace()
                guard !atEnd else { throw ParseError.unexpectedEnd }
                switch bytes[index] {
                case Self.comma: index += 1
                case Self.close: index += 1; return .list(items)
                default: throw ParseError.unexpectedCharacter(offset: index)
                }
            }
        }

        mutating func string() throws -> AppleScriptValue {
            index += 1
            var out: [UInt8] = []
            var runStart = index
            while index < bytes.count {
                switch bytes[index] {
                case Self.backslash:
                    out.append(contentsOf: bytes[runStart..<index])
                    let escape = index
                    index += 1
                    guard index < bytes.count else { throw ParseError.unexpectedEnd }
                    guard bytes[index] == Self.quote || bytes[index] == Self.backslash else {
                        throw ParseError.invalidEscape(offset: escape)
                    }
                    out.append(bytes[index])
                    index += 1
                    runStart = index
                case Self.quote:
                    out.append(contentsOf: bytes[runStart..<index])
                    index += 1
                    return .text(String(decoding: out, as: UTF8.self))
                default:
                    index += 1
                }
            }
            throw ParseError.unexpectedEnd
        }

        /// A bare value up to the next `,` or `}` at this level. Quoted strings inside it (as in
        /// `date "…"`) are skipped whole so a comma inside them does not end the atom.
        mutating func atom() throws -> AppleScriptValue {
            let start = index
            while index < bytes.count, bytes[index] != Self.comma, bytes[index] != Self.close {
                if bytes[index] == Self.open { throw ParseError.unexpectedCharacter(offset: index) }
                if bytes[index] == Self.quote {
                    index += 1
                    while index < bytes.count, bytes[index] != Self.quote {
                        if bytes[index] == Self.backslash { index += 1 }
                        index += 1
                    }
                    guard index < bytes.count else { throw ParseError.unexpectedEnd }
                }
                index += 1
            }
            var end = index
            while end > start, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[end - 1]) { end -= 1 }
            let token = bytes[start..<end]
            if token.elementsEqual("missing value".utf8) { return .missingValue }
            if let number = Self.integer(token) { return .integer(number) }
            if Self.isReal(token) { return .real }
            if token.isEmpty { throw ParseError.unexpectedCharacter(offset: start) }
            if token.contains(where: { [0x20, 0x09, 0x0A, 0x0D].contains($0) }),
               !token.contains(Self.quote), !token.starts(with: "«".utf8) {
                // `{1 2}`: two bare words where one value belongs.
                throw ParseError.unexpectedCharacter(offset: start)
            }
            return .other
        }

        /// A real as osascript writes one (`-?[0-9]+(.[0-9]+)?(E[+-]?[0-9]+)?` with a point or an
        /// exponent), or the daemon conversion's `«class doub»`.
        static func isReal(_ token: ArraySlice<UInt8>) -> Bool {
            if token.elementsEqual("«class doub»".utf8) { return true }
            var rest = token[...]
            if rest.first == 0x2D { rest = rest.dropFirst() }
            func digits() -> Int {
                let count = rest.prefix(while: { (0x30...0x39).contains($0) }).count
                rest = rest.dropFirst(count)
                return count
            }
            guard digits() > 0 else { return false }
            var marked = false
            if rest.first == 0x2E {
                rest = rest.dropFirst()
                guard digits() > 0 else { return false }
                marked = true
            }
            if rest.first == 0x45 {
                rest = rest.dropFirst()
                if rest.first == 0x2B || rest.first == 0x2D { rest = rest.dropFirst() }
                guard digits() > 0 else { return false }
                marked = true
            }
            return marked && rest.isEmpty
        }

        /// `-?[0-9]+`, within `Int` range.
        static func integer(_ token: ArraySlice<UInt8>) -> Int? {
            var digits = token[...]
            if digits.first == 0x2D { digits = digits.dropFirst() }
            guard !digits.isEmpty, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
            return Int(String(decoding: token, as: UTF8.self))
        }
    }
}

