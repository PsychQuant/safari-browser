import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

final class MCPToolCatalogTests: XCTestCase {
    private func current() throws -> MCPToolCatalog {
        try MCPToolCatalog(metadata: Data(SafariBrowser._dumpHelp().utf8))
    }

    func testCurrentCatalogCoversEveryPublicLeafAndExpandedOptions() throws {
        let catalog = try current()
        XCTAssertEqual(catalog.tools.count, 76)
        XCTAssertEqual(catalog.tools.map(\.name), catalog.tools.map(\.name).sorted())
        XCTAssertTrue(catalog.tools.contains { $0.name == "safari.daemon.start" })
        XCTAssertTrue(catalog.tools.contains { $0.name == "safari.setup" })
        XCTAssertTrue(catalog.tools.contains { $0.name == "safari.help" })
        XCTAssertFalse(catalog.tools.contains { $0.path.contains("__serve") || $0.path.contains("__mcp-exec") || $0.path.first == "mcp" || $0.path == ["tab", "switch"] })
        let open = try XCTUnwrap(catalog.tools.first { $0.name == "safari.open" })
        let schema = try XCTUnwrap(open.descriptor["inputSchema"])
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(schema["properties"]?["options"]?["properties"]?["window"]?["type"], .string("string"))
        XCTAssertEqual(schema["properties"]?["positionals"]?["required"], .array([.string("url")]))
    }

    func testLiteralValuesAndStdinStaySeparate() throws {
        let actual = try current().invocation(toolName: "safari.open", input: .object([
            "positionals": .object(["url": .string("-quoted 'URL' $(noop)\n")]),
            "options": .object(["url": .string("--literal=foo"), "new-tab": .bool(true), "replace-tab": .bool(false)]),
            "stdin": .string("input\0\n")
        ]))
        XCTAssertEqual(actual.arguments, ["open", "--new-tab", "--url=--literal=foo", "--", "-quoted 'URL' $(noop)\n"])
        XCTAssertEqual(actual.stdin, Data("input\0\n".utf8))
    }

    func testShapeErrorsFailBeforeDispatch() throws {
        let catalog = try current()
        for input: JSONValue in [
            .null, .object([:]), .object(["extra": .bool(true)]),
            .object(["positionals": .object(["url": .int(4)])]),
            .object(["positionals": .object(["url": .string("a\0b")])]),
            .object(["positionals": .object(["url": .string("ok")]), "options": .object(["unknown": .string("v")])]),
            .object(["positionals": .object(["url": .string("ok")]), "options": .object(["new-tab": .int(1)])]),
            .object(["positionals": .object(["url": .string("ok")]), "options": .object(["window": .int(1)])]),
            .object(["positionals": .object(["url": .string("ok")]), "stdin": .bool(false)])
        ] { XCTAssertThrowsError(try catalog.invocation(toolName: "safari.open", input: input), "\(input)") }
        XCTAssertThrowsError(try catalog.invocation(toolName: "safari.mcp", input: .object([:])))
    }

    func testRepeatingHelpPositionalsAndEmptyInput() throws {
        let catalog = try current()
        XCTAssertEqual(try catalog.invocation(toolName: "safari.help", input: .object([
            "positionals": .object(["subcommands": .array([.string("daemon"), .string("start")])])
        ])).arguments, ["help", "--", "daemon", "start"])
        XCTAssertEqual(try catalog.invocation(toolName: "safari.help", input: .object([:])).arguments, ["help"])
    }
}

private struct CatalogLiteralCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "literal")
    @Option(name: .short) var x: String
    @Argument var value: String
}

extension MCPToolCatalogTests {
    private func fixture(arguments: [[String: Any]], commandName: String = "fixture") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "serializationVersion": 0,
            "command": ["commandName": "root", "shouldDisplay": true, "subcommands": [[
                "commandName": commandName, "shouldDisplay": true, "arguments": arguments
            ]]]
        ])
    }
    private func argument(_ key: String, kind: String, optional: Bool = true, repeating: Bool = false, nameKind: String = "long") -> [String: Any] {
        var result: [String: Any] = ["kind": kind, "valueName": key, "shouldDisplay": true, "isOptional": optional, "isRepeating": repeating, "parsingStrategy": "default"]
        if kind != "positional" {
            result["names"] = [["name": key, "kind": nameKind]]
            result["preferredName"] = ["name": key, "kind": nameKind]
        }
        return result
    }

    func testShortOptionLiteralMappingUsesOriginalParser() throws {
        let catalog = try MCPToolCatalog(metadata: fixture(arguments: [
            argument("x", kind: "option", optional: false, nameKind: "short"),
            argument("value", kind: "positional", optional: false)
        ], commandName: "literal"))
        let invocation = try catalog.invocation(toolName: "safari.literal", input: .object([
            "options": .object(["x": .string("--looks-like-option")]),
            "positionals": .object(["value": .string("-literal ' $(text)")])
        ]))
        let parsed = try CatalogLiteralCommand.parse(Array(invocation.arguments.dropFirst()))
        XCTAssertEqual(parsed.x, "--looks-like-option")
        XCTAssertEqual(parsed.value, "-literal ' $(text)")
        let empty = try catalog.invocation(toolName: "safari.literal", input: .object([
            "options": .object(["x": .string("")]), "positionals": .object(["value": .string("")])
        ]))
        let emptyParsed = try CatalogLiteralCommand.parse(Array(empty.arguments.dropFirst()))
        XCTAssertEqual(emptyParsed.x, "")
        XCTAssertEqual(emptyParsed.value, "")
    }

    func testRepeatingArgumentsRequiredFlagsAndOptionalHoles() throws {
        let catalog = try MCPToolCatalog(metadata: fixture(arguments: [
            argument("v", kind: "flag", repeating: true, nameKind: "short"),
            argument("required", kind: "flag", optional: false),
            argument("item", kind: "option", optional: false, repeating: true),
            argument("first", kind: "positional"), argument("rest", kind: "positional", repeating: true)
        ]))
        let input: JSONValue = .object([
            "options": .object(["v": .int(2), "required": .bool(true), "item": .array([.string("a"), .string("-b")])]),
            "positionals": .object(["first": .string("x"), "rest": .array([.string("y"), .string("z")])])
        ])
        XCTAssertEqual(try catalog.invocation(toolName: "safari.fixture", input: input).arguments,
                       ["fixture", "-v", "-v", "--required", "--item=a", "--item=-b", "--", "x", "y", "z"])
        var root = try XCTUnwrap(input.objectValue)
        var options = try XCTUnwrap(root["options"]?.objectValue)
        for invalid: JSONValue in [.int(-1), .int(Int64.max), .bool(true), .double(1.5)] {
            options["v"] = invalid; root["options"] = .object(options)
            XCTAssertThrowsError(try catalog.invocation(toolName: "safari.fixture", input: .object(root)))
        }
        options["v"] = .int(0); options["required"] = .bool(false); root["options"] = .object(options)
        XCTAssertThrowsError(try catalog.invocation(toolName: "safari.fixture", input: .object(root)))
        options["required"] = .bool(true); options["item"] = .array([]); root["options"] = .object(options)
        XCTAssertThrowsError(try catalog.invocation(toolName: "safari.fixture", input: .object(root)))
        root = try XCTUnwrap(input.objectValue)
        root["positionals"] = .object(["rest": .array([.string("cannot-skip-first")])])
        XCTAssertThrowsError(try catalog.invocation(toolName: "safari.fixture", input: .object(root)))
    }

    func testMetadataVersionShapesKindsAndCollisionsFailExplicitly() throws {
        let valid = argument("x", kind: "option")
        for (field, value): (String, Any) in [("kind", "future"), ("parsingStrategy", "allRemainingInput"), ("isOptional", "true"), ("preferredName", ["name": "x", "kind": "future"]) ] {
            var changed = valid; changed[field] = value
            XCTAssertThrowsError(try MCPToolCatalog(metadata: fixture(arguments: [changed])), field)
        }
        XCTAssertThrowsError(try MCPToolCatalog(metadata: fixture(arguments: [valid, valid])))
        XCTAssertThrowsError(try MCPToolCatalog(metadata: fixture(arguments: [argument("one", kind: "positional", repeating: true), argument("two", kind: "positional")])))
        XCTAssertThrowsError(try MCPToolCatalog(metadata: fixture(arguments: [], commandName: "bad/name")))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture(arguments: [])) as? [String: Any])
        document["serializationVersion"] = 1
        XCTAssertThrowsError(try MCPToolCatalog(metadata: JSONSerialization.data(withJSONObject: document)))
        document["serializationVersion"] = 0
        var root = try XCTUnwrap(document["command"] as? [String: Any])
        let children = try XCTUnwrap(root["subcommands"] as? [[String: Any]])
        root["subcommands"] = children + children; document["command"] = root
        XCTAssertThrowsError(try MCPToolCatalog(metadata: JSONSerialization.data(withJSONObject: document)))
    }

    func testEnumeratedMetadataDoesNotInventScalarTypes() throws {
        var enumerated = argument("mode", kind: "option")
        enumerated["allValues"] = ["1", "slow"]
        let catalog = try MCPToolCatalog(metadata: fixture(arguments: [enumerated]))
        let schema = catalog.tools[0].descriptor["inputSchema"]?["properties"]?["options"]?["properties"]?["mode"]
        XCTAssertEqual(schema?["type"], .string("string"))
        XCTAssertEqual(schema?["enum"], .array([.string("1"), .string("slow")]))
        XCTAssertEqual(try catalog.invocation(toolName: "safari.fixture", input: .object(["options": .object(["mode": .string("1")])])).arguments, ["fixture", "--mode=1"])
        XCTAssertThrowsError(try catalog.invocation(toolName: "safari.fixture", input: .object(["options": .object(["mode": .string("other")])])) )
    }

    func testEveryPublicLeafSchemaMapsAndRoutesSafeHelp() throws {
        let metadata = Data(SafariBrowser._dumpHelp().utf8)
        let catalog = try MCPToolCatalog(metadata: metadata)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        let root = try XCTUnwrap(document["command"] as? [String: Any])
        var expectedPaths = Set<[String]>()
        func collect(_ node: [String: Any], _ path: [String]) {
            guard node["shouldDisplay"] as? Bool == true, let name = node["commandName"] as? String else { return }
            if path.isEmpty && name == "mcp" { return }
            let current = path + [name]
            if let children = node["subcommands"] as? [[String: Any]], !children.isEmpty {
                for child in children { collect(child, current) }
            } else { expectedPaths.insert(current) }
        }
        for child in root["subcommands"] as? [[String: Any]] ?? [] { collect(child, []) }
        XCTAssertEqual(Set(catalog.tools.map(\.path)), expectedPaths)
        for tool in catalog.tools {
            var input: [String: JSONValue] = [:]
            for groupName in ["positionals", "options"] {
                let group = try XCTUnwrap(tool.descriptor["inputSchema"]?["properties"]?[groupName])
                let properties = try XCTUnwrap(group["properties"]?.objectValue)
                var values: [String: JSONValue] = [:]
                // Populate every value, including expanded optional OptionGroups.
                for (key, shape) in properties {
                    switch shape["type"]?.stringValue {
                    case "boolean": values[key] = .bool(true)
                    case "integer": values[key] = .int(1)
                    case "array": values[key] = .array([.string("literal-value")])
                    default: values[key] = .string(shape["enum"]?.arrayValue?.first?.stringValue ?? "literal-value")
                    }
                }
                input[groupName] = .object(values)
            }
            let invocation = try catalog.invocation(toolName: tool.name, input: .object(input))
            XCTAssertEqual(Array(invocation.arguments.prefix(tool.path.count)), tool.path)
            // Parse each command path with help to test routing without
            // running commands or touching Safari. This is adapter, not GUI proof.
            let argv = tool.path + ["--help"]
            do {
                let parsed = try SafariBrowser.parseAsRoot(argv)
                XCTAssertTrue(String(reflecting: type(of: parsed)).hasSuffix(".HelpCommand"), "Expected help command: \(tool.name)")
            }
            catch { XCTAssertEqual(SafariBrowser.exitCode(for: error), .success, "\(tool.name): \(error)") }
        }
    }
}
