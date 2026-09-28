import Foundation
import Darwin
import MachO
import XCTest
@testable import SafariBrowser

final class MCPPersistentWorkerTests: XCTestCase {
    private final class Connection {
        let pair: MCPWorkerPair
        let image: String
        let worker: Int32
        private var buffer = Data()
        static var binary: URL {
            Bundle(for: MCPPersistentWorkerTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("safari-browser")
        }
        init(trace: Bool = false, binary: URL = binary) throws {
            image = try MCPExecutableIdentity.readImage(at: binary, architecture: MCPExecutableIdentity.currentArchitecture())
            var env = ProcessInfo.processInfo.environment
            env[MCPWorkerContext.directKey] = "1"
            env[MCPWorkerContext.imageKey] = image
            env["SAFARI_BROWSER_TRACE_TIMING"] = trace ? "1" : "0"
            pair = try MCPWorkerPair.launch(executable: binary, arguments: ["__mcp-supervise"], environment: env)
            do {
                guard case .hello(let actual, let pid, let parent)? = try Self.read(pair.control, buffer: &buffer),
                      actual == image, parent == pair.child.pid else { throw MCPWorkerLaunchError.supervisorContext }
                worker = pid
            } catch { _ = pair.child.retire(); throw error }
        }
        deinit { _ = pair.child.retire() }
        static func read(_ fd: Int32, buffer: inout Data, timeout: TimeInterval = 5) throws -> MCPWorkerWire.ServerMessage? {
            let end = ProcessInfo.processInfo.systemUptime + timeout
            var bytes = [UInt8](repeating: 0, count: 8192)
            repeat {
                if let newline = buffer.firstIndex(of: 10) {
                    let frame = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    return try MCPWorkerWire.decodeServer(frame)
                }
                if buffer.count > MCPWorkerWire.maxServerFrameBytes { throw MCPWorkerWire.WireError.invalidFrame }
                var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&item, 1, 10) <= 0 { continue }
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count == 0 {
                    if !buffer.isEmpty { throw MCPWorkerWire.WireError.invalidFrame }
                    return nil
                }
                if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw MCPWorkerLaunchError.status }
                buffer.append(contentsOf: bytes.prefix(count))
            } while ProcessInfo.processInfo.systemUptime < end
            throw MCPWorkerLaunchError.status
        }
        func next() throws -> MCPWorkerWire.ServerMessage? { try Self.read(pair.control, buffer: &buffer) }
        func sendRaw(_ data: Data) throws {
            let end = ProcessInfo.processInfo.systemUptime + 5
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < data.count, ProcessInfo.processInfo.systemUptime < end {
                    let count = Darwin.write(pair.control, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                    if count > 0 { offset += count; continue }
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        var item = pollfd(fd: pair.control, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&item, 1, 10); continue
                    }
                    throw MCPWorkerLaunchError.status
                }
                guard offset == data.count else { throw MCPWorkerLaunchError.status }
            }
        }
        func send(_ message: MCPWorkerWire.ClientMessage) throws { try sendRaw(MCPWorkerWire.encodeClient(message) + Data([10])) }
        func call(_ args: [String], input: Data = Data()) throws -> (code: Int32, reusable: Bool, stdout: Data, stderr: Data) {
            let token = UUID()
            try send(.request(id: token, arguments: args, input: input))
            var output = Data(), errors = Data()
            while let frame = try next() {
                switch frame {
                case .output(let id, let stream, let bytes):
                    XCTAssertEqual(id, token)
                    if stream == .stdout { output.append(bytes) } else { errors.append(bytes) }
                case .complete(let id, let code, let reusable):
                    XCTAssertEqual(id, token)
                    return (code, reusable, output, errors)
                case .retire(let id, .image, let code):
                    XCTAssertEqual(id, token)
                    return (try XCTUnwrap(code), false, output, errors)
                default: XCTFail("Unexpected worker reply: \(frame)"); throw MCPWorkerLaunchError.status
                }
            }
            throw MCPWorkerLaunchError.status
        }
    }

    func testTwentyActualCommandsReuseOnePIDWithFreshTraces() throws {
        let connection = try Connection(trace: true)
        var requests = Set<String>()
        for _ in 0..<20 {
            let result = try connection.call(["wait", "0"])
            XCTAssertEqual(result.code, 0); XCTAssertTrue(result.reusable); XCTAssertTrue(result.stdout.isEmpty)
            let line = try XCTUnwrap(String(data: result.stderr, encoding: .utf8))
            XCTAssertTrue(line.hasPrefix(PerformanceTrace.prefix))
            let json = Data(line.dropFirst(PerformanceTrace.prefix.count).utf8)
            let trace = try JSONDecoder().decode(PerformanceTrace.Summary.self, from: json)
            XCTAssertEqual(trace.processID, Int(connection.worker))
            requests.insert(trace.requestID)
        }
        XCTAssertEqual(requests.count, 20)
        try connection.send(.shutdown)
        XCTAssertNil(try connection.next())
    }

    func testEveryPublicToolHelpRunsInTheActualPersistentWorker() throws {
        let connection = try Connection()
        let catalog = try MCPToolCatalog(metadata: Data(SafariBrowser._dumpHelp().utf8))
        XCTAssertEqual(catalog.tools.count, 77)
        for tool in catalog.tools {
            let arguments = tool.name == "safari.help" ? ["--help"] : tool.path + ["--help"]
            let result = try connection.call(arguments)
            XCTAssertEqual(result.code, 0, tool.name)
            XCTAssertTrue(result.reusable, tool.name)
            XCTAssertTrue(result.stderr.isEmpty, tool.name)
            XCTAssertTrue(String(decoding: result.stdout, as: UTF8.self).contains("USAGE: safari-browser"), tool.name)
        }
        try connection.send(.shutdown)
        XCTAssertNil(try connection.next())
    }

    func testActualHelpExecStdinAndHiddenRejectionDoNotPolluteNextCall() throws {
        let connection = try Connection()
        let help = try connection.call(["wait", "--help"])
        XCTAssertEqual(help.code, 0); XCTAssertTrue(help.reusable)
        XCTAssertTrue(String(decoding: help.stdout, as: UTF8.self).contains("USAGE: safari-browser wait"))
        XCTAssertTrue(help.stderr.isEmpty)
        let invalid = try connection.call(["exec"], input: Data("not a script".utf8))
        XCTAssertNotEqual(invalid.code, 0); XCTAssertTrue(invalid.reusable)
        let script = Data(#"[{"cmd":"wait","args":["0"]}]"#.utf8)
        let valid = try connection.call(["exec"], input: script)
        XCTAssertEqual(valid.code, 0); XCTAssertTrue(valid.reusable)
        let steps = try XCTUnwrap(JSONSerialization.jsonObject(with: valid.stdout) as? [[String: Any]])
        XCTAssertEqual(steps.first?["status"] as? String, "ok")
        for args in [["mcp"], ["__mcp-exec", "wait", "0"], ["__mcp-supervise"], ["__mcp-worker"]] {
            let blocked = try connection.call(args)
            XCTAssertNotEqual(blocked.code, 0)
            XCTAssertTrue(blocked.reusable)
            XCTAssertTrue(String(decoding: blocked.stderr, as: UTF8.self).contains("Recursive or hidden MCP dispatch"))
        }
        XCTAssertNotEqual(try connection.call(["wait", "-1"]).code, 0)
        let next = try connection.call(["wait", "0"])
        XCTAssertEqual(next.code, 0); XCTAssertTrue(next.stdout.isEmpty); XCTAssertTrue(next.stderr.isEmpty)
        try connection.send(.shutdown)
        XCTAssertNil(try connection.next())
    }

    func testWarmWorkerRejectsAtomicExecutableReplacementBeforeNextCommand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("safari-browser")
        try FileManager.default.copyItem(at: Connection.binary, to: executable)
        let connection = try Connection(binary: executable)
        defer { _ = connection.pair.child.retire() }
        XCTAssertEqual(try connection.call(["wait", "0"]).code, 0)
        var bytes = try Data(contentsOf: executable)
        let header = bytes.withUnsafeBytes { $0.loadUnaligned(as: mach_header_64.self) }
        XCTAssertEqual(header.magic, MH_MAGIC_64)
        var offset = MemoryLayout<mach_header_64>.size
        var changed = false
        for _ in 0..<header.ncmds {
            let command = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: load_command.self) }
            if command.cmd == LC_UUID { bytes[offset + 8] ^= 1; changed = true; break }
            offset += Int(command.cmdsize)
        }
        XCTAssertTrue(changed)
        let replacement = directory.appendingPathComponent("replacement")
        try bytes.write(to: replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)
        // Replace the pathname, never modify a mapped executable inode in place.
        XCTAssertEqual(rename(replacement.path, executable.path), 0)
        let result = try connection.call(["wait", "0"])
        XCTAssertEqual(result.code, 64); XCTAssertFalse(result.reusable)
        XCTAssertTrue(result.stdout.isEmpty)
        let message = String(decoding: result.stderr, as: UTF8.self)
        XCTAssertTrue(message.contains("executable changed")); XCTAssertTrue(message.contains("not executed"))
        XCTAssertNil(try connection.next())
    }

    func testReadyHandshakeReleasesBootstrapOutputAndHelpersStayOutOfCatalog() throws {
        let connection = try Connection()
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(connection.pair.diagnostics, &byte, 1), 0)
        let catalog = try MCPToolCatalog(metadata: Data(SafariBrowser._dumpHelp().utf8))
        XCTAssertEqual(catalog.tools.count, 77)
        XCTAssertFalse(catalog.tools.contains { $0.path.contains("__mcp-supervise") || $0.path.contains("__mcp-worker") })
        try connection.send(.shutdown)
        XCTAssertNil(try connection.next())
    }

    func testDirectHelperEntryWithoutParentLeaseIsRejected() async throws {
        let binary = Connection.binary
        let image = try MCPExecutableIdentity.readImage(at: binary, architecture: MCPExecutableIdentity.currentArchitecture())
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: MCPWorkerSupervisor.parentKey)
        environment.removeValue(forKey: MCPWorkerSupervisor.workerParentKey)
        for command in ["__mcp-supervise", "__mcp-worker"] {
            let result = await MCPProcessRunner(executable: binary, environment: environment, workerPrefix: [], timeout: 2).run(
                arguments: [command], input: Data(), expectedImage: image)
            XCTAssertEqual(result.exitCode, 64)
            XCTAssertTrue(String(decoding: result.stderr, as: UTF8.self).contains("internal MCP worker"))
        }
    }

    func testWorkerRejectsWrongGroupAndWrongParentBeforeHandshake() throws {
        let binary = Connection.binary
        let image = try MCPExecutableIdentity.readImage(at: binary, architecture: MCPExecutableIdentity.currentArchitecture())
        for wrongParent in [false, true] {
            var environment = ProcessInfo.processInfo.environment
            environment[MCPWorkerContext.directKey] = "1"
            environment[MCPWorkerContext.imageKey] = image
            environment[MCPWorkerSupervisor.workerParentKey] = String(getpid())
            let arguments: [String] = wrongParent
                ? ["-c", "export SAFARI_BROWSER_MCP_WORKER_PARENT=$$; exec \"$1\" __mcp-worker", "fixture", binary.path]
                : ["__mcp-worker"]
            let pair = try MCPWorkerPair.launch(executable: wrongParent ? URL(fileURLWithPath: "/bin/sh") : binary,
                                                arguments: arguments, environment: environment)
            defer { _ = pair.child.retire() }
            var buffer = Data()
            XCTAssertNil(try Connection.read(pair.control, buffer: &buffer))
        }
    }

    func testMalformedAndPartialControlFramesTerminateWithoutReply() throws {
        for frame in [Data("{}\n".utf8), Data("{\"kind\":\"request\"".utf8)] {
            let connection = try Connection()
            try connection.sendRaw(frame)
            _ = Darwin.shutdown(connection.pair.control, SHUT_WR)
            XCTAssertNil(try connection.next())
        }
    }
}
