import Foundation

/// A single step in an exec-script document.
///
/// Strict Codable: unknown keys are rejected at decode time so typos like
/// `"command"` for `"cmd"` fail loudly per Requirement: Step object schema.
struct ScriptStep: Equatable {
    var cmd: String
    var args: [String]
    var varName: String?
    var ifExpression: String?
    var onError: OnErrorMode

    enum OnErrorMode: String, Equatable {
        case abort
        case `continue`
    }

    init(
        cmd: String,
        args: [String] = [],
        varName: String? = nil,
        ifExpression: String? = nil,
        onError: OnErrorMode = .abort
    ) {
        self.cmd = cmd
        self.args = args
        self.varName = varName
        self.ifExpression = ifExpression
        self.onError = onError
    }
}

extension ScriptStep: Decodable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cmd
        case args
        case varName = "var"
        case ifExpression = "if"
        case onError
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: AnyCodable].self)
        let allowed = Set(CodingKeys.allCases.map { $0.rawValue })
        let unknown = raw.keys.filter { !allowed.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw ScriptParseError.invalidStepSchema(
                "unknown key(s) \(unknown.map { "'\($0)'" }.joined(separator: ", "))"
            )
        }

        guard let cmdValue = raw["cmd"]?.stringValue else {
            throw ScriptParseError.invalidStepSchema("missing required key 'cmd'")
        }
        self.cmd = cmdValue

        if let argsRaw = raw["args"] {
            guard let arr = argsRaw.arrayValue else {
                throw ScriptParseError.invalidStepSchema("'args' must be an array of strings")
            }
            var collected: [String] = []
            collected.reserveCapacity(arr.count)
            for item in arr {
                guard let s = item.stringValue else {
                    throw ScriptParseError.invalidStepSchema("'args' must be an array of strings")
                }
                collected.append(s)
            }
            self.args = collected
        } else {
            self.args = []
        }

        self.varName = raw["var"]?.stringValue
        self.ifExpression = raw["if"]?.stringValue

        if let onErrRaw = raw["onError"]?.stringValue {
            guard let mode = OnErrorMode(rawValue: onErrRaw) else {
                throw ScriptParseError.invalidStepSchema(
                    "'onError' must be 'abort' or 'continue'"
                )
            }
            self.onError = mode
        } else {
            self.onError = .abort
        }
    }
}

/// A minimal JSON value wrapper that preserves enough type information to
/// validate step schemas without committing to a specific Swift type per key.
struct AnyCodable: Decodable {
    let raw: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.raw = NSNull()
        } else if let s = try? container.decode(String.self) {
            self.raw = s
        } else if let b = try? container.decode(Bool.self) {
            self.raw = b
        } else if let i = try? container.decode(Int.self) {
            self.raw = i
        } else if let d = try? container.decode(Double.self) {
            self.raw = d
        } else if let arr = try? container.decode([AnyCodable].self) {
            self.raw = arr
        } else if let obj = try? container.decode([String: AnyCodable].self) {
            self.raw = obj
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported JSON value"
            )
        }
    }

    var stringValue: String? { raw as? String }
    var arrayValue: [AnyCodable]? { raw as? [AnyCodable] }
}

/// Errors emitted during script parsing. Mirror the top-level error shape so
/// CLI output stays consistent with other commands.
enum ScriptParseError: Error, Equatable {
    case invalidScriptFormat(String)
    case invalidStepSchema(String)
    case maxStepsExceeded(actual: Int, cap: Int)

    var code: String {
        switch self {
        case .invalidScriptFormat: return "invalidScriptFormat"
        case .invalidStepSchema: return "invalidStepSchema"
        case .maxStepsExceeded: return "maxStepsExceeded"
        }
    }

    var message: String {
        switch self {
        case .invalidScriptFormat(let msg): return msg
        case .invalidStepSchema(let msg): return msg
        case .maxStepsExceeded(let actual, let cap):
            return "\(actual) steps exceeds cap of \(cap)"
        }
    }
}
