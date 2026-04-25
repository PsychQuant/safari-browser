import XCTest
import Foundation
import Darwin
@testable import SafariBrowser

/// Section 1 coverage for `daemon-security-hardening` — pure / lightweight
/// tests for the socket-dir resolver and the pid-file write path. Tests
/// that require a running daemon (a/b: socket and pid mode bits) live in
/// the live-Safari integration suite; here we validate (c) TMPDIR-unset
/// rejection, (d) world-writable parent rejection, (e) the
/// `--allow-unsafe-socket-dir` bypass via the pure-function resolver.
final class DaemonSocketPermissionsTests: XCTestCase {

    // MARK: - Pure resolver tests

    func testResolver_explicitSocketDirOverridesEnv() {
        let result = DaemonPaths.resolveSocketDir(
            socketDir: "/var/run/safari-browser",
            env: ["TMPDIR": "/tmp"],
            allowUnsafe: false,
            statF: { _ in DaemonPaths.Stat(mode: 0o755, isDirectory: true) }
        )
        XCTAssertEqual(result, .ok("/var/run/safari-browser"))
    }

    func testResolver_tmpdirEnvUsedWhenNoOverride() {
        let result = DaemonPaths.resolveSocketDir(
            socketDir: nil,
            env: ["TMPDIR": "/private/tmp/sb"],
            allowUnsafe: false,
            statF: { _ in DaemonPaths.Stat(mode: 0o700, isDirectory: true) }
        )
        XCTAssertEqual(result, .ok("/private/tmp/sb"))
    }

    func testResolver_tmpdirUnsetRejected_whenNoOverride() {
        let result = DaemonPaths.resolveSocketDir(
            socketDir: nil,
            env: [:],
            allowUnsafe: false,
            statF: { _ in DaemonPaths.Stat(mode: 0o755, isDirectory: true) }
        )
        if case .rejected(let reason, let msg) = result {
            XCTAssertEqual(reason, .tmpdirUnset)
            XCTAssertTrue(msg.contains("--socket-dir") || msg.contains("TMPDIR"))
        } else {
            XCTFail("expected .rejected(.tmpdirUnset), got \(result)")
        }
    }

    func testResolver_emptyTmpdirRejected() {
        let result = DaemonPaths.resolveSocketDir(
            socketDir: nil,
            env: ["TMPDIR": ""],
            allowUnsafe: false,
            statF: { _ in nil }
        )
        if case .rejected(let reason, _) = result {
            XCTAssertEqual(reason, .tmpdirUnset)
        } else {
            XCTFail("empty TMPDIR should be treated as unset")
        }
    }

    func testResolver_worldWritableParentRejected() {
        // Mode 0o1777 is the standard /tmp sticky-bit world-writable mode.
        let result = DaemonPaths.resolveSocketDir(
            socketDir: nil,
            env: ["TMPDIR": "/tmp"],
            allowUnsafe: false,
            statF: { _ in DaemonPaths.Stat(mode: 0o777, isDirectory: true) }
        )
        if case .rejected(let reason, let msg) = result {
            XCTAssertEqual(reason, .parentWorldWritable)
            XCTAssertTrue(msg.contains("--allow-unsafe-socket-dir"))
        } else {
            XCTFail("expected .parentWorldWritable rejection, got \(result)")
        }
    }

    func testResolver_allowUnsafeBypass() {
        // Same world-writable parent but bypass flag honored.
        let result = DaemonPaths.resolveSocketDir(
            socketDir: nil,
            env: ["TMPDIR": "/tmp"],
            allowUnsafe: true,
            statF: { _ in DaemonPaths.Stat(mode: 0o777, isDirectory: true) }
        )
        XCTAssertEqual(result, .ok("/tmp"))
    }

    func testResolver_missingDirRejected() {
        let result = DaemonPaths.resolveSocketDir(
            socketDir: "/no/such/path",
            env: [:],
            allowUnsafe: false,
            statF: { _ in nil }
        )
        if case .rejected(let reason, _) = result {
            XCTAssertEqual(reason, .parentMissing)
        } else {
            XCTFail("missing dir should reject")
        }
    }

    func testResolver_trailingSlashStripped() {
        let result = DaemonPaths.resolveSocketDir(
            socketDir: "/var/run/sb/",
            env: [:],
            allowUnsafe: false,
            statF: { _ in DaemonPaths.Stat(mode: 0o700, isDirectory: true) }
        )
        XCTAssertEqual(result, .ok("/var/run/sb"))
    }

    func testResolver_safeMode_0o700_accepted() {
        // Owner-only modes are always safe (S_IWOTH bit clear).
        for safeMode: UInt16 in [0o700, 0o750, 0o755] {
            let result = DaemonPaths.resolveSocketDir(
                socketDir: "/safe",
                env: [:],
                allowUnsafe: false,
                statF: { _ in DaemonPaths.Stat(mode: safeMode, isDirectory: true) }
            )
            XCTAssertEqual(result, .ok("/safe"), "mode 0o\(String(safeMode, radix: 8)) should be accepted")
        }
    }

    // MARK: - composeSocketPath

    func testComposeSocketPath_simpleCase() {
        let p = DaemonPaths.composeSocketPath(
            dir: "/private/tmp", prefix: "safari-browser-", name: "default", suffix: ".sock"
        )
        XCTAssertEqual(p, "/private/tmp/safari-browser-default.sock")
    }

    // MARK: - pid file mode (live filesystem)

    /// Task 1.4: pid file SHALL be written with mode 0600 (owner-only)
    /// using `open(2) + O_CREAT|O_WRONLY|O_EXCL` so a racing observer
    /// cannot capture the pid before the file is sealed.
    func testWritePidFile_modeIs0600() throws {
        let tmpDir = NSTemporaryDirectory()
        let pidPath = tmpDir + "test-pid-\(UUID().uuidString).pid"
        defer { unlink(pidPath) }

        try DaemonPaths.writePidFile(at: pidPath, pid: 12345)

        var sb = Darwin.stat()
        let rc = pidPath.withCString { stat($0, &sb) }
        XCTAssertEqual(rc, 0, "stat should succeed on the pid file we just wrote")
        let mode = sb.st_mode & 0o777
        XCTAssertEqual(mode, 0o600, "pid file mode must be 0600, got 0o\(String(mode, radix: 8))")

        // Verify content
        let content = try String(contentsOfFile: pidPath, encoding: .utf8)
        XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "12345")
    }

    func testWritePidFile_failsWhenAlreadyExists() throws {
        // O_EXCL semantics: writing twice without unlinking SHALL fail.
        let pidPath = NSTemporaryDirectory() + "test-pid-excl-\(UUID().uuidString).pid"
        defer { unlink(pidPath) }

        try DaemonPaths.writePidFile(at: pidPath, pid: 1)
        XCTAssertThrowsError(try DaemonPaths.writePidFile(at: pidPath, pid: 2))
    }
}
