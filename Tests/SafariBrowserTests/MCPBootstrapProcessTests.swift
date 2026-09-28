import Foundation
import Darwin
import XCTest
@testable import SafariBrowser

final class MCPBootstrapProcessTests: XCTestCase, @unchecked Sendable {
    private var binary: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("safari-browser") }
    private final class Harness {
        let child: MCPChildReservation
        let metadata: MCPWorkerFD
        let lease: MCPWorkerFD
        let output: MCPWorkerFD
        let status: MCPWorkerFD
        init(child: MCPChildReservation, metadata: MCPWorkerFD, lease: MCPWorkerFD, output: MCPWorkerFD, status: MCPWorkerFD) {
            self.child = child; self.metadata = metadata; self.lease = lease; self.output = output; self.status = status
        }
        func cleanup() {
            metadata.close(); lease.close()
            guard case .reaped = child.retire(timeout: 2) else { return XCTFail("Owned bootstrap fixture was not reaped") }
        }
        func exited(within seconds: TimeInterval) throws -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            repeat {
                if try child.observe() == .exited { return true }
                usleep(1_000)
            } while ProcessInfo.processInfo.systemUptime < deadline
            return false
        }
        @discardableResult func send(_ data: Data, within seconds: TimeInterval = 1.5) throws -> Int {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            var offset = 0
            while offset < data.count, ProcessInfo.processInfo.systemUptime < deadline {
                let count = data.withUnsafeBytes { Darwin.write(metadata.value, $0.baseAddress!.advanced(by: offset), min(16384, data.count - offset)) }
                if count > 0 { offset += count }
                else if count < 0, errno == EPIPE { return offset }
                else if count < 0, errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { throw MCPWorkerLaunchError.descriptors }
                else { var item = pollfd(fd: metadata.value, events: Int16(POLLOUT), revents: 0); _ = poll(&item, 1, 5) }
            }
            return offset
        }
    }
    private func launch(marker: URL) throws -> Harness {
        let (metadataRead, metadataWrite) = try MCPWorkerFD.pipePair()
        let (leaseRead, leaseWrite) = try MCPWorkerFD.pipePair()
        let (outputRead, outputWrite) = try MCPWorkerFD.pipePair()
        let (statusRead, statusWrite) = try MCPWorkerFD.pipePair()
        let header = try MCPIsolatedBootstrap.context(parent: getpid(), deadline: ProcessInfo.processInfo.systemUptime + 3)
        let written = header.withUnsafeBytes { Darwin.write(metadataWrite.value, $0.baseAddress!, $0.count) }
        guard written == header.count else { throw MCPWorkerLaunchError.descriptors }
        try metadataWrite.nonblocking(); try outputRead.nonblocking(); try statusRead.nonblocking()
        guard fcntl(metadataWrite.value, F_SETNOSIGPIPE, 1) == 0 else { throw MCPWorkerLaunchError.descriptors }
        let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard null >= 0 else { throw MCPWorkerLaunchError.descriptors }
        defer { Darwin.close(null) }
        let child = try MCPWorkerSpawn.child(executable: binary,
            arguments: ["-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('executed')", marker.path],
            environment: [MCPWorkerContext.directKey: "2", MCPWorkerContext.imageKey: "fixture"],
            descriptors: [0: null, 1: outputWrite.value, 2: outputWrite.value, 3: metadataRead.value,
                          4: leaseRead.value, 5: statusWrite.value], argument0: "/usr/bin/python3")
        metadataRead.close(); leaseRead.close(); outputWrite.close(); statusWrite.close()
        return Harness(child: child, metadata: metadataWrite, lease: leaseWrite, output: outputRead, status: statusRead)
    }
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testMalformedOrIncompleteEnvironmentNeverStartsActualCLI() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let values = ["", "{", "[]", "{\"SAFARI_BROWSER_MCP_DIRECT\":\"2\"}",
                      "{\"SAFARI_BROWSER_MCP_DIRECT\":\"1\",\"SAFARI_BROWSER_MCP_IMAGE_ID\":\"fixture\"}",
                      "{\"SAFARI_BROWSER_MCP_DIRECT\":true,\"SAFARI_BROWSER_MCP_IMAGE_ID\":\"fixture\"}"]
        for (index, value) in values.enumerated() {
            let marker = directory.appendingPathComponent(String(index))
            let fixture = try launch(marker: marker)
            defer { fixture.cleanup() }
            let data = Data(value.utf8)
            XCTAssertEqual(try fixture.send(data), data.count)
            fixture.metadata.close()
            XCTAssertTrue(try fixture.exited(within: 1))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Invalid metadata must not execute the target")
            var byte: UInt8 = 0
            XCTAssertEqual(Darwin.read(fixture.status.value, &byte, 1), 0, "No actual worker status exists when startup is rejected")
        }
    }

    func testEnvironmentCapRejectsBeforeEOFOrDeadline() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("effect")
        let fixture = try launch(marker: marker); defer { fixture.cleanup() }
        // Keep metadata writer OPEN. Without the cap the helper must still be
        // awaiting more JSON rather than exiting from malformed EOF.
        let expectedLimit = 8 * 1024 * 1024
        let sent = try fixture.send(Data(repeating: 32, count: expectedLimit + 8192))
        XCTAssertGreaterThan(sent, expectedLimit)
        XCTAssertTrue(try fixture.exited(within: 0.5), "Metadata limit must reject without waiting for EOF or the 3s deadline")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLeaseEOFWhileReadingPartialEnvironmentTerminatesHelper() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("effect")
        let fixture = try launch(marker: marker); defer { fixture.cleanup() }
        // More than a pipe buffer must be consumed, proving the helper entered
        // its environment read loop (which comes after arming the lease).
        let partial = Data(repeating: 32, count: 256 * 1024)
        XCTAssertEqual(try fixture.send(partial), partial.count)
        XCTAssertEqual(try fixture.child.observe(), .running)
        fixture.lease.close() // Metadata stays open, so its EOF cannot end this test.
        XCTAssertTrue(try fixture.exited(within: 0.5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLargeParentEnvironmentUsesProductionPumpWithoutTruncation() async {
        let size = 131072
        let runner = MCPProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            environment: ["OWNED_PAYLOAD": String(repeating: "\u{0001}", count: size)], workerPrefix: ["-c"],
            supervisorExecutable: binary, timeout: 3)
        let result = await runner.run(arguments: ["import os; v=os.environ['OWNED_PAYLOAD']; assert all(ord(c)==1 for c in v); print(len(v))"],
                                      input: Data(), expectedImage: "fixture")
        XCTAssertEqual(result.stdout, Data("131072\n".utf8))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.failure)
        let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
    }

    func testMissingTruncatedOversizedAndInvalidStatusRemainIncomplete() async {
        for record in ["b''", "b'x'*11", "b'x'*13", "b'x'*12"] {
            let python = URL(fileURLWithPath: "/usr/bin/python3")
            let runner = MCPProcessRunner(executable: python, workerPrefix: ["-c"], supervisorExecutable: python, timeout: 2)
            let result = await runner.run(arguments: ["import os\nwhile os.read(3,65536): pass\nos.write(1,b'payload'); os.write(5," + record + ")"],
                                          input: Data(), expectedImage: "fixture")
            XCTAssertEqual(result.stdout, Data("payload".utf8))
            XCTAssertNil(result.exitCode, "A successful helper is not proof of the actual CLI exit status")
            XCTAssertTrue(result.failure?.contains("valid status record") == true)
            XCTAssertEqual(MCPSession.toolResult(result)["isError"], .bool(true))
            let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
        }
    }
}
