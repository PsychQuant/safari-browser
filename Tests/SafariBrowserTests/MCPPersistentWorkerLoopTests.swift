import Foundation
import XCTest
@testable import SafariBrowser

final class MCPPersistentWorkerLoopTests: XCTestCase, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Data]
        private var written: [MCPWorkerWire.ServerMessage] = []
        private var executions = 0
        init(_ frames: [Data]) { pending = frames }
        func next() -> Data? { lock.withLock { pending.isEmpty ? nil : pending.removeFirst() } }
        func record(_ frame: MCPWorkerWire.ServerMessage) { lock.withLock { written.append(frame) } }
        func executed() { lock.withLock { executions += 1 } }
        var count: Int { lock.withLock { executions } }
        var frames: [MCPWorkerWire.ServerMessage] { lock.withLock { written } }
        var remaining: Int { lock.withLock { pending.count } }
    }
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private func queue() throws -> State {
        try State([first, second].map { try MCPWorkerWire.encodeClient(.request(id: $0, arguments: ["wait", "0"], input: Data())) })
    }

    func testActualUnfinishedAXReadCompletesOnceAndRefusesTheNextRequest() async throws {
        let state = try queue(), worker = BoundedAXWorker()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        try await MCPPersistentWorkerLoop.run(image: "fixture", workerPID: 20, supervisorPID: 19,
            next: { state.next() }, send: { state.record($0) }, execute: { _, _, output in
                state.executed()
                _ = worker.run(budget: 0.03, fallback: false) { _ in
                    entered.signal()
                    _ = release.wait(timeout: .now() + 3)
                    return true
                }
                try output(.stdout, Data("finished CLI".utf8))
                return .init(exitCode: 0, streamsComplete: true)
            }, validateImage: {}, onlyOwnedProcesses: { true }, axIsQuiescent: { worker.isQuiescent })
        XCTAssertEqual(entered.wait(timeout: .now() + 0.5), .success)
        XCTAssertFalse(worker.isQuiescent)
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(state.remaining, 1)
        XCTAssertEqual(state.frames.last, .complete(id: first, exitCode: 0, reusable: false))
        XCTAssertTrue(state.frames.contains(.output(id: first, stream: .stdout, bytes: Data("finished CLI".utf8))))
    }

    func testUnsealedStreamsDescendantsAndExecutionFailureRetireBeforeNextRequest() async throws {
        struct Failure: Error {}
        for fault in ["streams", "descendants", "execution"] {
            let state = try queue()
            try await MCPPersistentWorkerLoop.run(image: "fixture", workerPID: 20, supervisorPID: 19,
                next: { state.next() }, send: { state.record($0) }, execute: { _, _, output in
                    state.executed()
                    try output(.stderr, Data("prefix".utf8))
                    if fault == "execution" { throw Failure() }
                    return .init(exitCode: 17, streamsComplete: fault != "streams")
                }, validateImage: {}, onlyOwnedProcesses: { fault != "descendants" }, axIsQuiescent: { true })
            XCTAssertEqual(state.count, 1); XCTAssertEqual(state.remaining, 1)
            XCTAssertEqual(state.frames.last, .retire(id: first, reason: fault == "descendants" ? .descendants : .io,
                exitCode: fault == "execution" ? nil : 17))
        }
    }

    func testFailedImageGuardNeverExecutesAndRequiresRestart() async throws {
        struct Failure: Error {}
        let state = try queue()
        try await MCPPersistentWorkerLoop.run(image: "fixture", workerPID: 20, supervisorPID: 19,
            next: { state.next() }, send: { state.record($0) }, execute: { _, _, _ in
                state.executed(); return .init(exitCode: 0, streamsComplete: true)
            }, validateImage: { throw Failure() }, onlyOwnedProcesses: { true }, axIsQuiescent: { true })
        XCTAssertEqual(state.count, 0); XCTAssertEqual(state.remaining, 1)
        XCTAssertEqual(state.frames.last, .complete(id: first, exitCode: 64, reusable: false))
        let errors = state.frames.compactMap { frame -> Data? in
            if case .output(_, .stderr, let bytes) = frame { return bytes }; return nil
        }.reduce(Data(), +)
        XCTAssertTrue(String(decoding: errors, as: UTF8.self).contains("executable changed"))
        XCTAssertTrue(String(decoding: errors, as: UTF8.self).contains("not executed"))
    }

    func testShutdownAndMalformedFramesDoNotExecuteAnything() async throws {
        for malformed in [false, true] {
            let state = State([malformed ? Data("{}".utf8) : try MCPWorkerWire.encodeClient(.shutdown)])
            do {
                try await MCPPersistentWorkerLoop.run(image: "fixture", workerPID: 20, supervisorPID: 19,
                    next: { state.next() }, send: { state.record($0) }, execute: { _, _, _ in
                        state.executed(); return .init(exitCode: 0, streamsComplete: true)
                    }, validateImage: {}, onlyOwnedProcesses: { true }, axIsQuiescent: { true })
                XCTAssertFalse(malformed)
            } catch { XCTAssertTrue(malformed) }
            XCTAssertEqual(state.count, 0)
            XCTAssertEqual(state.frames, [.hello(image: "fixture", workerPID: 20, supervisorPID: 19)])
        }
    }
}
