import XCTest
import Foundation
@testable import SafariBrowser

/// Covers the `Namespace isolation via NAME` spec requirement.
/// Resolution precedence: `--name` flag > `SAFARI_BROWSER_NAME` env > `"default"`.
final class DaemonClientTests: XCTestCase {

    private let envKey = "SAFARI_BROWSER_NAME"

    override func setUp() async throws {
        try await super.setUp()
        unsetenv(envKey)
    }

    override func tearDown() async throws {
        unsetenv(envKey)
        try await super.tearDown()
    }

    // MARK: - NAME resolution

    func testResolveName_defaultWhenNoFlagNoEnv() {
        XCTAssertEqual(DaemonClient.resolveName(flag: nil, env: [:]), "default")
    }

    func testResolveName_envFallback() {
        XCTAssertEqual(
            DaemonClient.resolveName(flag: nil, env: [envKey: "from-env"]),
            "from-env"
        )
    }

    func testResolveName_flagBeatsEnv() {
        XCTAssertEqual(
            DaemonClient.resolveName(flag: "from-flag", env: [envKey: "from-env"]),
            "from-flag"
        )
    }

    func testResolveName_emptyFlagFallsThroughToEnv() {
        // `--name ""` should not clobber env; treat as unset.
        XCTAssertEqual(
            DaemonClient.resolveName(flag: "", env: [envKey: "from-env"]),
            "from-env"
        )
    }

    func testResolveName_emptyEnvFallsThroughToDefault() {
        XCTAssertEqual(
            DaemonClient.resolveName(flag: nil, env: [envKey: ""]),
            "default"
        )
    }

    // MARK: - Socket path derivation

    func testSocketPath_usesTmpDirAndName() {
        let path = DaemonClient.socketPath(name: "alpha")
        XCTAssertTrue(
            path.hasSuffix("safari-browser-alpha.sock"),
            "unexpected path: \(path)"
        )
        // Must sit under an accessible temp dir (macOS TMPDIR usually under /var or per-user).
        let dir = (path as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - End-to-end client <-> server round trip

    func testSendRequest_roundTripsJSON() async throws {
        let name = "client-test-\(UUID().uuidString.prefix(8))"
        let socketPath = DaemonClient.socketPath(name: String(name))
        let server = DaemonServer.Instance()
        await server.register("echo") { params in params }
        try await server.start(socketPath: socketPath)
        defer {
            Task { await server.stop() }
        }

        let resultData = try await DaemonClient.sendRequest(
            name: String(name),
            method: "echo",
            params: Data(#"{"hello":"world"}"#.utf8),
            requestId: 1
        )
        let result = try JSONSerialization.jsonObject(with: resultData, options: []) as? [String: Any]
        XCTAssertEqual(result?["hello"] as? String, "world")
    }

    func testSendRequest_surfacesServerError() async throws {
        let name = "client-err-\(UUID().uuidString.prefix(8))"
        let socketPath = DaemonClient.socketPath(name: String(name))
        let server = DaemonServer.Instance()
        try await server.start(socketPath: socketPath)
        defer { Task { await server.stop() } }

        do {
            _ = try await DaemonClient.sendRequest(
                name: String(name),
                method: "does.not.exist",
                params: Data("{}".utf8),
                requestId: 2
            )
            XCTFail("expected methodNotFound")
        } catch DaemonClient.Error.remoteError(let code, _) {
            XCTAssertEqual(code, "methodNotFound")
        }
    }

    // MARK: - Timeout (failure mode (e) from Silent fallback spec)

    func testSendRequest_timeout_raisesIoError() async throws {
        let name = "timeout-\(UUID().uuidString.prefix(8))"
        let socketPath = DaemonClient.socketPath(name: String(name))
        let server = DaemonServer.Instance()
        await server.register("hang") { _ in
            // Sleep longer than the client's timeout. When the client hits
            // SO_RCVTIMEO, the socket read errors with EAGAIN — mapped to
            // ioError — and the task group returns without waiting for us.
            try await Task.sleep(for: .seconds(30))
            return Data("{}".utf8)
        }
        try await server.start(socketPath: socketPath)
        defer { Task { await server.stop() } }

        let start = Date()
        do {
            _ = try await DaemonClient.sendRequest(
                name: String(name),
                method: "hang",
                params: Data("{}".utf8),
                requestId: 1,
                timeout: 0.5
            )
            XCTFail("expected ioError timeout")
        } catch DaemonClient.Error.ioError {
            // ok
        } catch {
            XCTFail("expected ioError, got \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "timeout should fire near 0.5s, not wait full 30s")
    }

    func testSendRequest_failsWhenNoDaemon() async throws {
        let name = "no-daemon-\(UUID().uuidString.prefix(8))"
        do {
            _ = try await DaemonClient.sendRequest(
                name: String(name),
                method: "echo",
                params: Data("{}".utf8),
                requestId: 1
            )
            XCTFail("expected connectFailed")
        } catch DaemonClient.Error.connectFailed {
            // ok
        }
    }
}
