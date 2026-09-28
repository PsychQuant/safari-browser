import Foundation
import Darwin
import MachO
import XCTest
@testable import SafariBrowser

final class MCPReviewBoundaryTests: XCTestCase, @unchecked Sendable {
    private final class Swap: @unchecked Sendable {
        private let lock = NSLock()
        var replacement: URL
        var executable: URL
        private var armed = false
        private var writes = 0
        init(replacement: URL, executable: URL) { self.replacement = replacement; self.executable = executable }
        func arm() { lock.withLock { armed = true } }
        var count: Int { lock.withLock { writes } }
        func beforeSend() throws {
            try lock.withLock {
                writes += 1
                if armed {
                    armed = false
                    guard rename(replacement.path, executable.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
                }
            }
        }
    }
    private final class Delay: @unchecked Sendable {
        private let lock = NSLock()
        private var until: TimeInterval = 0
        func arm(seconds: TimeInterval) { lock.withLock { until = ProcessInfo.processInfo.systemUptime + seconds } }
        var pending: Bool { lock.withLock { ProcessInfo.processInfo.systemUptime < until } }
    }
    private var binary: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("safari-browser") }
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    func testWorkerOnlyImageFailureStaysInvalidAfterPathRestoration() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("worker"), replacement = directory.appendingPathComponent("replacement"), backup = directory.appendingPathComponent("original")
        try FileManager.default.copyItem(at: binary, to: executable)
        try FileManager.default.copyItem(at: binary, to: backup)
        var data = try Data(contentsOf: binary)
        let header = data.withUnsafeBytes { $0.loadUnaligned(as: mach_header_64.self) }
        XCTAssertEqual(header.magic, MH_MAGIC_64)
        var offset = MemoryLayout<mach_header_64>.size, changed = false
        for _ in 0..<header.ncmds {
            let command = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: load_command.self) }
            if command.cmd == LC_UUID { data[offset + 8] ^= 1; changed = true; break }
            offset += Int(command.cmdsize)
        }
        XCTAssertTrue(changed)
        try data.write(to: replacement)
        let image = try MCPExecutableIdentity.readImage(at: executable, architecture: MCPExecutableIdentity.currentArchitecture())
        let swap = Swap(replacement: replacement, executable: executable)
        var lifecycle = MCPPersistentRunner.Lifecycle()
        lifecycle.beforeRequestSend = { try swap.beforeSend() }
        let runner = MCPPersistentRunner(executable: executable, lifecycle: lifecycle)
        let first = await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image)
        XCTAssertNil(first.failure)
        swap.arm()
        let rejected = await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image)
        XCTAssertEqual(rejected.exitCode, 64)
        XCTAssertTrue(String(decoding: rejected.stderr, as: UTF8.self).contains("executable changed"))
        XCTAssertEqual(swap.count, 2)
        XCTAssertEqual(rename(backup.path, executable.path), 0)
        let next = await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image)
        XCTAssertTrue(next.failure?.contains("restart") == true)
        XCTAssertTrue(next.failure?.contains("not executed") == true)
        XCTAssertEqual(swap.count, 2, "A worker-only invalidation must prevent the next request from being sent")
        let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
    }

    func testLargeArgumentRouteRetainsInvocationDeadlineAfterRetirementDelay() async throws {
        let image = try MCPExecutableIdentity.readImage(at: binary, architecture: MCPExecutableIdentity.currentArchitecture())
        let delay = Delay()
        var lifecycle = MCPPersistentRunner.Lifecycle()
        lifecycle.retire = { delay.pending ? .pending : $0.retire(timeout: 0) }
        let runner = MCPPersistentRunner(executable: binary, timeout: 1.2, lifecycle: lifecycle)
        let warm = await runner.run(arguments: ["wait", "0"], input: Data(), expectedImage: image)
        XCTAssertNil(warm.failure)
        // A representable duration with many leading zeroes remains a valid wait,
        // while its argv reservation exceeds half this OS's ARG_MAX.
        let duration = String(repeating: "0", count: sysconf(_SC_ARG_MAX) / 2 + 4096) + "30000"
        delay.arm(seconds: 0.6)
        let start = ProcessInfo.processInfo.systemUptime
        let result = await runner.run(arguments: ["wait", duration], input: Data(), expectedImage: image)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertTrue(result.failure?.contains("timed out") == true)
        XCTAssertLessThan(elapsed, 1.6, "Preselection must not grant a new 1.2-second execution budget")
        let cleanup = await runner.shutdown(); XCTAssertNil(cleanup)
    }

    func testExpiredInheritedDeadlineNeverLaunchesOriginalRunner() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("executed")
        let runner = MCPProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/python3"), workerPrefix: ["-c"], timeout: 3,
            invocationDeadline: ProcessInfo.processInfo.systemUptime - 1)
        let result = await runner.run(arguments: ["import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('effect')", marker.path], input: Data(), expectedImage: "fixture")
        XCTAssertNil(result.exitCode)
        XCTAssertTrue(result.failure?.contains("not executed") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
