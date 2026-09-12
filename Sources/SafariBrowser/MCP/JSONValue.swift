import Foundation

indirect enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), int(Int64), double(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var intValue: Int64? { if case .int(let v) = self { return v }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    subscript(_ key: String) -> JSONValue? { objectValue?[key] }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    static func decode(_ data: Data) throws -> JSONValue {
        // Foundation accepts trailing commas on some supported systems.
        // Reject that extension for the JSON-RPC wire, without interpreting
        // commas/brackets that occur inside JSON strings.
        var quoted = false, escaped = false
        var previous: UInt8?
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false; previous = 34 }
            } else if byte == 34 {
                quoted = true
            } else if ![9, 10, 13, 32].contains(byte) {
                if (byte == 93 || byte == 125) && previous == 44 {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Trailing JSON comma"))
                }
                previous = byte
            }
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(self) }
}
