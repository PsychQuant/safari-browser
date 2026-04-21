import XCTest
import Foundation
@testable import SafariBrowser

/// Task 6.1 — `Idle auto-shutdown` requirement. Covers the env var parse +
/// clamp to `[60, 3600]`, activity tracking via `recordActivity(at:)`, and
/// the pure `isIdle(now:)` decision used by the production watchdog.
final class DaemonIdleTimeoutTests: XCTestCase {

    // MARK: - Env var parse + clamp

    func testResolveIdleTimeout_defaultWhenNoEnv() {
        XCTAssertEqual(DaemonServer.Instance.resolveIdleTimeout(env: [:]), 600)
    }

    func testResolveIdleTimeout_validValuePassesThrough() {
        XCTAssertEqual(
            DaemonServer.Instance.resolveIdleTimeout(env: ["SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT": "120"]),
            120
        )
    }

    func testResolveIdleTimeout_belowMinClampsTo60() {
        XCTAssertEqual(
            DaemonServer.Instance.resolveIdleTimeout(env: ["SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT": "10"]),
            60
        )
    }

    func testResolveIdleTimeout_aboveMaxClampsTo3600() {
        XCTAssertEqual(
            DaemonServer.Instance.resolveIdleTimeout(env: ["SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT": "99999"]),
            3600
        )
    }

    func testResolveIdleTimeout_nonNumericFallsBackToDefault() {
        XCTAssertEqual(
            DaemonServer.Instance.resolveIdleTimeout(env: ["SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT": "not-a-number"]),
            600
        )
    }

    func testResolveIdleTimeout_emptyFallsBackToDefault() {
        XCTAssertEqual(
            DaemonServer.Instance.resolveIdleTimeout(env: ["SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT": ""]),
            600
        )
    }

    // MARK: - isIdle decision

    func testIsIdle_beforeTimeout_returnsFalse() async {
        let server = DaemonServer.Instance()
        await server.configureIdleTimeout(60)
        let t0 = Date()
        await server.recordActivity(at: t0)
        let idle = await server.isIdle(now: t0.addingTimeInterval(59))
        XCTAssertFalse(idle)
    }

    func testIsIdle_atTimeout_returnsTrue() async {
        let server = DaemonServer.Instance()
        await server.configureIdleTimeout(60)
        let t0 = Date()
        await server.recordActivity(at: t0)
        let idle = await server.isIdle(now: t0.addingTimeInterval(60))
        XCTAssertTrue(idle)
    }

    func testIsIdle_afterTimeout_returnsTrue() async {
        let server = DaemonServer.Instance()
        await server.configureIdleTimeout(60)
        let t0 = Date()
        await server.recordActivity(at: t0)
        let idle = await server.isIdle(now: t0.addingTimeInterval(61))
        XCTAssertTrue(idle)
    }

    // MARK: - recordActivity resets the idle clock

    func testRecordActivity_resetsIdleClock() async {
        let server = DaemonServer.Instance()
        await server.configureIdleTimeout(60)
        let t0 = Date()
        await server.recordActivity(at: t0)

        // At t0 + 50: not yet idle
        let idleAt50 = await server.isIdle(now: t0.addingTimeInterval(50))
        XCTAssertFalse(idleAt50)

        // Activity at t0 + 55 pushes the clock forward
        await server.recordActivity(at: t0.addingTimeInterval(55))

        // At t0 + 110 (55s after latest activity): not yet idle
        let idleAt110 = await server.isIdle(now: t0.addingTimeInterval(110))
        XCTAssertFalse(idleAt110)

        // At t0 + 116 (61s after latest activity): idle
        let idleAt116 = await server.isIdle(now: t0.addingTimeInterval(116))
        XCTAssertTrue(idleAt116)
    }

    // MARK: - Dispatch path updates activity

    /// A request flowing through the server MUST update `lastActivity` so
    /// the idle watchdog doesn't kill an actively-used daemon.
    func testDispatchedRequest_updatesLastActivity() async throws {
        let server = DaemonServer.Instance()
        await server.configureIdleTimeout(60)
        let before = Date().addingTimeInterval(-120)
        await server.recordActivity(at: before)
        // Before any new activity, the daemon would be considered idle at "now".
        let idleBeforeRequest = await server.isIdle(now: Date())
        XCTAssertTrue(idleBeforeRequest)

        let socketPath = "\(NSTemporaryDirectory())idle-\(UUID().uuidString.prefix(8)).sock"
        await server.register("echo") { params in params }
        try await server.start(socketPath: socketPath)
        defer {
            Task { await server.stop() }
            unlink(socketPath)
        }

        let fd = try TestUnixSocket.connect(path: socketPath)
        defer { close(fd) }
        try TestUnixSocket.writeLine(fd: fd, line: #"{"method":"echo","params":{},"requestId":1}"#)
        _ = try TestUnixSocket.readLine(fd: fd)

        // After the request the daemon should no longer be idle.
        let idleAfterRequest = await server.isIdle(now: Date())
        XCTAssertFalse(idleAfterRequest)
    }
}
