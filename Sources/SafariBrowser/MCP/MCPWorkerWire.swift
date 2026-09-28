import Foundation

/// The private protocol carries data only. Framing and request correlation belong to the I/O owner.
enum MCPWorkerWire {
    static let maxClientFrameBytes = 8 * 1024 * 1024
    static let maxServerFrameBytes = 64 * 1024
    static let maxInputBytes = 4 * 1024 * 1024
    static let maxOutputChunkBytes = 8192
    static let maxArgumentCount = 65536

    enum Stream: String, Codable, Sendable { case stdout, stderr }
    enum RetirementReason: String, Codable, Sendable { case descendants, io, scope }
    enum ClientMessage: Sendable, Equatable {
        case request(id: UUID, arguments: [String], input: Data)
        case shutdown
    }
    enum ServerMessage: Sendable, Equatable {
        case hello(image: String, workerPID: Int32, supervisorPID: Int32)
        case output(id: UUID, stream: Stream, bytes: Data)
        case complete(id: UUID, exitCode: Int32, reusable: Bool)
        case retire(id: UUID, reason: RetirementReason, exitCode: Int32?)
    }
    enum WireError: Error, Equatable, Sendable, LocalizedError {
        case invalidFrame
        var errorDescription: String? { "Invalid private worker frame." }
    }

    /// Returned data excludes the LF delimiter; encoded newlines within strings are escaped.
    static func encodeClient(_ message: ClientMessage) throws -> Data {
        try encode(ClientEnvelope(message: message), limit: maxClientFrameBytes)
    }
    static func decodeClient(_ data: Data) throws -> ClientMessage {
        try decode(ClientEnvelope.self, data: data, limit: maxClientFrameBytes).message
    }
    static func encodeServer(_ message: ServerMessage) throws -> Data {
        try encode(ServerEnvelope(message: message), limit: maxServerFrameBytes)
    }
    static func decodeServer(_ data: Data) throws -> ServerMessage {
        try decode(ServerEnvelope.self, data: data, limit: maxServerFrameBytes).message
    }

    private static func encode<T: Encodable>(_ value: T, limit: Int) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            try validateFrame(data, limit: limit)
            return data
        } catch { throw WireError.invalidFrame }
    }
    private static func decode<T: Decodable>(_ type: T.Type, data: Data, limit: Int) throws -> T {
        do {
            try validateFrame(data, limit: limit)
            // Only this typed decoding pass interprets keys and values, including duplicate keys.
            return try JSONDecoder().decode(type, from: data)
        } catch { throw WireError.invalidFrame }
    }
    private static func validateFrame(_ data: Data, limit: Int) throws {
        guard !data.isEmpty, data.count <= limit, !data.contains(10) else { throw WireError.invalidFrame }
    }
    private static func validateArguments(_ arguments: [String]) throws {
        guard arguments.count <= maxArgumentCount else { throw WireError.invalidFrame }
        var total = 0
        for argument in arguments {
            // Bound work before JSONEncoder can expand escaping. Final encoded size is checked separately.
            guard !argument.utf8.contains(0), argument.utf8.count <= maxClientFrameBytes - total else {
                throw WireError.invalidFrame
            }
            total += argument.utf8.count
        }
    }
    private static func uuid(_ text: String) throws -> UUID {
        guard let value = UUID(uuidString: text), value.uuidString.lowercased() == text.lowercased() else {
            throw WireError.invalidFrame
        }
        return value
    }
    private static func decimal(_ text: String, range: ClosedRange<Int32>) throws -> Int32 {
        guard let value = Int32(text), range.contains(value), String(value) == text else {
            throw WireError.invalidFrame
        }
        return value
    }
    private static func base64(_ text: String, limit: Int) throws -> Data {
        guard text.utf8.count <= ((limit + 2) / 3) * 4,
              let bytes = Data(base64Encoded: text), bytes.count <= limit,
              bytes.base64EncodedString() == text else { throw WireError.invalidFrame }
        return bytes
    }
    private static func validateExitCode(_ code: Int32) throws {
        guard (0...255).contains(code) else { throw WireError.invalidFrame }
    }

    // A dynamic key retains unknown names in allKeys, unlike a closed CodingKeys enum.
    private struct Key: CodingKey, Hashable {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
    private struct Fields {
        let values: KeyedDecodingContainer<Key>
        init(_ decoder: any Decoder) throws { values = try decoder.container(keyedBy: Key.self) }
        func require(_ required: Set<String>, optional: Set<String> = []) throws {
            let actual = Set(values.allKeys.map(\.stringValue))
            guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
                throw WireError.invalidFrame
            }
        }
        func get<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
            try values.decode(type, forKey: Key(name))
        }
        func kind() throws -> String {
            guard try get("version", as: String.self) == "1" else { throw WireError.invalidFrame }
            return try get("kind")
        }
        func arguments() throws -> [String] {
            var container = try values.nestedUnkeyedContainer(forKey: Key("arguments"))
            if let count = container.count, count > maxArgumentCount { throw WireError.invalidFrame }
            var arguments: [String] = []
            while !container.isAtEnd {
                guard arguments.count < maxArgumentCount else { throw WireError.invalidFrame }
                arguments.append(try container.decode(String.self))
            }
            try validateArguments(arguments)
            return arguments
        }
        func id() throws -> UUID { try uuid(get("id")) }
        func exitCode() throws -> Int32 { try decimal(get("exitCode"), range: 0...255) }
    }
    private struct Writer {
        var values: KeyedEncodingContainer<Key>
        init(_ encoder: any Encoder, kind: String) throws {
            values = encoder.container(keyedBy: Key.self)
            try put("kind", kind)
            try put("version", "1")
        }
        mutating func put<T: Encodable>(_ name: String, _ value: T) throws {
            try values.encode(value, forKey: Key(name))
        }
    }
    private struct ClientEnvelope: Codable {
        let message: ClientMessage
        init(message: ClientMessage) { self.message = message }
        init(from decoder: any Decoder) throws {
            let fields = try Fields(decoder)
            switch try fields.kind() {
            case "shutdown":
                try fields.require(["kind", "version"])
                message = .shutdown
            case "request":
                try fields.require(["kind", "version", "id", "arguments", "input"])
                let arguments = try fields.arguments()
                message = .request(id: try fields.id(), arguments: arguments,
                                   input: try base64(fields.get("input"), limit: maxInputBytes))
            default: throw WireError.invalidFrame
            }
        }
        func encode(to encoder: any Encoder) throws {
            switch message {
            case .shutdown:
                _ = try Writer(encoder, kind: "shutdown")
            case let .request(id, arguments, input):
                try validateArguments(arguments)
                guard input.count <= maxInputBytes else { throw WireError.invalidFrame }
                var writer = try Writer(encoder, kind: "request")
                try writer.put("id", id.uuidString)
                try writer.put("arguments", arguments)
                try writer.put("input", input.base64EncodedString())
            }
        }
    }
    private struct ServerEnvelope: Codable {
        let message: ServerMessage
        init(message: ServerMessage) { self.message = message }
        init(from decoder: any Decoder) throws {
            let fields = try Fields(decoder)
            switch try fields.kind() {
            case "hello":
                try fields.require(["kind", "version", "image", "workerPID", "supervisorPID"])
                message = .hello(image: try fields.get("image"),
                                 workerPID: try decimal(fields.get("workerPID"), range: 1...Int32.max),
                                 supervisorPID: try decimal(fields.get("supervisorPID"), range: 1...Int32.max))
            case "output":
                try fields.require(["kind", "version", "id", "stream", "bytes"])
                message = .output(id: try fields.id(), stream: try fields.get("stream"),
                                  bytes: try base64(fields.get("bytes"), limit: maxOutputChunkBytes))
            case "complete":
                try fields.require(["kind", "version", "id", "exitCode", "reusable"])
                message = .complete(id: try fields.id(), exitCode: try fields.exitCode(), reusable: try fields.get("reusable"))
            case "retire":
                try fields.require(["kind", "version", "id", "reason"], optional: ["exitCode"])
                // Absence is meaningful; an explicit null is malformed, not an absent exit code.
                let code = try fields.values.contains(Key("exitCode")) ? fields.exitCode() : nil
                message = .retire(id: try fields.id(), reason: try fields.get("reason"), exitCode: code)
            default: throw WireError.invalidFrame
            }
        }
        func encode(to encoder: any Encoder) throws {
            switch message {
            case let .hello(image, workerPID, supervisorPID):
                guard workerPID > 0, supervisorPID > 0, image.utf8.count <= maxServerFrameBytes else {
                    throw WireError.invalidFrame
                }
                var writer = try Writer(encoder, kind: "hello")
                try writer.put("image", image)
                try writer.put("workerPID", String(workerPID))
                try writer.put("supervisorPID", String(supervisorPID))
            case let .output(id, stream, bytes):
                guard bytes.count <= maxOutputChunkBytes else { throw WireError.invalidFrame }
                var writer = try Writer(encoder, kind: "output")
                try writer.put("id", id.uuidString)
                try writer.put("stream", stream)
                try writer.put("bytes", bytes.base64EncodedString())
            case let .complete(id, exitCode, reusable):
                try validateExitCode(exitCode)
                var writer = try Writer(encoder, kind: "complete")
                try writer.put("id", id.uuidString)
                try writer.put("exitCode", String(exitCode))
                try writer.put("reusable", reusable)
            case let .retire(id, reason, exitCode):
                if let exitCode { try validateExitCode(exitCode) }
                var writer = try Writer(encoder, kind: "retire")
                try writer.put("id", id.uuidString)
                try writer.put("reason", reason)
                if let exitCode { try writer.put("exitCode", String(exitCode)) }
            }
        }
    }

    /// A diagnostic report from the supervisor, never authority to signal the reported PID.
    struct TerminationRecord: Equatable, Sendable {
        let workerPID: Int32
        let rawWaitStatus: Int32
        static let byteCount = 12
        private static let magic: UInt32 = 0x53424d31

        func encode() throws -> Data {
            try validate()
            var bytes = Data()
            for word in [Self.magic, UInt32(workerPID), UInt32(rawWaitStatus)] {
                var littleEndian = word.littleEndian
                withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
            }
            return bytes
        }
        static func decode(_ data: Data) throws -> Self {
            guard data.count == byteCount else { throw WireError.invalidFrame }
            // Data slices need not begin at zero or satisfy UInt32 alignment.
            let bytes = Array(data)
            func word(_ start: Int) -> UInt32 {
                UInt32(bytes[start]) | UInt32(bytes[start + 1]) << 8 |
                    UInt32(bytes[start + 2]) << 16 | UInt32(bytes[start + 3]) << 24
            }
            guard word(0) == magic,
                  let pid = Int32(exactly: word(4)), let status = Int32(exactly: word(8)) else {
                throw WireError.invalidFrame
            }
            let record = Self(workerPID: pid, rawWaitStatus: status)
            try record.validate()
            return record
        }
        private func validate() throws {
            guard workerPID > 0, rawWaitStatus >= 0 else { throw WireError.invalidFrame }
            let signal = rawWaitStatus & 0x7f
            let exited = signal == 0 && (rawWaitStatus & ~0xff00) == 0
            // Darwin's terminating signals are 1...31; bit 7 marks a core dump.
            // Reject stopped/continued reports and unused high bits, including mixed exit/signal data.
            let signaled = (1...31).contains(signal) && (rawWaitStatus & ~0xff) == 0
            guard exited || signaled else { throw WireError.invalidFrame }
        }
    }
}
