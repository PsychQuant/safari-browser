import Foundation

struct MCPInvocation: Sendable, Equatable {
    let arguments: [String]
    let stdin: Data
}

struct MCPToolBinding: Sendable {
    let name: String
    let path: [String]
    let descriptor: JSONValue
    fileprivate let definitions: [MCPArgumentDefinition]
}

struct MCPToolCatalogError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// A transport adapter only: value ranges and option interactions stay in the CLI parser.
struct MCPToolCatalog: Sendable {
    let tools: [MCPToolBinding]
    private let byName: [String: MCPToolBinding]
    // Bound count expansion independently of the small integer's JSON wire size.
    static let maximumFlagRepetitions = 65_536

    init(metadata: Data) throws {
        let document = try JSONDecoder().decode(MCPMetadataDocument.self, from: metadata)
        guard document.serializationVersion == 0 else {
            throw MCPToolCatalogError(message: "Unsupported ArgumentParser serializationVersion: \(document.serializationVersion)")
        }
        var bindings: [MCPToolBinding] = []
        func visit(_ node: MCPMetadataCommand, path: [String]) throws {
            guard node.shouldDisplay else { return }
            guard Self.validName(node.commandName), !node.commandName.hasPrefix("-") else {
                throw MCPToolCatalogError(message: "Unsupported command name: \(node.commandName)")
            }
            if path.isEmpty && node.commandName == "mcp" { return }
            let currentPath = path + [node.commandName]
            if let children = node.subcommands, !children.isEmpty {
                for child in children { try visit(child, path: currentPath) }
                return
            }
            let definitions = try (node.arguments ?? []).filter(\.shouldDisplay).map(MCPArgumentDefinition.init)
            let positionals = definitions.filter { $0.kind == "positional" }
            // A repeating positional consumes the remainder. Other arrangements
            // require metadata semantics that this adapter cannot safely infer.
            if positionals.dropLast().contains(where: \.repeating) {
                throw MCPToolCatalogError(message: "A repeating positional must be last: \(currentPath.joined(separator: " "))")
            }
            for group in [positionals, definitions.filter { $0.kind != "positional" }] {
                guard Set(group.map(\.key)).count == group.count else {
                    throw MCPToolCatalogError(message: "Duplicate argument key: \(currentPath.joined(separator: " "))")
                }
            }
            let name = "safari." + currentPath.joined(separator: ".")
            let positionalSchema = Self.objectSchema(positionals)
            let optionsSchema = Self.objectSchema(definitions.filter { $0.kind != "positional" })
            var schema: [String: JSONValue] = [
                "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                "type": .string("object"), "additionalProperties": .bool(false),
                "properties": .object([
                    "positionals": positionalSchema, "options": optionsSchema,
                    "stdin": .object(["type": .string("string"), "description": .string("UTF-8 command input, isolated from the MCP protocol stream.")])
                ])
            ]
            var required: [JSONValue] = []
            if positionals.contains(where: { !$0.optional }) { required.append(.string("positionals")) }
            if definitions.contains(where: { $0.kind != "positional" && !$0.optional }) { required.append(.string("options")) }
            if !required.isEmpty { schema["required"] = .array(required) }
            let descriptor: JSONValue = .object([
                "name": .string(name), "description": .string(node.abstract ?? currentPath.joined(separator: " ")),
                "inputSchema": .object(schema)
            ])
            bindings.append(MCPToolBinding(name: name, path: currentPath, descriptor: descriptor, definitions: definitions))
        }
        guard let children = document.command.subcommands, !children.isEmpty else {
            throw MCPToolCatalogError(message: "ArgumentParser metadata has no root subcommands")
        }
        for child in children { try visit(child, path: []) }
        guard Set(bindings.map(\.name)).count == bindings.count else {
            throw MCPToolCatalogError(message: "MCP tool naming collision")
        }
        tools = bindings.sorted { $0.name < $1.name }
        byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    func invocation(toolName: String, input: JSONValue) throws -> MCPInvocation {
        guard let binding = byName[toolName] else { throw MCPToolCatalogError(message: "Unknown tool: \(toolName)") }
        let root = try Self.object(input, allowed: ["positionals", "options", "stdin"], context: "arguments")
        let positionalDefinitions = binding.definitions.filter { $0.kind == "positional" }
        let optionDefinitions = binding.definitions.filter { $0.kind != "positional" }
        let positionals = try Self.object(root["positionals"] ?? .object([:]), allowed: Set(positionalDefinitions.map(\.key)), context: "positionals")
        let options = try Self.object(root["options"] ?? .object([:]), allowed: Set(optionDefinitions.map(\.key)), context: "options")
        var argv = binding.path
        for definition in optionDefinitions {
            guard let value = options[definition.key] else {
                if !definition.optional { throw MCPToolCatalogError(message: "Missing required option: \(definition.key)") }
                continue
            }
            if definition.kind == "flag" {
                let count: Int
                if definition.repeating {
                    guard let n = value.intValue, n >= 0, n <= Int64(Self.maximumFlagRepetitions) else {
                        throw MCPToolCatalogError(message: "Option \(definition.key) must be a count from 0 through \(Self.maximumFlagRepetitions)")
                    }
                    count = Int(n)
                } else {
                    guard let enabled = value.boolValue else { throw MCPToolCatalogError(message: "Option \(definition.key) must be boolean") }
                    count = enabled ? 1 : 0
                }
                if !definition.optional && count == 0 { throw MCPToolCatalogError(message: "Required flag must be present: \(definition.key)") }
                argv.append(contentsOf: repeatElement(definition.spelling, count: count))
            } else {
                let values = try definition.values(value)
                for value in values {
                    // Named option values use an explicit equals delimiter.
                    // No value can become a new flag, even when it starts with '-'.
                    argv.append(definition.spelling + "=" + value)
                }
            }
        }
        var positionalValues: [String] = []
        var missingEarlier = false
        for definition in positionalDefinitions {
            guard let value = positionals[definition.key] else {
                if !definition.optional { throw MCPToolCatalogError(message: "Missing required positional: \(definition.key)") }
                missingEarlier = true
                continue
            }
            let values = try definition.values(value)
            if !values.isEmpty && missingEarlier { throw MCPToolCatalogError(message: "Cannot skip an earlier positional before \(definition.key)") }
            if values.isEmpty { missingEarlier = true }
            positionalValues.append(contentsOf: values)
        }
        if !positionalValues.isEmpty { argv.append("--"); argv.append(contentsOf: positionalValues) }
        var stdin = Data()
        if let value = root["stdin"] {
            guard let string = value.stringValue else { throw MCPToolCatalogError(message: "stdin must be a UTF-8 string") }
            stdin = Data(string.utf8)
        }
        return MCPInvocation(arguments: argv, stdin: stdin)
    }

    private static func object(_ value: JSONValue, allowed: Set<String>, context: String) throws -> [String: JSONValue] {
        guard let result = value.objectValue else { throw MCPToolCatalogError(message: "\(context) must be an object") }
        if let unknown = result.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw MCPToolCatalogError(message: "Unknown \(context) key: \(unknown)")
        }
        return result
    }
    fileprivate static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }
    private static func objectSchema(_ definitions: [MCPArgumentDefinition]) -> JSONValue {
        var result: [String: JSONValue] = [
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object(Dictionary(uniqueKeysWithValues: definitions.map { ($0.key, $0.schema) }))
        ]
        let required = definitions.filter { !$0.optional }.map { JSONValue.string($0.key) }
        if !required.isEmpty { result["required"] = .array(required) }
        return .object(result)
    }
}

fileprivate struct MCPArgumentDefinition: Sendable {
    let key: String
    let kind: String
    let optional: Bool
    let repeating: Bool
    let nameKind: String?
    let spelling: String
    let schema: JSONValue
    let allowedValues: [String]?

    init(_ metadata: MCPMetadataArgument) throws {
        guard ["positional", "option", "flag"].contains(metadata.kind), metadata.parsingStrategy == "default" else {
            throw MCPToolCatalogError(message: "Unsupported argument kind or parsingStrategy: \(metadata.kind)/\(metadata.parsingStrategy)")
        }
        kind = metadata.kind; optional = metadata.isOptional; repeating = metadata.isRepeating
        allowedValues = metadata.allValues
        if kind == "positional" {
            guard let valueName = metadata.valueName, MCPToolCatalog.validName(valueName), metadata.preferredName == nil, metadata.names == nil else {
                throw MCPToolCatalogError(message: "Unsupported positional metadata")
            }
            key = valueName; nameKind = nil; spelling = ""
        } else {
            guard let preferred = metadata.preferredName, let names = metadata.names, names.contains(preferred), !names.isEmpty,
                  names.allSatisfy({ name in
                      ["short", "long", "longWithSingleDash"].contains(name.kind) && MCPToolCatalog.validName(name.name) && !name.name.hasPrefix("-") && (name.kind != "short" || name.name.utf8.count == 1)
                  }) else { throw MCPToolCatalogError(message: "Unsupported option name metadata") }
            key = preferred.name; nameKind = preferred.kind
            spelling = (preferred.kind == "long" ? "--" : "-") + preferred.name
        }
        var shape: [String: JSONValue]
        if kind == "flag" {
            guard allowedValues == nil else { throw MCPToolCatalogError(message: "Flag enum metadata is unsupported") }
            if repeating {
                shape = ["type": .string("integer"), "minimum": .int(optional ? 0 : 1), "maximum": .int(Int64(MCPToolCatalog.maximumFlagRepetitions))]
            } else {
                shape = ["type": .string("boolean")]
                if !optional { shape["const"] = .bool(true) }
            }
        } else {
            var item: [String: JSONValue] = ["type": .string("string")]
            if let allowedValues {
                guard !allowedValues.isEmpty else { throw MCPToolCatalogError(message: "Empty value enumeration") }
                item["enum"] = .array(allowedValues.map(JSONValue.string))
            }
            if repeating {
                shape = ["type": .string("array"), "items": .object(item)]
                if !optional { shape["minItems"] = .int(1) }
            } else { shape = item }
        }
        let presenceNote = kind == "flag" ? " Presence only: true adds the flag; false omits it." : ""
        shape["description"] = .string((metadata.abstract ?? key) + (repeating && kind == "flag" ? " Number of flag occurrences." : presenceNote))
        schema = .object(shape)
    }

    func values(_ value: JSONValue) throws -> [String] {
        let values: [String]
        if repeating {
            guard let array = value.arrayValue, array.allSatisfy({ $0.stringValue != nil }) else {
                throw MCPToolCatalogError(message: "\(key) must be an array of strings")
            }
            values = array.compactMap(\.stringValue)
            if !optional && values.isEmpty { throw MCPToolCatalogError(message: "\(key) requires at least one value") }
        } else {
            guard let string = value.stringValue else { throw MCPToolCatalogError(message: "\(key) must be a string") }
            values = [string]
        }
        guard values.allSatisfy({ !$0.utf8.contains(0) }) else { throw MCPToolCatalogError(message: "NUL is not allowed in argv: \(key)") }
        if let allowedValues, let invalid = values.first(where: { !allowedValues.contains($0) }) {
            throw MCPToolCatalogError(message: "Unsupported value for \(key): \(invalid)")
        }
        return values
    }
}

private struct MCPMetadataDocument: Decodable {
    let serializationVersion: Int
    let command: MCPMetadataCommand
}
private struct MCPMetadataCommand: Decodable {
    let commandName: String
    let shouldDisplay: Bool
    let abstract: String?
    let arguments: [MCPMetadataArgument]?
    let subcommands: [MCPMetadataCommand]?
}
fileprivate struct MCPMetadataArgument: Decodable {
    let kind: String
    let shouldDisplay: Bool
    let isOptional: Bool
    let isRepeating: Bool
    let parsingStrategy: String
    let valueName: String?
    let names: [MCPMetadataName]?
    let preferredName: MCPMetadataName?
    let abstract: String?
    let allValues: [String]?
}
fileprivate struct MCPMetadataName: Decodable, Equatable {
    let kind: String
    let name: String
}
