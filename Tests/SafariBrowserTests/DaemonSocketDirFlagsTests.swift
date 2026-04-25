import XCTest
import ArgumentParser
@testable import SafariBrowser

/// Section 1 follow-up of `daemon-security-hardening` — CLI flag wiring
/// for `--socket-dir` and `--allow-unsafe-socket-dir`. The pure resolver
/// `DaemonPaths.resolveSocketDir(...)` already enforces the safety
/// contract; these tests pin that the CLI surface plumbs the flags
/// through to the resolver and that `DaemonClient.socketPath(dir:name:)`
/// composes the override path correctly.
final class DaemonSocketDirFlagsTests: XCTestCase {

    // MARK: - DaemonClient overrides

    func testSocketPath_withExplicitDir_usesOverride() {
        let path = DaemonClient.socketPath(dir: "/var/run/sb", name: "default")
        XCTAssertEqual(path, "/var/run/sb/safari-browser-default.sock")
    }

    func testPidPath_withExplicitDir_usesOverride() {
        let path = DaemonClient.pidPath(dir: "/var/run/sb", name: "default")
        XCTAssertEqual(path, "/var/run/sb/safari-browser-default.pid")
    }

    func testLogPath_withExplicitDir_usesOverride() {
        let path = DaemonClient.logPath(dir: "/var/run/sb", name: "default")
        XCTAssertEqual(path, "/var/run/sb/safari-browser-default.log")
    }

    func testSocketPath_dirVsTmpDirOverloads_produceConsistentLayout() {
        // The dir-based overload SHALL produce paths that look identical
        // to the TMPDIR-based default when given the equivalent dir.
        let viaDir = DaemonClient.socketPath(dir: "/tmp", name: "n")
        XCTAssertEqual(viaDir, "/tmp/safari-browser-n.sock")
    }

    // MARK: - ArgumentParser parsing

    func testDaemonStart_parsesSocketDirFlag() throws {
        let cmd = try DaemonStartCommand.parse(["--socket-dir", "/var/run/sb"])
        XCTAssertEqual(cmd.socketDirFlags.socketDir, "/var/run/sb")
        XCTAssertFalse(cmd.socketDirFlags.allowUnsafeSocketDir)
    }

    func testDaemonStart_parsesAllowUnsafeFlag() throws {
        let cmd = try DaemonStartCommand.parse(["--allow-unsafe-socket-dir"])
        XCTAssertTrue(cmd.socketDirFlags.allowUnsafeSocketDir)
        XCTAssertNil(cmd.socketDirFlags.socketDir)
    }

    func testDaemonStart_parsesBothFlagsTogether() throws {
        let cmd = try DaemonStartCommand.parse([
            "--socket-dir", "/tmp",
            "--allow-unsafe-socket-dir",
            "--name", "ci",
        ])
        XCTAssertEqual(cmd.socketDirFlags.socketDir, "/tmp")
        XCTAssertTrue(cmd.socketDirFlags.allowUnsafeSocketDir)
        XCTAssertEqual(cmd.nameFlag.name, "ci")
    }

    func testDaemonStop_parsesSocketDirFlag() throws {
        let cmd = try DaemonStopCommand.parse(["--socket-dir", "/var/run/sb"])
        XCTAssertEqual(cmd.socketDirFlags.socketDir, "/var/run/sb")
    }

    func testDaemonStatus_parsesSocketDirFlag() throws {
        let cmd = try DaemonStatusCommand.parse(["--socket-dir", "/var/run/sb"])
        XCTAssertEqual(cmd.socketDirFlags.socketDir, "/var/run/sb")
    }

    func testDaemonLogs_parsesSocketDirFlag() throws {
        let cmd = try DaemonLogsCommand.parse(["--socket-dir", "/var/run/sb"])
        XCTAssertEqual(cmd.socketDirFlags.socketDir, "/var/run/sb")
    }

    func testDaemonServe_parsesSocketDirFlag() throws {
        let cmd = try DaemonServeCommand.parse(["--socket-dir", "/var/run/sb"])
        XCTAssertEqual(cmd.socketDirFlags.socketDir, "/var/run/sb")
    }

    // MARK: - resolveDaemonSocketDir contract

    func testResolveDaemonSocketDir_explicitOverrideWins() throws {
        // We can't easily inject a fake env, so we use a directory we know
        // exists with safe permissions: NSTemporaryDirectory() under
        // /var/folders/.../T which is owner-only on macOS.
        let tmp = NSTemporaryDirectory()
        let flags = try DaemonSocketDirFlags.parse(["--socket-dir", tmp])
        let resolved = try resolveDaemonSocketDir(flags: flags)
        // The resolver strips trailing slashes; tmp may end with `/`.
        XCTAssertEqual(resolved, tmp.hasSuffix("/") ? String(tmp.dropLast()) : tmp)
    }

    func testResolveDaemonSocketDir_rejectsMissingDir() {
        let flags = (try? DaemonSocketDirFlags.parse(["--socket-dir", "/no/such/path/zzz-\(UUID().uuidString)"])) ?? DaemonSocketDirFlags()
        XCTAssertThrowsError(try resolveDaemonSocketDir(flags: flags)) { error in
            XCTAssertTrue("\(error)".contains("does not exist") || "\(error)".contains("not statable"),
                          "expected missing-dir rejection: \(error)")
        }
    }
}
