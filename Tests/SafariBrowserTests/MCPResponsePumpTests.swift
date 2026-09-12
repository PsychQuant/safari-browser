import Foundation
import XCTest
@testable import SafariBrowser

final class MCPResponsePumpTests: XCTestCase, @unchecked Sendable {
    private enum SinkError: Error, LocalizedError, Equatable {
        case broken, closed
        var errorDescription: String? {
            switch self {
            case .broken: return "Fixture output stream failed."
            case .closed: return "Fixture output stream closed."
            }
        }
    }

    private actor Sink {
        let started: @Sendable (Int) -> Void
        let throwOnWrite: Bool
        var received: [Data] = []
        var continuation: CheckedContinuation<Void, Error>?
        var closed = false
        var closeCount = 0
        var activeWrites = 0
        var maximumActiveWrites = 0

        init(throwOnWrite: Bool = false, started: @escaping @Sendable (Int) -> Void = { _ in }) {
            self.throwOnWrite = throwOnWrite
            self.started = started
        }

        func write(_ frame: Data) async throws {
            guard !closed else { throw SinkError.closed }
            received.append(frame)
            started(received.count)
            if throwOnWrite { throw SinkError.broken }
            activeWrites += 1
            maximumActiveWrites = max(maximumActiveWrites, activeWrites)
            defer { activeWrites -= 1 }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func release() {
            let waiter = continuation
            continuation = nil
            waiter?.resume()
        }

        func close() {
            closeCount += 1
            closed = true
            let waiter = continuation
            continuation = nil
            waiter?.resume(throwing: SinkError.closed)
        }
    }

    func testAdmissionReturnsWhileOutputIsBlockedAndDrainIsSerial() async throws {
        let firstStarted = expectation(description: "first output started")
        let secondStarted = expectation(description: "second output started")
        let sink = Sink { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { secondStarted.fulfill() }
        }
        let pump = try MCPResponsePump(maximumQueuedFrames: 2, maximumQueuedBytes: 8,
                                       write: { try await sink.write($0) }, closeOutput: { await sink.close() })
        let admitted = expectation(description: "enqueue returns without waiting for output")
        let first = Task {
            try await pump.enqueue(Data("one".utf8))
            admitted.fulfill()
        }
        await fulfillment(of: [admitted, firstStarted], timeout: 1)
        try await pump.enqueue(Data("two".utf8))
        let beforeRelease = await sink.received
        XCTAssertEqual(beforeRelease, [Data("one".utf8)])
        await sink.release()
        await fulfillment(of: [secondStarted], timeout: 1)
        // The first completed frame releases both its frame slot and byte budget.
        try await pump.enqueue(Data("tri".utf8))
        let maximum = await sink.maximumActiveWrites
        XCTAssertEqual(maximum, 1)
        await pump.close()
        try await first.value
    }

    func testFrameCountLimitIncludesBlockedActiveWriteAndNotifiesFailure() async throws {
        let started = expectation(description: "output started")
        let failed = expectation(description: "reader notified of queue overflow")
        let sink = Sink { _ in started.fulfill() }
        let pump = try MCPResponsePump(maximumQueuedFrames: 1, write: { try await sink.write($0) },
                                       closeOutput: { await sink.close() }, onFailure: { failed.fulfill() })
        try await pump.enqueue(Data("one".utf8))
        await fulfillment(of: [started], timeout: 1)
        do { try await pump.enqueue(Data("two".utf8)); XCTFail("active write did not count toward limit") }
        catch { XCTAssertEqual(error as? MCPResponsePumpError, .queueFull) }
        await fulfillment(of: [failed], timeout: 1)
        let failure = await pump.failureDescription()
        XCTAssertEqual(failure, MCPResponsePumpError.queueFull.localizedDescription)
        await pump.close()
        let received = await sink.received
        XCTAssertEqual(received, [Data("one".utf8)])
    }

    func testByteLimitIncludesDelimiterAndActiveWrite() async throws {
        let started = expectation(description: "output started")
        let sink = Sink { _ in started.fulfill() }
        let pump = try MCPResponsePump(maximumQueuedBytes: 6, write: { try await sink.write($0) },
                                       closeOutput: { await sink.close() })
        try await pump.enqueue(Data("12345".utf8))
        await fulfillment(of: [started], timeout: 1)
        do { try await pump.enqueue(Data()); XCTFail("delimiter was omitted from byte budget") }
        catch { XCTAssertEqual(error as? MCPResponsePumpError, .queueFull) }
        await pump.close()
    }

    func testCloseUnblocksWriteWithoutClientReadAndIsIdempotent() async throws {
        let started = expectation(description: "output started")
        let closed = expectation(description: "close completed without client read")
        let sink = Sink { _ in started.fulfill() }
        let pump = try MCPResponsePump(write: { try await sink.write($0) }, closeOutput: { await sink.close() })
        try await pump.enqueue(Data("blocked".utf8))
        await fulfillment(of: [started], timeout: 1)
        let closing = Task {
            async let first: Void = pump.close()
            async let second: Void = pump.close()
            _ = await (first, second)
            closed.fulfill()
        }
        await fulfillment(of: [closed], timeout: 1)
        await closing.value
        await pump.close()
        let count = await sink.closeCount
        let failure = await pump.failureDescription()
        XCTAssertEqual(count, 1)
        XCTAssertNil(failure)
        do { try await pump.enqueue(Data("late".utf8)); XCTFail("closed pump admitted output") }
        catch { XCTAssertEqual(error as? MCPResponsePumpError, .closed) }
    }

    func testWriteFailureNotifiesReaderAndRemainsObservable() async throws {
        let failed = expectation(description: "reader notified of output failure")
        let sink = Sink(throwOnWrite: true)
        let pump = try MCPResponsePump(write: { try await sink.write($0) }, closeOutput: { await sink.close() },
                                       onFailure: { failed.fulfill() })
        try await pump.enqueue(Data("output".utf8))
        await fulfillment(of: [failed], timeout: 1)
        let failure = await pump.failureDescription()
        XCTAssertEqual(failure, SinkError.broken.localizedDescription)
        do { try await pump.enqueue(Data("late".utf8)); XCTFail("failed pump admitted output") }
        catch { XCTAssertEqual(error as? SinkError, .broken) }
        await pump.close()
    }

    func testInvalidLimitsFailBeforeOutput() throws {
        for (frames, bytes) in [(0, 16), (-1, 16), (1, 0), (1, -1)] {
            XCTAssertThrowsError(try MCPResponsePump(maximumQueuedFrames: frames, maximumQueuedBytes: bytes,
                                                     write: { _ in }, closeOutput: {}))
        }
    }
}
