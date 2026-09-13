import Foundation

/// One stdio connection. The catalog is immutable; only business calls occupy
/// the worker slot, so cancellation and discovery remain responsive.
actor MCPSession {
    typealias Output = @Sendable (Data) async throws -> Void
    static let modernVersion = "2026-07-28"
    static let legacyVersions = ["2025-06-18", "2025-11-25"]
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let maximumFrameBytes = 8 * 1024 * 1024
    static let pageSize = 50
    static let serverInfo: JSONValue = .object(["name": .string("safari-browser"), "version": .string("1")])
    static let instructions = "Tools run the existing CLI in isolated workers. String values follow CLI syntax; semantic validation remains in the CLI. Cancellation stops owned processes but cannot undo prior effects or explicitly started persistent daemons. Failed or incomplete calls are never retried automatically. Restart this server after updating its executable."

    private let catalog: MCPToolCatalog
    private let runner: any MCPCommandRunning
    private let expectedImage: String
    private let output: Output
    private var legacyVersion: String?
    private var legacyReady = false
    private var stopped = false
    private var outputFailure: String?
    private struct Active {
        let id: JSONValue
        let token: UUID
        let modern: Bool
        let task: Task<Void, Never>
        var cancelled = false
    }
    private var active: Active?

    init(catalog: MCPToolCatalog, runner: any MCPCommandRunning, expectedImage: String, output: @escaping Output) {
        self.catalog = catalog; self.runner = runner
        self.expectedImage = expectedImage; self.output = output
    }

    func receive(_ data: Data) async throws {
        guard !stopped else { return }
        let message: JSONValue
        do { message = try JSONValue.decode(data) }
        catch { try await rpcError(id: .null, code: -32700, message: "Invalid JSON"); return }
        guard let envelope = message.objectValue, message["jsonrpc"] == .string("2.0"),
              let method = message["method"]?.stringValue,
              message["result"] == nil, message["error"] == nil else {
            try await rpcError(id: .null, code: -32600, message: "Invalid JSON-RPC request"); return
        }
        let id = envelope["id"]
        if let id, !Self.validID(id) {
            try await rpcError(id: .null, code: -32600, message: "Request ID must be a string or integer"); return
        }
        guard message["params"] == nil || message["params"]?.objectValue != nil else {
            if let id { try await rpcError(id: id, code: -32602, message: "params must be an object") }
            return
        }
        let params = message["params"]?.objectValue ?? [:]
        guard let id else {
            if method == "notifications/initialized", legacyVersion != nil { legacyReady = true }
            if method == "notifications/cancelled", let requestID = params["requestId"],
               Self.validID(requestID), active?.id == requestID {
                active?.cancelled = true
                active?.task.cancel()
            }
            return
        }
        // Use id:null for the malformed duplicate, leaving the original ID's
        // eventual response unambiguous. A duplicate never starts another worker.
        if active?.id == id {
            try await rpcError(id: .null, code: -32600, message: "Duplicate in-flight request ID"); return
        }
        guard params["_meta"] == nil || params["_meta"]?.objectValue != nil else {
            try await rpcError(id: id, code: -32602, message: "_meta must be an object"); return
        }
        let meta = params["_meta"]?.objectValue ?? [:]
        // Legacy _meta can carry progressToken and extension fields. Only
        // modern per-request protocol fields select the modern validation path.
        let modernRequested = [Self.versionKey, Self.capabilitiesKey, "io.modelcontextprotocol/clientInfo", "io.modelcontextprotocol/logLevel"].contains { meta[$0] != nil }
        if method == "initialize", !modernRequested {
            guard legacyVersion == nil,
                  let requested = params["protocolVersion"]?.stringValue,
                  params["capabilities"]?.objectValue != nil,
                  let info = params["clientInfo"]?.objectValue,
                  info["name"]?.stringValue != nil, info["version"]?.stringValue != nil else {
                try await rpcError(id: id, code: -32602, message: "Invalid or repeated initialize request"); return
            }
            let selected = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions.last!
            legacyVersion = selected
            try await result(id: id, modern: false, fields: ["protocolVersion": .string(selected), "capabilities": .object(["tools": .object([:])]), "serverInfo": Self.serverInfo, "instructions": .string(Self.instructions)])
            return
        }
        let modern: Bool
        if modernRequested {
            guard let version = meta[Self.versionKey]?.stringValue,
                  meta[Self.capabilitiesKey]?.objectValue != nil else {
                try await rpcError(id: id, code: -32602, message: "Required per-request protocolVersion and clientCapabilities metadata is missing or invalid"); return
            }
            guard version == Self.modernVersion else {
                try await rpcError(id: id, code: -32022, message: "Unsupported per-request protocol version", data: .object(["supported": .array([.string(Self.modernVersion)]), "requested": .string(version)])); return
            }
            modern = true
        } else if method != "server/discover", legacyReady || method == "ping" {
            modern = false
        } else {
            try await rpcError(id: id, code: -32602, message: "Supply modern request metadata or complete legacy initialization"); return
        }
        switch method {
        case "ping":
            try await result(id: id, modern: modern, fields: [:])
        case "server/discover":
            try await result(id: id, modern: modern, fields: ["supportedVersions": .array(([Self.modernVersion] + Self.legacyVersions).map(JSONValue.string)), "capabilities": .object(["tools": .object([:])]), "instructions": .string(Self.instructions)])
        case "tools/list":
            var offset = 0
            if let cursor = params["cursor"] {
                guard let value = cursor.stringValue, value.hasPrefix("page:"),
                      let parsed = Int(value.dropFirst(5)), value == "page:\(parsed)",
                      parsed > 0, parsed % Self.pageSize == 0, parsed < catalog.tools.count else {
                    try await rpcError(id: id, code: -32602, message: "Invalid tools cursor"); return
                }
                offset = parsed
            }
            let end = min(offset + Self.pageSize, catalog.tools.count)
            let descriptors = catalog.tools[offset..<end].map { binding -> JSONValue in
                var descriptor = binding.descriptor.objectValue ?? [:]
                descriptor["outputSchema"] = Self.outputSchema
                return .object(descriptor)
            }
            var fields: [String: JSONValue] = ["tools": .array(descriptors)]
            if end < catalog.tools.count { fields["nextCursor"] = .string("page:\(end)") }
            try await result(id: id, modern: modern, fields: fields)
        case "tools/call":
            guard let name = params["name"]?.stringValue,
                  params["arguments"] == nil || params["arguments"]?.objectValue != nil else {
                try await rpcError(id: id, code: -32602, message: "tools/call requires a name and object arguments"); return
            }
            guard catalog.tools.contains(where: { $0.name == name }) else {
                try await rpcError(id: id, code: -32602, message: "Unknown tool: \(name)"); return
            }
            guard active == nil else {
                try await result(id: id, modern: modern, fields: Self.toolResult(MCPCommandResult(failure: "Another tool is running or stopping; this call was not executed."))); return
            }
            let invocation: MCPInvocation
            do { invocation = try catalog.invocation(toolName: name, input: params["arguments"] ?? .object([:])) }
            catch {
                try await result(id: id, modern: modern, fields: Self.toolResult(MCPCommandResult(failure: "Invalid tool arguments; command was not executed: \(error.localizedDescription)"))); return
            }
            let token = UUID()
            let task = Task { [runner, expectedImage] in
                let result = await runner.run(arguments: invocation.arguments, input: invocation.stdin, expectedImage: expectedImage)
                await self.complete(token: token, result: result)
            }
            active = Active(id: id, token: token, modern: modern, task: task)
        default:
            try await rpcError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    func shutdown() async {
        stopped = true
        active?.cancelled = true
        active?.task.cancel()
        let pending = active?.task
        await pending?.value
        active = nil
    }
    func terminalFailure() -> String? { outputFailure }

    private func complete(token: UUID, result command: MCPCommandResult) async {
        guard let pending = active, pending.token == token else { return }
        active = nil
        guard !stopped, !pending.cancelled, !command.cancelled else { return }
        do { try await result(id: pending.id, modern: pending.modern, fields: Self.toolResult(command)) }
        catch { outputFailure = error.localizedDescription; stopped = true }
    }

    private static func validID(_ value: JSONValue) -> Bool {
        switch value { case .string, .int: return true; default: return false }
    }
    private func rpcError(id: JSONValue, code: Int64, message: String, data: JSONValue? = nil) async throws {
        var fields: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { fields["data"] = data }
        let encoded = try JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(fields)]).encoded()
        if encoded.count > Self.maximumFrameBytes {
            try await output(try JSONValue.object(["jsonrpc": .string("2.0"), "id": .null,
                "error": .object(["code": .int(-32603), "message": .string("Response cannot fit the MCP frame limit")])]).encoded())
        } else { try await output(encoded) }
    }
    private func result(id: JSONValue, modern: Bool, fields: [String: JSONValue], mayReduce: Bool = true) async throws {
        var fields = fields
        if modern {
            fields["resultType"] = .string("complete")
            fields["_meta"] = .object(["io.modelcontextprotocol/serverInfo": Self.serverInfo])
        }
        let envelope: JSONValue = .object(["jsonrpc": .string("2.0"), "id": id, "result": .object(fields)])
        let data = try envelope.encoded()
        guard data.count <= Self.maximumFrameBytes else {
            // Captured bytes may expand under JSON escaping and duplicated text
            // content. Never return a silently clipped successful tool result.
            if fields["isError"] != nil && mayReduce {
                try await result(id: id, modern: modern, fields: Self.toolResult(MCPCommandResult(truncated: true, failure: "Encoded tool output exceeds the MCP frame limit. Output is incomplete; the command may already have run.")), mayReduce: false)
            } else {
                try await rpcError(id: id, code: -32603, message: "Encoded response exceeds the MCP frame limit")
            }
            return
        }
        try await output(data)
    }

    static func toolResult(_ command: MCPCommandResult) -> [String: JSONValue] {
        func stream(_ data: Data) -> JSONValue {
            if let text = String(data: data, encoding: .utf8) { return .object(["encoding": .string("utf-8"), "data": .string(text)]) }
            return .object(["encoding": .string("base64"), "data": .string(data.base64EncodedString())])
        }
        let out = stream(command.stdout), err = stream(command.stderr)
        let complete = command.exitCode != nil && !command.truncated && !command.cancelled && command.failure == nil
        let structured: JSONValue = .object(["stdout": out, "stderr": err,
            "exit_code": command.exitCode.map { .int(Int64($0)) } ?? .null,
            "capture_complete": .bool(complete), "failure": command.failure.map(JSONValue.string) ?? .null])
        var content: [JSONValue] = []
        func text(_ value: String) -> JSONValue { .object(["type": .string("text"), "text": .string(value)]) }
        if let failure = command.failure { content.append(text(failure)) }
        for (label, value, bytes) in [("stderr", err, command.stderr), ("stdout", out, command.stdout)] where !bytes.isEmpty {
            content.append(text("\(label) (\(value["encoding"]!.stringValue!)):\n\(value["data"]!.stringValue!)"))
        }
        if content.isEmpty { content.append(text("Command exited with status \(command.exitCode.map(String.init) ?? "unknown").")) }
        return ["content": .array(content), "structuredContent": structured,
                "isError": .bool(!complete || command.exitCode != 0)]
    }

    static let outputSchema: JSONValue = {
        let stream: JSONValue = .object(["type": .string("object"), "additionalProperties": .bool(false),
            "required": .array([.string("encoding"), .string("data")]), "properties": .object([
                "encoding": .object(["type": .string("string"), "enum": .array([.string("utf-8"), .string("base64")])]),
                "data": .object(["type": .string("string")])])])
        return .object(["type": .string("object"), "additionalProperties": .bool(false),
            "required": .array(["stdout", "stderr", "exit_code", "capture_complete", "failure"].map(JSONValue.string)),
            "properties": .object(["stdout": stream, "stderr": stream,
                "exit_code": .object(["type": .array([.string("integer"), .string("null")])]),
                "capture_complete": .object(["type": .string("boolean")]),
                "failure": .object(["type": .array([.string("string"), .string("null")])])])])
    }()
}
