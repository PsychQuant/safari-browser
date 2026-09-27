import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonConnectionTests: XCTestCase {
    func testNativeReadinessWakesForInputAndClosesItsMonitor() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        let registered = expectation(description: "native readiness registered")
        let monitorClosed = expectation(description: "native monitor descriptor closed")
        let finished = expectation(description: "read resumes on input")
        let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(
            readinessRegistered: { registered.fulfill() }, readinessClosed: { monitorClosed.fulfill() }))
        defer { connection.revoke() }
        let reader = Task {
            do { let value = try await connection.readChunk(); XCTAssertEqual(value, Data("x".utf8)) }
            catch { XCTFail("native readiness failed: \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [registered], timeout: 1)
        var byte: UInt8 = 120
        XCTAssertEqual(Darwin.write(pair.peer, &byte, 1), 1)
        await fulfillment(of: [finished, monitorClosed], timeout: 1)
        reader.cancel()
    }

    func testNativeReadinessRevokeClosesMonitorWithoutPeerInput() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        let registered = expectation(description: "native readiness registered")
        let monitorClosed = expectation(description: "revoked monitor closed")
        let finished = expectation(description: "revoked read completes")
        let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(
            readinessRegistered: { registered.fulfill() }, readinessClosed: { monitorClosed.fulfill() }))
        let reader = Task {
            do { _ = try await connection.readChunk(); XCTFail("revoked read cannot succeed") }
            catch { XCTAssertEqual(error as? DaemonConnection.Failure, .revoked) }
            finished.fulfill()
        }
        await fulfillment(of: [registered], timeout: 1)
        connection.revoke()
        await fulfillment(of: [finished, monitorClosed], timeout: 1)
        reader.cancel()
    }

    func testNativeReadinessWakesForPeerEOF() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        let registered = expectation(description: "read readiness registered")
        let closed = expectation(description: "EOF monitor closed")
        let finished = expectation(description: "EOF returned")
        let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(
            readinessRegistered: { registered.fulfill() }, readinessClosed: { closed.fulfill() }))
        defer { connection.revoke() }
        let reader = Task {
            do { let value = try await connection.readChunk(); XCTAssertNil(value) }
            catch { XCTFail("EOF read failed: \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [registered], timeout: 1)
        XCTAssertEqual(shutdown(pair.peer, SHUT_WR), 0)
        await fulfillment(of: [finished, closed], timeout: 1)
        reader.cancel()
    }

    func testNativeWaitCancellationRetiresMonitor() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        let registered = expectation(description: "read readiness registered")
        let closed = expectation(description: "cancelled monitor closed")
        let finished = expectation(description: "cancelled wait returned")
        let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(
            readinessRegistered: { registered.fulfill() }, readinessClosed: { closed.fulfill() }))
        defer { connection.revoke() }
        let reader = Task {
            do { _ = try await connection.readChunk(); XCTFail("cancelled wait cannot succeed") }
            catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [registered], timeout: 1)
        reader.cancel()
        await fulfillment(of: [finished, closed], timeout: 1)
        XCTAssertFalse(connection.isRevoked, "cancelling one wait does not take ownership from its caller")
    }

    func testNativeWriteDeadlineRetiresBlockedMonitor() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        var size: Int32 = 4096
        XCTAssertEqual(setsockopt(pair.adopted, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)), 0)
        let registrations = Counter(), closures = Counter()
        let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(
            readinessRegistered: { registrations.increment() }, readinessClosed: { closures.increment() }))
        defer { connection.revoke() }
        let begin = ContinuousClock.now
        do {
            try await connection.write(Data(repeating: 97, count: 1024 * 1024), deadline: begin.advanced(by: .milliseconds(30)))
            XCTFail("non-reading peer must reach the absolute deadline")
        } catch { XCTAssertEqual(error as? DaemonConnection.Failure, .deadlineExceeded) }
        XCTAssertLessThan(begin.duration(to: .now), .seconds(1))
        for _ in 0..<100 {
            if closures.count == registrations.count { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(registrations.count, 0)
        XCTAssertEqual(closures.count, registrations.count)
    }

    func testNativeReadinessDescriptorChurnDoesNotLeak() async throws {
        let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        let finished = expectation(description: "all waits finished")
        let closed = expectation(description: "all monitor descriptors closed")
        finished.expectedFulfillmentCount = 50
        closed.expectedFulfillmentCount = 50
        var readers: [Task<Void, Never>] = []
        for _ in 0..<50 {
            let pair = try makePair()
            let registered = expectation(description: "owned monitor registered")
            let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(
                readinessRegistered: { registered.fulfill() }, readinessClosed: { closed.fulfill() }))
            readers.append(Task {
                do { _ = try await connection.readChunk(); XCTFail("revoked wait cannot succeed") }
                catch { XCTAssertEqual(error as? DaemonConnection.Failure, .revoked) }
                finished.fulfill()
            })
            await fulfillment(of: [registered], timeout: 1)
            connection.revoke()
            close(pair.peer)
        }
        await fulfillment(of: [finished, closed], timeout: 2)
        readers.forEach { $0.cancel() }
        let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        // Permit lazy runtime bookkeeping, but not one leaked fd per monitor.
        XCTAssertLessThanOrEqual(after, before + 2)
    }
    private struct Pair { let adopted: Int32; let peer: Int32 }
    private func makePair() throws -> Pair {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw NSError(domain: "OwnedSocketPair", code: Int(errno))
        }
        var enabled: Int32 = 1
        XCTAssertEqual(setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)), 0)
        XCTAssertEqual(fcntl(fds[1], F_SETFL, O_NONBLOCK), 0)
        return Pair(adopted: fds[0], peer: fds[1])
    }

    func testAdoptionConfiguresNonblockingCloseOnExecAndNoSIGPIPE() throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        let connection = try DaemonConnection(adopting: pair.adopted)
        defer { connection.revoke() }
        XCTAssertNotEqual(fcntl(pair.adopted, F_GETFL) & O_NONBLOCK, 0)
        XCTAssertNotEqual(fcntl(pair.adopted, F_GETFD) & FD_CLOEXEC, 0)
        var enabled: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(pair.adopted, SOL_SOCKET, SO_NOSIGPIPE, &enabled, &size), 0)
        XCTAssertEqual(enabled, 1)
    }

    func testReadChunkPreservesBytesAndReportsOnlyPeerEOF() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        let connection = try DaemonConnection(adopting: pair.adopted)
        defer { connection.revoke() }
        let bytes = Data("abcd".utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(pair.peer, $0.baseAddress!, $0.count) }, 4)
        XCTAssertEqual(shutdown(pair.peer, SHUT_WR), 0)
        let first = try await connection.readChunk(maxBytes: 2)
        let second = try await connection.readChunk(maxBytes: 2)
        let eof = try await connection.readChunk()
        XCTAssertEqual(first, Data("ab".utf8))
        XCTAssertEqual(second, Data("cd".utf8))
        XCTAssertNil(eof)
    }

    func testWriteTransmitsTheSuppliedBytes() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        let connection = try DaemonConnection(adopting: pair.adopted)
        defer { connection.revoke() }
        try await connection.write(Data("fixture response\n".utf8))
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(pair.peer, &buffer, buffer.count)
        XCTAssertEqual(count, 17)
        if count > 0 { XCTAssertEqual(Data(buffer.prefix(count)), Data("fixture response\n".utf8)) }
    }

    private actor Gate {
        private var open = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if open { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { open = true; continuation?.resume(); continuation = nil }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        @discardableResult func increment() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { value } }
        func advance(_ duration: Duration) { lock.withLock { value = value.advanced(by: duration) } }
    }

    func testRevocationEndsWaitingReadWithoutTurningCancellationIntoEOF() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        let waiting = expectation(description: "read waiting without data")
        let finished = expectation(description: "read finished after revoke")
        let gate = Gate()
        let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(wait: { _ in
            waiting.fulfill(); await gate.wait()
        }))
        let read = Task {
            do { _ = try await connection.readChunk(); XCTFail("revocation must not be a successful EOF") }
            catch { XCTAssertEqual(error as? DaemonConnection.Failure, .revoked) }
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 1)
        connection.revoke()
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        await read.value
        XCTAssertTrue(connection.isRevoked)
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(pair.peer, &byte, 1), 0)
    }

    func testTaskCancellationInterruptsReadWaitWithoutPeerInput() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        let waiting = expectation(description: "read entered async sleep")
        let finished = expectation(description: "cancelled read completed")
        let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(wait: { _ in
            waiting.fulfill(); try await Task.sleep(for: .seconds(30))
        }))
        defer { connection.revoke() }
        let read = Task {
            do { _ = try await connection.readChunk(); XCTFail("task cancellation must throw") }
            catch is CancellationError {}
            catch { XCTFail("unexpected error: \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 1)
        read.cancel()
        await fulfillment(of: [finished], timeout: 2)
        await read.value
    }

    func testSlowPeerWriteCanBeRevokedOutsideTheWaitingLock() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        var size: Int32 = 4096
        XCTAssertEqual(setsockopt(pair.adopted, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)), 0)
        let waiting = expectation(description: "write backpressure")
        let finished = expectation(description: "revoked writer completed")
        let gate = Gate()
        let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(wait: { _ in
            waiting.fulfill(); await gate.wait()
        }))
        let write = Task {
            do { try await connection.write(Data(repeating: 0x61, count: 1024 * 1024)); XCTFail("slow peer should require retry") }
            catch { XCTAssertEqual(error as? DaemonConnection.Failure, .revoked) }
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 1)
        connection.revoke()
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        await write.value
    }

    func testTaskCancellationInterruptsWriteBackpressure() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        var size: Int32 = 4096
        XCTAssertEqual(setsockopt(pair.adopted, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)), 0)
        let waiting = expectation(description: "write entered async sleep")
        let finished = expectation(description: "cancelled writer completed")
        let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(wait: { _ in
            waiting.fulfill(); try await Task.sleep(for: .seconds(30))
        }))
        defer { connection.revoke() }
        let write = Task {
            do { try await connection.write(Data(repeating: 0x61, count: 1024 * 1024)); XCTFail("task cancellation must throw") }
            catch is CancellationError {}
            catch { XCTFail("unexpected error: \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 1)
        write.cancel()
        await fulfillment(of: [finished], timeout: 2)
        await write.value
    }

    func testPartialWritesDeliverEveryByteToSlowReader() async throws {
        let pair = try makePair()
        var size: Int32 = 4096
        XCTAssertEqual(setsockopt(pair.adopted, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)), 0)
        let sender = try DaemonConnection(adopting: pair.adopted)
        let receiver = try DaemonConnection(adopting: pair.peer)
        defer { sender.revoke(); receiver.revoke() }
        let payload = Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let reader = Task {
            var received = Data()
            while received.count < payload.count {
                guard let chunk = try await receiver.readChunk(maxBytes: 2048) else { break }
                received.append(chunk)
                try await Task.sleep(for: .milliseconds(1))
            }
            return received
        }
        try await sender.write(payload, deadline: .now.advanced(by: .seconds(2)))
        let received = try await reader.value
        XCTAssertEqual(received, payload)
    }

    func testInterruptedReadAndWriteYieldThenPreserveBytes() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        let readCalls = Counter(), writeCalls = Counter(), yields = Counter()
        let environment = DaemonConnection.Environment(read: { fd, buffer, size in
            if readCalls.increment() <= 3 { return .init(count: -1, errno: EINTR) }
            let count = Darwin.read(fd, buffer, size)
            return .init(count: count, errno: count < 0 ? errno : 0)
        }, write: { fd, buffer, size in
            if writeCalls.increment() <= 3 { return .init(count: -1, errno: EINTR) }
            let count = Darwin.write(fd, buffer, size)
            return .init(count: count, errno: count < 0 ? errno : 0)
        }, yield: { yields.increment(); await Task.yield() })
        let connection = try DaemonConnection(adopting: pair.adopted, environment: environment)
        defer { connection.revoke() }
        var byte: UInt8 = 0x7A
        XCTAssertEqual(Darwin.write(pair.peer, &byte, 1), 1)
        let received = try await connection.readChunk()
        XCTAssertEqual(received, Data([0x7A]))
        try await connection.write(Data([0x42]))
        XCTAssertEqual(Darwin.read(pair.peer, &byte, 1), 1)
        XCTAssertEqual(byte, 0x42)
        XCTAssertEqual(yields.count, 6, "interrupted syscalls must yield instead of spinning")
    }

    func testProgressingWritesYieldAndKeepOneAbsoluteDeadline() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        let clock = Clock(), yields = Counter()
        let environment = DaemonConnection.Environment(write: { fd, buffer, size in
            let count = Darwin.write(fd, buffer, min(size, 1))
            clock.advance(.milliseconds(1))
            return .init(count: count, errno: count < 0 ? errno : 0)
        }, now: { clock.now }, yield: { yields.increment(); await Task.yield() })
        let connection = try DaemonConnection(adopting: pair.adopted, environment: environment)
        defer { connection.revoke() }
        let deadline = clock.now.advanced(by: .milliseconds(40))
        do {
            try await connection.write(Data(repeating: 0x61, count: 100), deadline: deadline)
            XCTFail("partial progress must not reset the total write budget")
        } catch { XCTAssertEqual(error as? DaemonConnection.Failure, .deadlineExceeded) }
        var buffer = [UInt8](repeating: 0, count: 100)
        XCTAssertEqual(Darwin.read(pair.peer, &buffer, buffer.count), 40)
        XCTAssertGreaterThan(yields.count, 0, "a long progressing loop must still allow other tasks to run")
    }

    func testWouldBlockWriteHonorsAbsoluteDeadline() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        var size: Int32 = 4096
        XCTAssertEqual(setsockopt(pair.adopted, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)), 0)
        let clock = Clock(), waits = Counter()
        let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(wait: { delay in
            waits.increment(); clock.advance(delay)
        }, now: { clock.now }))
        defer { connection.revoke() }
        do {
            try await connection.write(Data(repeating: 0x61, count: 1024 * 1024), deadline: clock.now.advanced(by: .milliseconds(12)))
            XCTFail("a peer that never reads cannot extend the write budget")
        } catch { XCTAssertEqual(error as? DaemonConnection.Failure, .deadlineExceeded) }
        XCTAssertEqual(waits.count, 3)
    }

    func testFailedAdoptionClosesOwnedDescriptor() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[1]) }
        do {
            let unexpected = try DaemonConnection(adopting: fds[0])
            unexpected.revoke()
            XCTFail("a pipe cannot satisfy socket setup")
        } catch { XCTAssertEqual(error as? DaemonConnection.Failure, .system(operation: .configure, errno: ENOTSOCK)) }
        XCTAssertEqual(fcntl(fds[0], F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    /// F_DUPFD only acquires an unused number; unlike dup2 it cannot close an
    /// unrelated descriptor if another task happened to acquire the old slot.
    private func reuse(_ retired: Int32, from source: Int32) throws -> Int32 {
        let replacement = fcntl(source, F_DUPFD, retired)
        guard replacement == retired else {
            if replacement >= 0 { close(replacement) }
            throw XCTSkip("another task acquired the retired descriptor before the owned fixture")
        }
        XCTAssertEqual(fcntl(replacement, F_SETFL, O_NONBLOCK), 0)
        return replacement
    }

    func testRevokedReadCannotConsumeDataFromReusedDescriptor() async throws {
        let pair = try makePair(), replacement = try makePair()
        defer { close(pair.peer); close(replacement.adopted); close(replacement.peer) }
        let waiting = expectation(description: "old reader suspended")
        let finished = expectation(description: "old reader rejects reused slot")
        let gate = Gate()
        let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(wait: { _ in
            waiting.fulfill(); await gate.wait()
        }))
        let read = Task {
            do { _ = try await connection.readChunk(); XCTFail("old reader cannot observe replacement data") }
            catch { XCTAssertEqual(error as? DaemonConnection.Failure, .revoked) }
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 1)
        connection.revoke()
        let reused: Int32
        do { reused = try reuse(pair.adopted, from: replacement.adopted) }
        catch { await gate.release(); await read.value; throw error }
        defer { close(reused) }
        var byte: UInt8 = 0x5A
        XCTAssertEqual(Darwin.write(replacement.peer, &byte, 1), 1)
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        await read.value
        XCTAssertEqual(Darwin.read(reused, &byte, 1), 1)
        XCTAssertEqual(byte, 0x5A)
        connection.revoke()
        XCTAssertGreaterThanOrEqual(fcntl(reused, F_GETFD), 0)
    }

    func testRevokedWriteCannotTouchReusedDescriptor() async throws {
        let pair = try makePair(), replacement = try makePair()
        defer { close(pair.peer); close(replacement.adopted); close(replacement.peer) }
        var size: Int32 = 4096
        XCTAssertEqual(setsockopt(pair.adopted, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)), 0)
        let waiting = expectation(description: "old writer suspended")
        let finished = expectation(description: "old writer rejects reused slot")
        let gate = Gate()
        let connection = try DaemonConnection(adopting: pair.adopted, environment: .init(wait: { _ in
            waiting.fulfill(); await gate.wait()
        }))
        let write = Task {
            do { try await connection.write(Data(repeating: 0x61, count: 1024 * 1024)); XCTFail("old writer cannot write to replacement") }
            catch { XCTAssertEqual(error as? DaemonConnection.Failure, .revoked) }
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 1)
        connection.revoke()
        let reused: Int32
        do { reused = try reuse(pair.adopted, from: replacement.adopted) }
        catch { await gate.release(); await write.value; throw error }
        defer { close(reused) }
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        await write.value
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(replacement.peer, &byte, 1), -1)
        XCTAssertEqual(errno, EAGAIN, "old data must not arrive at the new peer")
        var marker: UInt8 = 0x42
        XCTAssertEqual(Darwin.write(reused, &marker, 1), 1)
        XCTAssertEqual(Darwin.read(replacement.peer, &byte, 1), 1)
        XCTAssertEqual(byte, marker)
    }

    func testConcurrentRepeatedRevocationDoesNotCloseReplacement() async throws {
        let pair = try makePair(), replacement = try makePair()
        defer { close(pair.peer); close(replacement.adopted); close(replacement.peer) }
        let owner = try DaemonConnection(adopting: pair.adopted)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { owner.revoke() } }
        }
        XCTAssertTrue(owner.isRevoked)
        let reused = try reuse(pair.adopted, from: replacement.adopted)
        defer { close(reused) }
        owner.revoke()
        XCTAssertGreaterThanOrEqual(fcntl(reused, F_GETFD), 0)
    }

    func testDeinitAfterRevocationDoesNotCloseReplacement() throws {
        let pair = try makePair(), replacement = try makePair()
        defer { close(pair.peer); close(replacement.adopted); close(replacement.peer) }
        var connection: DaemonConnection? = try DaemonConnection(adopting: pair.adopted)
        let isReleased = { [weak connection] in connection == nil }
        connection?.revoke()
        let reused = try reuse(pair.adopted, from: replacement.adopted)
        defer { close(reused) }
        connection = nil
        XCTAssertTrue(isReleased())
        XCTAssertGreaterThanOrEqual(fcntl(reused, F_GETFD), 0)
        var marker: UInt8 = 0x55, received: UInt8 = 0
        XCTAssertEqual(Darwin.write(reused, &marker, 1), 1)
        XCTAssertEqual(Darwin.read(replacement.peer, &received, 1), 1)
        XCTAssertEqual(received, marker)
    }

    func testPeerClosureThrowsSystemWriteErrorWithoutSIGPIPE() async throws {
        let pair = try makePair()
        let connection = try DaemonConnection(adopting: pair.adopted)
        defer { connection.revoke() }
        close(pair.peer)
        do { try await connection.write(Data([1])); XCTFail("a closed peer must fail the write") }
        catch { XCTAssertEqual(error as? DaemonConnection.Failure, .system(operation: .write, errno: EPIPE)) }
    }

    func testInvalidReadSizeIsNotReportedAsPeerEOF() async throws {
        let pair = try makePair()
        defer { close(pair.peer) }
        let connection = try DaemonConnection(adopting: pair.adopted)
        defer { connection.revoke() }
        do { _ = try await connection.readChunk(maxBytes: 0); XCTFail("zero-sized read is not peer EOF") }
        catch { XCTAssertEqual(error as? DaemonConnection.Failure, .system(operation: .read, errno: EINVAL)) }
    }

}
