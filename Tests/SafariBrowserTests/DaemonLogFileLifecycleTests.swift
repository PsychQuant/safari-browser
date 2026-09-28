import Foundation
import XCTest
@testable import SafariBrowser

/// Uses the production ServeLoop file sink, never a Safari handler.
final class DaemonLogFileLifecycleTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func hit() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func records(at url: URL) throws -> [[String: Any]] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    func testProductionFileSinkRecordsNormalShutdownHandoff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("f205-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = DaemonClient.socketPath(dir: directory.path, name: "owned")
        let pid = directory.appendingPathComponent("owned.pid")
        let log = directory.appendingPathComponent("owned.log")
        let server = DaemonServeLoop.Server()
        do {
            try await server.start(socketPath: socket, pidPath: pid.path, idleTimeout: 60,
                logPath: log.path, env: [:], stderrWriter: { _ in })
            let response = try await DaemonClient.sendRequest(name: "owned", method: "daemon.shutdown",
                params: Data("{}".utf8), requestId: 205, timeout: 2, socketDir: directory.path)
            XCTAssertEqual(response, Data("{}".utf8))
            let reason = await server.waitUntilStopped()
            XCTAssertEqual(reason, .requested)
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !(try records(at: log).contains { $0["event"] as? String == "request_shutdown_handoff" }),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let rows = try records(at: log)
            print("#205 production file events: \(rows.compactMap { $0["event"] as? String })")
            XCTAssertEqual(rows.count, 3, "a live owned file sink must not be eagerly closed before the final event")
            let handoff = try XCTUnwrap(rows.first { $0["event"] as? String == "request_shutdown_handoff" })
            XCTAssertEqual(handoff["outcome"] as? String, "hook_returned")
            XCTAssertEqual(handoff["peerReceipt"] as? String, "unconfirmed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
            XCTAssertFalse(FileManager.default.fileExists(atPath: pid.path))
            await server.stop()
        } catch { await server.stop(); throw error }
    }
    func testCapturedOldRunWriterAppendsAfterRestartAndClosesAtRetirement() async throws {
        for full in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lease205-" + String(UUID().uuidString.prefix(8)))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let socket = DaemonClient.socketPath(dir: directory.path, name: "owned")
            let pid = directory.appendingPathComponent("owned.pid"), log = directory.appendingPathComponent("owned.log")
            let server = DaemonServeLoop.Server(), oldCloses = Counter(), newCloses = Counter()
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let entered = expectation(description: "old prepared record persisted before writer blocks")
            let newWritten = expectation(description: "replacement candidate persisted before old writer resumes")
            let env = full ? [DaemonLog.logFullEnvVar: "1"] : [:]
            do {
                try await server.start(socketPath: socket, pidPath: pid.path, idleTimeout: 60,
                    logPath: log.path, env: env, stderrWriter: { _ in }, lifecycle: .init(afterLogWriteAttempt: { line in
                        if line.contains("request_response_prepared") {
                            entered.fulfill()
                            _ = release.wait(timeout: .now() + 5)
                        }
                    }, didCloseLog: { oldCloses.hit() }))
                let client = Task {
                    do {
                        _ = try await DaemonClient.sendRequest(name: "owned", method: "daemon.shutdown",
                            params: Data("{}".utf8), requestId: 7, timeout: 2, socketDir: directory.path)
                        return false
                    } catch let error as DaemonClient.Error {
                        if case .requestOutcomeUnknown = error { return true }
                        return false
                    } catch { return false }
                }
                await fulfillment(of: [entered], timeout: 1)
                let started = ContinuousClock.now
                await server.stop()
                XCTAssertLessThan(started.duration(to: .now), .seconds(1))
                let unknown = await client.value
                XCTAssertTrue(unknown)
                XCTAssertEqual(oldCloses.value, 0, "captured old writer still owns its sink")
                try await server.start(socketPath: socket, pidPath: pid.path, idleTimeout: 60,
                    logPath: log.path, env: env, stderrWriter: { _ in }, lifecycle: .init(afterLogWriteAttempt: { line in
                        if line.contains("request_response_candidate") { newWritten.fulfill() }
                    }, didCloseLog: { newCloses.hit() }))
                _ = try await DaemonClient.sendRequest(name: "owned", method: "daemon.status",
                    params: Data("{}".utf8), requestId: 7, timeout: 1, socketDir: directory.path)
                await fulfillment(of: [newWritten], timeout: 1)
                let before = try records(at: log)
                XCTAssertEqual(before.count, 3)
                release.signal()
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while oldCloses.value == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertEqual(oldCloses.value, 1)
                let rows = try records(at: log)
                XCTAssertEqual(rows.count, 4, "late old append must preserve all replacement records")
                let oldPrepared = try XCTUnwrap(rows.first { $0["method"] as? String == "daemon.shutdown" })
                let newPrepared = try XCTUnwrap(rows.first { $0["method"] as? String == "daemon.status" })
                let oldToken = try XCTUnwrap(oldPrepared["requestToken"] as? String)
                let newToken = try XCTUnwrap(newPrepared["requestToken"] as? String)
                XCTAssertNotEqual(oldToken, newToken)
                let oldCandidate = try XCTUnwrap(rows.first { $0["event"] as? String == "request_response_candidate" && $0["requestToken"] as? String == oldToken })
                XCTAssertEqual(oldCandidate["outcome"] as? String, "cancelled")
                XCTAssertEqual(oldCandidate["selection"] as? String, "not_selected")
                XCTAssertEqual(rows.filter { $0["requestToken"] as? String == newToken }.count, 2)
                await server.stop()
                let closeDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while newCloses.value == 0, ContinuousClock.now < closeDeadline { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertEqual(newCloses.value, 1)
            } catch { release.signal(); await server.stop(); throw error }
        }
    }
    func testStartupFailureReleasesFileSinkWithoutLeavingRunResources() async throws {
        enum FixtureFailure: Error { case expected }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fail205-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = DaemonClient.socketPath(dir: directory.path, name: "owned")
        let pid = directory.appendingPathComponent("owned.pid"), log = directory.appendingPathComponent("owned.log")
        let server = DaemonServeLoop.Server(), closes = Counter()
        do {
            try await server.start(socketPath: socket, pidPath: pid.path, idleTimeout: 60,
                logPath: log.path, env: [:], stderrWriter: { _ in }, lifecycle: .init(
                    beforeListenerStart: { throw FixtureFailure.expected }, didCloseLog: { closes.hit() }))
            XCTFail("injected startup failure must propagate")
            await server.stop()
        } catch FixtureFailure.expected {
            let reason = await server.waitUntilStopped()
            XCTAssertEqual(reason, .startupFailed)
        } catch { await server.stop(); throw error }
        XCTAssertEqual(closes.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pid.path))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "")
    }
}
