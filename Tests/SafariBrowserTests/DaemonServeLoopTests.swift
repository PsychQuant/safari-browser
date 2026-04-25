import XCTest
import Foundation
@testable import SafariBrowser

/// Task 6.2 — `DaemonServeLoop.Server` encapsulates the full daemon serve
/// lifecycle (pid file + server + cache + dispatch registration + watchdog
/// + graceful shutdown) so the CLI subcommand bodies can be thin wrappers
/// and the core logic is testable in-process without forking a real process.
final class DaemonServeLoopTests: XCTestCase {

    var socketPath: String!
    var pidPath: String!

    override func setUp() async throws {
        try await super.setUp()
        let suffix = String(UUID().uuidString.prefix(8))
        socketPath = "\(NSTemporaryDirectory())sl-\(suffix).sock"
        pidPath = "\(NSTemporaryDirectory())sl-\(suffix).pid"
    }

    override func tearDown() async throws {
        unlink(socketPath)
        unlink(pidPath)
        try await super.tearDown()
    }

    // MARK: - Lifecycle

    func testStart_writesPidFile() async throws {
        let loop = DaemonServeLoop.Server()
        try await loop.start(
            socketPath: socketPath,
            pidPath: pidPath,
            idleTimeout: 60
        )
        defer { Task { await loop.stop() } }

        XCTAssertTrue(FileManager.default.fileExists(atPath: pidPath))
        // Section 4: pid file is JSON `PidRecord` with (pid, exec, boot)
        // — readPidFile decodes and verifies the recorded pid matches us.
        switch DaemonPaths.readPidFile(at: pidPath) {
        case .ok(let record):
            XCTAssertEqual(record.pid, getpid())
            XCTAssertFalse(record.exec.isEmpty)
        case .stale, .absent:
            XCTFail("pid file should be readable as JSON PidRecord")
        }
    }

    func testStop_removesPidAndSocket() async throws {
        let loop = DaemonServeLoop.Server()
        try await loop.start(
            socketPath: socketPath,
            pidPath: pidPath,
            idleTimeout: 60
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        await loop.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: pidPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testStart_twice_isIdempotent() async throws {
        let loop = DaemonServeLoop.Server()
        try await loop.start(
            socketPath: socketPath,
            pidPath: pidPath,
            idleTimeout: 60
        )
        // Second start must be a no-op, not throw.
        try await loop.start(
            socketPath: socketPath,
            pidPath: pidPath,
            idleTimeout: 60
        )
        defer { Task { await loop.stop() } }

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    // MARK: - daemon.shutdown method

    func testDaemonShutdown_method_exitsLoop() async throws {
        let loop = DaemonServeLoop.Server()
        try await loop.start(
            socketPath: socketPath,
            pidPath: pidPath,
            idleTimeout: 60
        )

        // Send shutdown request by pointing the raw-socket client at the
        // test socket path directly; the production DaemonClient uses a
        // NAME-based path that doesn't apply here.
        let fd = try TestUnixSocket.connect(path: socketPath)
        try TestUnixSocket.writeLine(
            fd: fd,
            line: #"{"method":"daemon.shutdown","params":{},"requestId":1}"#
        )
        _ = try TestUnixSocket.readLine(fd: fd)
        close(fd)

        // Give the daemon a beat to process shutdown and clean up.
        for _ in 0..<50 {
            if !FileManager.default.fileExists(atPath: socketPath) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidPath))
    }

    // MARK: - daemon.status method

    func testDaemonStatus_method_returnsStats() async throws {
        let loop = DaemonServeLoop.Server()
        try await loop.start(
            socketPath: socketPath,
            pidPath: pidPath,
            idleTimeout: 60
        )
        defer { Task { await loop.stop() } }

        let fd = try TestUnixSocket.connect(path: socketPath)
        defer { close(fd) }
        try TestUnixSocket.writeLine(
            fd: fd,
            line: #"{"method":"daemon.status","params":{},"requestId":1}"#
        )
        let line = try TestUnixSocket.readLine(fd: fd)
        let data = Data(line.utf8)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let result = try XCTUnwrap(json?["result"] as? [String: Any])
        XCTAssertNotNil(result["pid"], "status should include pid")
        XCTAssertNotNil(result["uptimeSeconds"], "status should include uptime")
        XCTAssertNotNil(result["requestCount"], "status should include request count")
        XCTAssertNotNil(result["preCompiledCount"], "status should include pre-compiled script count")
        XCTAssertNotNil(result["lastActivityEpoch"], "status should include last activity")
    }

    // MARK: - isDaemonAlive helper

    func testIsDaemonAlive_returnsFalseWhenNothingRunning() {
        let alive = DaemonServeLoop.isDaemonAlive(
            socketPath: socketPath,
            pidPath: pidPath
        )
        XCTAssertFalse(alive)
    }

    func testIsDaemonAlive_returnsTrueWhenLoopRunning() async throws {
        let loop = DaemonServeLoop.Server()
        try await loop.start(
            socketPath: socketPath,
            pidPath: pidPath,
            idleTimeout: 60
        )
        defer { Task { await loop.stop() } }

        let alive = DaemonServeLoop.isDaemonAlive(
            socketPath: socketPath,
            pidPath: pidPath
        )
        XCTAssertTrue(alive)
    }

    func testIsDaemonAlive_stalePidFile_returnsFalse() throws {
        // Write a pid pointing at a definitely-dead process.
        // PID 1 (launchd) is always alive on macOS, so pick something high
        // that's very unlikely to be a real running process.
        try "999999".write(toFile: pidPath, atomically: true, encoding: .utf8)
        // Matching socket file to pass the cheap existence check.
        FileManager.default.createFile(atPath: socketPath, contents: nil)

        let alive = DaemonServeLoop.isDaemonAlive(
            socketPath: socketPath,
            pidPath: pidPath
        )
        XCTAssertFalse(alive)
    }
}
