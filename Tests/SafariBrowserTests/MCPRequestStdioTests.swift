import Foundation
import Darwin
import XCTest
@testable import SafariBrowser

final class MCPRequestStdioTests: XCTestCase {
    private static let fixture: Result<URL, Error> = Result {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-stdio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fixture")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library", "-o", executable.path] + [
            "Sources/SafariBrowser/MCP/MCPRequestStdio.swift", "Sources/SafariBrowser/MCP/MCPWorkerSupervisor.swift",
            "Sources/SafariBrowser/MCP/MCPWorkerWire.swift", "Tests/Fixtures/MCPRequestStdioFixture.swift"
        ].map { root.appendingPathComponent($0).path }
        let log = directory.appendingPathComponent("build.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        build.standardOutput = output; build.standardError = output
        try build.run(); build.waitUntilExit()
        guard build.terminationStatus == 0 else {
            throw NSError(domain: "Fixture build", code: Int(build.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: (try? String(contentsOf: log, encoding: .utf8)) ?? "No build log"])
        }
        return executable
    }
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func run(_ mode: String) throws -> [MCPWorkerWire.ServerMessage] {
        var output: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&output), 0)
        defer { for fd in output where fd >= 0 { Darwin.close(fd) } }
        let child = try MCPWorkerSpawn.child(executable: Self.fixture.get(), arguments: [mode],
            environment: ProcessInfo.processInfo.environment, descriptors: [3: output[1]])
        defer { _ = child.retire() }
        Darwin.close(output[1]); output[1] = -1
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var eof = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            var item = pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)
            if poll(&item, 1, 10) <= 0 { continue }
            let count = Darwin.read(output[0], &buffer, buffer.count)
            if count == 0 { eof = true; break }
            if count < 0 { if errno == EINTR { continue }; break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count < 4 * 1024 * 1024 else { XCTFail("Fixture output unexpectedly unbounded"); break }
        }
        XCTAssertTrue(eof, "Fixture must finish its own work before the parent terminates it")
        // Observe exit before retiring so normal completion is not turned into TERM.
        while ProcessInfo.processInfo.systemUptime < deadline, try child.observe() == .running { usleep(1_000) }
        guard case .reaped(let status) = child.retire() else { throw MCPWorkerLaunchError.status }
        XCTAssertEqual(status, 0, "Fixture failed or was terminated, rather than completing normally")
        return try data.split(separator: 10).map { try MCPWorkerWire.decodeServer(Data($0)) }
    }
    private func bytes(_ messages: [MCPWorkerWire.ServerMessage], id: UUID, stream: MCPWorkerWire.Stream) -> Data {
        var result = Data()
        for message in messages {
            if case .output(let token, let channel, let bytes) = message, token == id, channel == stream {
                XCTAssertLessThanOrEqual(bytes.count, 8192)
                result.append(bytes)
            }
        }
        return result
    }
    func testSameProcessCapturesConcurrentPipesAndFlushesBeforeNextRequest() throws {
        let messages = try run("healthy")
        let input = Data((0..<200_000).map { UInt8($0 % 256) })
        // print's C buffer is flushed at sealing; the direct fd writes precede it.
        XCTAssertEqual(bytes(messages, id: first, stream: .stdout), Data(repeating: 65, count: 200_000) + input + Data("buffered-first\n".utf8))
        XCTAssertEqual(bytes(messages, id: first, stream: .stderr), Data(repeating: 255, count: 200_000))
        XCTAssertEqual(bytes(messages, id: second, stream: .stdout), Data("second-end\n".utf8))
        XCTAssertEqual(bytes(messages, id: second, stream: .stderr), Data("second-error".utf8))
        let completion = try XCTUnwrap(messages.firstIndex(of: .complete(id: first, exitCode: 23, reusable: true)))
        XCTAssertFalse(messages.dropFirst(completion + 1).contains { if case .output(let id, _, _) = $0 { return id == first }; return false })
        XCTAssertEqual(messages.last, .complete(id: second, exitCode: 0, reusable: true))
    }
    func testIdleBufferedStdoutIsDiscardedBeforeNextRequest() throws {
        let messages = try run("idle-buffer")
        XCTAssertEqual(bytes(messages, id: first, stream: .stdout), Data("first\n".utf8))
        XCTAssertEqual(bytes(messages, id: second, stream: .stdout), Data("second\n".utf8))
        XCTAssertEqual(messages.last, .complete(id: second, exitCode: 0, reusable: true))
    }

    func testCStdinUnreadBufferDoesNotReachNextRequest() throws {
        for mode in ["c-stdin", "c-eof"] {
            let messages = try run(mode)
            XCTAssertEqual(bytes(messages, id: first, stream: .stdout), Data((mode == "c-eof" ? "-1\n" : "97\n").utf8))
            XCTAssertEqual(bytes(messages, id: second, stream: .stdout), Data("98\n".utf8))
        }
    }
    func testUnusedLargeInputIsStoppedWithoutBlockingCompletion() throws {
        let messages = try run("ignored-input")
        XCTAssertEqual(bytes(messages, id: first, stream: .stdout), Data("done\n".utf8))
        XCTAssertEqual(messages.last, .complete(id: first, exitCode: 0, reusable: true))
    }
    func testFailedOutputAndLateWriterPoisonReuse() throws {
        for mode in ["failed-output", "late-writer"] {
            let messages = try run(mode)
            XCTAssertTrue(messages.contains(.complete(id: first, exitCode: 0, reusable: false)))
            XCTAssertTrue(messages.contains(.retire(id: second, reason: .io, exitCode: nil)))
        }
    }
    func testAnotherObjectCannotClaimTheSameProcessStdio() throws {
        let messages = try run("second-scope")
        XCTAssertEqual(messages.last, .retire(id: first, reason: .scope, exitCode: nil))
    }
    func testOversizedInputRejectedBeforeOperation() throws {
        let messages = try run("input-limit")
        XCTAssertEqual(messages.last, .retire(id: first, reason: .io, exitCode: nil))
    }
}
