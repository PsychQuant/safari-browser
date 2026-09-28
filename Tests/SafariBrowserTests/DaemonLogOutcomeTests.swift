import Foundation
import XCTest
@testable import SafariBrowser

/// Real socket and captured-writer contracts for #205.
final class DaemonLogOutcomeTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) -> Bool {
            lock.withLock {
                storage.append(line)
                return storage.count == 1
            }
        }
        var values: [String] { lock.withLock { storage } }
    }

    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("o205-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func rows(_ log: Lines) throws -> [[String: Any]] {
        try log.values.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let satisfied = await predicate()
        XCTAssertTrue(satisfied, "owned fixture did not reach its expected state")
    }

    func testRevokedShutdownDistinguishesPreparedResponseFromRejectedCandidate() async throws {
        for full in [false, true] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("l205-" + String(UUID().uuidString.prefix(8)))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = DaemonClient.socketPath(dir: directory.path, name: "owned")
            let old = Lines(), replacement = Lines(), release = DispatchSemaphore(value: 0)
            let entered = expectation(description: "old shutdown log entered, full=\(full)")
            let server = DaemonServer.Instance()
            do {
                await server.setLogWriter({ line in
                    if old.append(line) {
                        entered.fulfill()
                        _ = release.wait(timeout: .now() + 5)
                    }
                }, logFull: full)
                try await server.start(socketPath: path)
                let client = Task {
                    do {
                        _ = try await DaemonClient.sendRequest(name: "owned", method: "daemon.shutdown",
                            params: Data("{}".utf8), requestId: 205, timeout: 2, socketDir: directory.path)
                        return "unexpected success"
                    } catch let error as DaemonClient.Error {
                        if case .requestOutcomeUnknown = error { return "unknown" }
                        return error.description
                    } catch { return String(describing: error) }
                }
                await fulfillment(of: [entered], timeout: 1)
                // stop must finish while the old writer remains blocked.
                await server.stop()
                let outcome = await client.value
                XCTAssertEqual(outcome, "unknown")
                await server.setLogWriter({ line in _ = replacement.append(line) }, logFull: full)
                try await server.start(socketPath: path)
                release.signal()
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while await server.activeOperationCount > 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let operations = await server.activeOperationCount
                XCTAssertEqual(operations, 0)
                XCTAssertEqual(old.values.count, 2, "prepared response needs the later candidate outcome")
                XCTAssertTrue(replacement.values.isEmpty, "old work must not borrow the new logger")
                let log = try XCTUnwrap(old.values.first)
                let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(log.utf8)) as? [String: Any])
                XCTAssertEqual(entry["method"] as? String, "daemon.shutdown")
                XCTAssertEqual((entry["result"] as? [String: Any])?.count, 0)
                XCTAssertTrue(entry["error"] is NSNull)
                XCTAssertEqual(entry["event"] as? String, "request_response_prepared")
                XCTAssertEqual(entry["peerReceipt"] as? String, "unconfirmed")
                let token = try XCTUnwrap(entry["requestToken"] as? String)
                XCTAssertNotNil(UUID(uuidString: token))
                let final = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(old.values.last).utf8)) as? [String: Any])
                XCTAssertEqual(final["event"] as? String, "request_response_candidate")
                XCTAssertEqual(final["outcome"] as? String, "cancelled")
                XCTAssertEqual(final["selection"] as? String, "not_selected")
                XCTAssertEqual(final["requestToken"] as? String, token)
                XCTAssertEqual(final["peerReceipt"] as? String, "unconfirmed")
                XCTAssertEqual(Set(final.keys), ["ts", "event", "requestToken", "peerReceipt", "outcome", "selection"])
                let status = try await DaemonClient.sendRequest(name: "owned", method: "daemon.status",
                    params: Data("{}".utf8), requestId: 206, timeout: 2, socketDir: directory.path)
                XCTAssertNotNil(try JSONSerialization.jsonObject(with: status) as? [String: Any])
                await server.stop()
            } catch {
                release.signal()
                await server.stop()
                throw error
            }
        }
    }
    func testNormalShutdownLogsGuardedHandoffWithoutClaimingPeerReceipt() async throws {
        for useHook in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("n205-" + String(UUID().uuidString.prefix(8)))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = DaemonClient.socketPath(dir: directory.path, name: "owned")
            let server = DaemonServer.Instance(), log = Lines()
            do {
                await server.setLogWriter { line in _ = log.append(line) }
                if useHook { await server.setShutdownHook { await server.stop() } }
                try await server.start(socketPath: path)
                let data = try await DaemonClient.sendRequest(name: "owned", method: "daemon.shutdown",
                    params: Data("{}".utf8), requestId: 205, timeout: 2, socketDir: directory.path)
                XCTAssertEqual(data, Data("{}".utf8))
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while log.values.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: path))
                XCTAssertEqual(log.values.count, 3)
                let objects = try log.values.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
                let prepared = try XCTUnwrap(objects.first { $0["event"] as? String == "request_response_prepared" })
                let token = try XCTUnwrap(prepared["requestToken"] as? String)
                XCTAssertNotNil(UUID(uuidString: token))
                for row in objects {
                    XCTAssertEqual(row["requestToken"] as? String, token)
                    XCTAssertEqual(row["peerReceipt"] as? String, "unconfirmed")
                }
                let candidate = try XCTUnwrap(objects.first { $0["event"] as? String == "request_response_candidate" })
                XCTAssertEqual(candidate["outcome"] as? String, "result")
                XCTAssertEqual(candidate["selection"] as? String, "selected")
                let handoff = try XCTUnwrap(objects.first { $0["event"] as? String == "request_shutdown_handoff" })
                XCTAssertEqual(handoff["outcome"] as? String, useHook ? "hook_returned" : "instance_stopped")
                XCTAssertEqual(Set(handoff.keys), ["ts", "event", "requestToken", "peerReceipt", "outcome"])
                await server.stop()
            } catch { await server.stop(); throw error }
        }
    }
    func testPlanRevokedBeforeHandoffCannotBorrowReplacementHook() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = Gate(), old = Lines(), replacement = Lines(), hooks = Lines()
        let entered = expectation(description: "ACK attempted before final handoff")
        let server = DaemonServer.Instance(connectionObservation: .init(beforeShutdownHandoff: {
            entered.fulfill()
            await gate.wait()
        }))
        let path = DaemonClient.socketPath(dir: directory.path, name: "owned")
        do {
            await server.setLogWriter { line in _ = old.append(line) }
            await server.setShutdownHook { _ = hooks.append("old"); await server.stop() }
            try await server.start(socketPath: path)
            let ack = try await DaemonClient.sendRequest(name: "owned", method: "daemon.shutdown",
                params: Data("{}".utf8), requestId: 7, timeout: 1, socketDir: directory.path)
            XCTAssertEqual(ack, Data("{}".utf8))
            await fulfillment(of: [entered], timeout: 1)
            await server.stop()
            await server.setLogWriter { line in _ = replacement.append(line) }
            await server.setShutdownHook { _ = hooks.append("replacement"); await server.stop() }
            try await server.start(socketPath: path)
            await gate.release()
            try await waitUntil { old.values.count == 3 }
            XCTAssertTrue(hooks.values.isEmpty)
            XCTAssertTrue(replacement.values.isEmpty)
            let oldRows = try rows(old)
            XCTAssertEqual(oldRows.first { $0["event"] as? String == "request_shutdown_handoff" }?["outcome"] as? String, "rejected")
            XCTAssertEqual(Set(oldRows.compactMap { $0["requestToken"] as? String }).count, 1)
            _ = try await DaemonClient.sendRequest(name: "owned", method: "daemon.status",
                params: Data("{}".utf8), requestId: 7, timeout: 1, socketDir: directory.path)
            await server.stop()
        } catch { await gate.release(); await server.stop(); throw error }
    }

    func testBlockedCandidateWriterCannotDelayReplyOrStop() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = expectation(description: "candidate writer blocked")
        let release = DispatchSemaphore(value: 0), log = Lines(), server = DaemonServer.Instance()
        defer { release.signal() }
        do {
            await server.setLogWriter { line in
                _ = log.append(line)
                if line.contains("request_response_candidate") {
                    entered.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                }
            }
            await server.register("owned") { _ in Data("true".utf8) }
            try await server.start(socketPath: DaemonClient.socketPath(dir: directory.path, name: "owned"))
            let client = Task {
                try await DaemonClient.sendRequest(name: "owned", method: "owned", params: Data("{}".utf8),
                    requestId: 7, timeout: 1, socketDir: directory.path)
            }
            await fulfillment(of: [entered], timeout: 1)
            let reply = try await client.value
            XCTAssertEqual(reply, Data("true".utf8), "response must not await the candidate writer")
            let started = ContinuousClock.now
            await server.stop()
            XCTAssertLessThan(started.duration(to: .now), .seconds(1))
            let unfinished = await server.activeOperationCount
            XCTAssertEqual(unfinished, 1, "blocked existing operation remains honestly tracked")
            release.signal()
            try await waitUntil { await server.activeOperationCount == 0 }
            XCTAssertEqual(log.values.count, 2)
        } catch { release.signal(); await server.stop(); throw error }
    }

    func testBlockedHandoffWriterRunsAfterStopAndKeepsOldLogger() async throws {
        for useNoStopHook in [false, true] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let entered = expectation(description: "handoff writer blocked after stop")
            let release = DispatchSemaphore(value: 0), old = Lines(), replacement = Lines(), finishes = Lines()
            let finished = expectation(description: "original transport finishes while handoff writer remains blocked")
            let server = DaemonServer.Instance(connectionObservation: .init(didFinish: {
                if finishes.append("finished") { finished.fulfill() }
            }))
            defer { release.signal() }
            let path = DaemonClient.socketPath(dir: directory.path, name: "owned")
            do {
                await server.setLogWriter { line in
                    _ = old.append(line)
                    if line.contains("request_shutdown_handoff") {
                        entered.fulfill()
                        _ = release.wait(timeout: .now() + 5)
                    }
                }
                if useNoStopHook { await server.setShutdownHook {} }
                try await server.start(socketPath: path)
                _ = try await DaemonClient.sendRequest(name: "owned", method: "daemon.shutdown",
                    params: Data("{}".utf8), requestId: 7, timeout: 1, socketDir: directory.path)
                await fulfillment(of: [entered], timeout: 1)
                await fulfillment(of: [finished], timeout: 1)
                XCTAssertEqual(FileManager.default.fileExists(atPath: path), useNoStopHook)
                let connections = await server.trackedConnectionCount
                XCTAssertEqual(connections, 0, "even a custom hook must not retain the transport behind its logger")
                let unfinished = await server.activeOperationCount
                XCTAssertEqual(unfinished, 1, "the blocked handoff writer belongs to the original tracked operation")
                let started = ContinuousClock.now
                await server.stop()
                XCTAssertLessThan(started.duration(to: .now), .seconds(1))
                await server.setLogWriter { line in _ = replacement.append(line) }
                try await server.start(socketPath: path)
                _ = try await DaemonClient.sendRequest(name: "owned", method: "daemon.status",
                    params: Data("{}".utf8), requestId: 7, timeout: 1, socketDir: directory.path)
                release.signal()
                try await waitUntil {
                    let pending = await server.activeOperationCount
                    return old.values.count == 3 && replacement.values.count == 2 && pending == 0
                }
                let oldToken = try XCTUnwrap(rows(old).first?["requestToken"] as? String)
                let newTokens = try rows(replacement).compactMap { $0["requestToken"] as? String }
                XCTAssertEqual(Set(newTokens).count, 1)
                XCTAssertFalse(newTokens.contains(oldToken), "reused client requestId must not merge different operations")
                await server.stop()
            } catch { release.signal(); await server.stop(); throw error }
        }
    }

    func testLateHandlerUsesCapturedLoggerAndReportsItsActualOffer() async throws {
        for stopBeforeReturn in [false, true] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let gate = Gate(), old = Lines(), replacement = Lines(), server = DaemonServer.Instance()
            let entered = expectation(description: "owned noncooperative handler entered")
            let path = DaemonClient.socketPath(dir: directory.path, name: "owned")
            do {
                await server.setLogWriter { line in _ = old.append(line) }
                await server.register("owned") { _ in
                    entered.fulfill()
                    await gate.wait()
                    return Data("true".utf8)
                }
                try await server.start(socketPath: path)
                let client = Task {
                    do {
                        let data = try await DaemonClient.sendRequest(name: "owned", method: "owned",
                            params: Data("{}".utf8), requestId: 7, timeout: 2, socketDir: directory.path)
                        return String(decoding: data, as: UTF8.self)
                    } catch let error as DaemonClient.Error {
                        if case .requestOutcomeUnknown = error { return "unknown" }
                        return error.description
                    } catch { return String(describing: error) }
                }
                await fulfillment(of: [entered], timeout: 1)
                if stopBeforeReturn { await server.stop() }
                await server.setLogWriter { line in _ = replacement.append(line) }
                if stopBeforeReturn { try await server.start(socketPath: path) }
                await gate.release()
                let result = await client.value
                XCTAssertEqual(result, stopBeforeReturn ? "unknown" : "true")
                try await waitUntil { await server.activeOperationCount == 0 }
                XCTAssertEqual(old.values.count, 2)
                XCTAssertTrue(replacement.values.isEmpty)
                let candidate = try XCTUnwrap(rows(old).first { $0["event"] as? String == "request_response_candidate" })
                XCTAssertEqual(candidate["outcome"] as? String, "result")
                XCTAssertEqual(candidate["selection"] as? String, stopBeforeReturn ? "not_selected" : "selected")
                XCTAssertEqual(candidate["peerReceipt"] as? String, "unconfirmed")
                await server.stop()
            } catch { await gate.release(); await server.stop(); throw error }
        }
    }
    func testCancelledBeforeExecutionLogsNoInventedPreparedResponse() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = Gate(), log = Lines(), calls = Lines()
        let entered = expectation(description: "operation admitted before execution")
        let server = DaemonServer.Instance(connectionObservation: .init(beforeOperation: {
            entered.fulfill()
            await gate.wait()
        }))
        do {
            await server.setLogWriter { line in _ = log.append(line) }
            await server.register("owned") { _ in _ = calls.append("handler"); return Data("true".utf8) }
            try await server.start(socketPath: DaemonClient.socketPath(dir: directory.path, name: "owned"))
            let client = Task {
                do {
                    _ = try await DaemonClient.sendRequest(name: "owned", method: "owned", params: Data("{}".utf8),
                        requestId: 7, timeout: 1, socketDir: directory.path)
                    return false
                } catch let error as DaemonClient.Error {
                    if case .requestOutcomeUnknown = error { return true }
                    return false
                } catch { return false }
            }
            await fulfillment(of: [entered], timeout: 1)
            await server.stop()
            await gate.release()
            let unknown = await client.value
            XCTAssertTrue(unknown)
            try await waitUntil { await server.activeOperationCount == 0 }
            XCTAssertTrue(calls.values.isEmpty)
            XCTAssertEqual(log.values.count, 1)
            let candidate = try XCTUnwrap(rows(log).first)
            XCTAssertEqual(candidate["event"] as? String, "request_response_candidate")
            XCTAssertEqual(candidate["outcome"] as? String, "cancelled")
            XCTAssertEqual(candidate["selection"] as? String, "not_offered")
            XCTAssertEqual(candidate["peerReceipt"] as? String, "unconfirmed")
        } catch { await gate.release(); await server.stop(); throw error }
    }

    func testErrorCandidatesMatchTheirEnvelopeAndDisabledLoggingStaysSilent() async throws {
        enum OwnedError: Error { case failed }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = DaemonServer.Instance(), log = Lines()
        do {
            await server.setLogWriter { line in _ = log.append(line) }
            await server.register("owned.result") { _ in Data("true".utf8) }
            await server.register("owned.error") { _ in throw OwnedError.failed }
            try await server.start(socketPath: DaemonClient.socketPath(dir: directory.path, name: "owned"))
            let cases: [(String, String, String, String?)] = [
                ("owned.result", "{}", "result", nil), ("absent", "{}", "method_not_found", "methodNotFound"),
                ("owned.error", "{}", "handler_error", "handlerError"), ("owned.result", "1", "parse_error", "parseError")]
            for (method, params, outcome, code) in cases {
                let previousCount = log.values.count
                do {
                    let data = try await DaemonClient.sendRequest(name: "owned", method: method,
                        params: Data(params.utf8), requestId: 7, timeout: 1, socketDir: directory.path)
                    XCTAssertNil(code)
                    XCTAssertEqual(data, Data("true".utf8))
                } catch let error as DaemonClient.Error {
                    guard case .remoteError(let actual, _) = error else { throw error }
                    XCTAssertEqual(actual, code)
                }
                try await waitUntil { await server.activeOperationCount == 0 }
                XCTAssertEqual(log.values.count, previousCount + 2)
                let candidate = try XCTUnwrap(rows(log).last)
                XCTAssertEqual(candidate["event"] as? String, "request_response_candidate")
                XCTAssertEqual(candidate["outcome"] as? String, outcome)
                XCTAssertEqual(candidate["selection"] as? String, "selected")
            }
            let candidates = try rows(log).filter { $0["event"] as? String == "request_response_candidate" }
            XCTAssertEqual(Set(candidates.compactMap { $0["requestToken"] as? String }).count, cases.count)
            await server.setLogWriter(nil)
            _ = try await DaemonClient.sendRequest(name: "owned", method: "owned.result", params: Data("{}".utf8),
                requestId: 7, timeout: 1, socketDir: directory.path)
            try await waitUntil { await server.activeOperationCount == 0 }
            XCTAssertEqual(log.values.count, cases.count * 2)
            await server.stop()
        } catch { await server.stop(); throw error }
    }
    func testCancelledOperationWaitsForActualHandoffBeforeLoggingIt() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = DaemonServer.Instance(), log = Lines(), gate = Gate()
        let stopped = expectation(description: "hook stopped instance but has not returned")
        do {
            await server.setLogWriter { line in _ = log.append(line) }
            await server.setShutdownHook {
                await server.stop()
                stopped.fulfill()
                await gate.wait()
            }
            try await server.start(socketPath: DaemonClient.socketPath(dir: directory.path, name: "owned"))
            let ack = try await DaemonClient.sendRequest(name: "owned", method: "daemon.shutdown",
                params: Data("{}".utf8), requestId: 7, timeout: 1, socketDir: directory.path)
            XCTAssertEqual(ack, Data("{}".utf8))
            await fulfillment(of: [stopped], timeout: 1)
            try await waitUntil { log.values.count >= 2 }
            XCTAssertEqual(log.values.count, 2, "task cancellation must not fabricate a final handoff")
            let pending = await server.activeOperationCount
            XCTAssertEqual(pending, 1, "the original operation is still awaiting its real handoff")
            await gate.release()
            try await waitUntil { await server.activeOperationCount == 0 }
            let handoff = try XCTUnwrap(rows(log).last)
            XCTAssertEqual(log.values.count, 3)
            XCTAssertEqual(handoff["event"] as? String, "request_shutdown_handoff")
            XCTAssertEqual(handoff["outcome"] as? String, "hook_returned")
            await server.stop()
        } catch { await gate.release(); await server.stop(); throw error }
    }
}
