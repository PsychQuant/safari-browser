import Darwin
import Foundation
import Dispatch

/// Owns one accepted socket. The lock serializes state checks and individual
/// nonblocking syscalls; all readiness waits and yields happen outside it.
final class DaemonConnection: @unchecked Sendable {
    enum Operation: String, Sendable { case configure, read, write }
    enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case revoked
        case system(operation: Operation, errno: Int32)
        case deadlineExceeded
        var description: String {
            switch self {
            case .revoked: return "connection revoked"
            case let .system(operation, code): return "connection \(operation.rawValue) failed: errno=\(code)"
            case .deadlineExceeded: return "connection write deadline exceeded"
            }
        }
    }
    struct IOResult: Sendable { let count: Int; let errno: Int32 }
    /// Synchronous syscall seams run under the descriptor lock. They must
    /// preserve nonblocking behavior and must not retain either fd or buffer.
    struct Environment: Sendable {
        var read: @Sendable (Int32, UnsafeMutableRawPointer, Int) -> IOResult = { fd, buffer, count in
            let result = Darwin.read(fd, buffer, count)
            return IOResult(count: result, errno: result < 0 ? errno : 0)
        }
        var write: @Sendable (Int32, UnsafeRawPointer, Int) -> IOResult = { fd, buffer, count in
            let result = Darwin.write(fd, buffer, count)
            return IOResult(count: result, errno: result < 0 ? errno : 0)
        }
        /// Nil uses native readiness. A custom wait is only a deterministic
        /// syscall/clock fixture adapter and preserves the existing retry seam.
        var wait: (@Sendable (Duration) async throws -> Void)? = nil
        var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
        var yield: @Sendable () async -> Void = { await Task.yield() }
        var readinessRegistered: @Sendable () -> Void = {}
        var readinessClosed: @Sendable () -> Void = {}
    }
    let id = UUID()
    private let lock = NSLock()
    // The descriptor never leaves the lock in production. Nil is permanent:
    // an old retry or deinit cannot act on a subsequently reused fd number.
    private var fd: Int32?
    private let environment: Environment
    private static let chunkBytes = 8192
    private static let retryDelay: Duration = .milliseconds(5)
    private static let readinessQueue = DispatchQueue(label: "safari-browser.daemon.readiness", qos: .userInitiated)
    private enum Wakeup: Sendable { case ready, revoked, timedOut }
    private final class ReadinessRegistration: @unchecked Sendable {
        let source: any DispatchSourceProtocol
        let result = DaemonRequestCompletion<Wakeup>()
        init(source: any DispatchSourceProtocol) { self.source = source }
        func resolve(_ value: Wakeup) {
            source.cancel()
            result.complete(value)
        }
        deinit { source.cancel() }
    }
    private var readiness: [UUID: ReadinessRegistration] = [:]

    /// The GCD source owns a private duplicate until its cancellation handler.
    /// Original I/O never uses that duplicate, so stop can revoke/close the
    /// original immediately without racing a later source handler or fd reuse.
    private func waitForReadiness(_ operation: Operation, deadline: ContinuousClock.Instant? = nil) async throws {
        if let wait = environment.wait {
            var delay = Self.retryDelay
            if let deadline {
                let remaining = environment.now().duration(to: deadline)
                guard remaining > .zero else { throw Failure.deadlineExceeded }
                delay = min(delay, remaining)
            }
            try await wait(delay)
            return
        }
        try Task.checkCancellation()
        let id = UUID()
        let registration = try lock.withLock {
            guard let fd else { throw Failure.revoked }
            if let deadline, environment.now() >= deadline { throw Failure.deadlineExceeded }
            let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw Failure.system(operation: operation, errno: errno) }
            let source: any DispatchSourceProtocol
            if operation == .read {
                source = DispatchSource.makeReadSource(fileDescriptor: duplicate, queue: Self.readinessQueue)
            } else {
                source = DispatchSource.makeWriteSource(fileDescriptor: duplicate, queue: Self.readinessQueue)
            }
            let value = ReadinessRegistration(source: source)
            let closed = environment.readinessClosed
            source.setEventHandler { [weak value] in value?.resolve(.ready) }
            source.setCancelHandler {
                _ = Darwin.close(duplicate)
                closed()
            }
            readiness[id] = value
            source.activate()
            return value
        }
        defer {
            registration.source.cancel()
            _ = lock.withLock { readiness.removeValue(forKey: id) }
        }
        environment.readinessRegistered()
        let timeout: Task<Void, Never>?
        if let deadline {
            timeout = Task.detached {
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                guard !Task.isCancelled else { return }
                registration.resolve(.timedOut)
            }
        } else { timeout = nil }
        defer { timeout?.cancel() }
        guard let result = await registration.result.wait() else { throw CancellationError() }
        switch result {
        case .ready: return
        case .revoked: throw Failure.revoked
        case .timedOut: throw Failure.deadlineExceeded
        }
    }

    /// Ownership transfers on entry, including when socket setup fails.
    init(adopting fd: Int32, environment: Environment = .init()) throws {
        self.fd = fd >= 0 ? fd : nil
        self.environment = environment
        do {
            try lock.withLock {
                guard fd >= 0 else { throw Failure.system(operation: .configure, errno: EBADF) }
                let status = fcntl(fd, F_GETFL)
                guard status >= 0, fcntl(fd, F_SETFL, status | O_NONBLOCK) == 0 else {
                    throw Failure.system(operation: .configure, errno: errno)
                }
                let descriptorFlags = fcntl(fd, F_GETFD)
                guard descriptorFlags >= 0, fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
                    throw Failure.system(operation: .configure, errno: errno)
                }
                var enabled: Int32 = 1
                guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                                 socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw Failure.system(operation: .configure, errno: errno)
                }
            }
        } catch {
            revoke()
            throw error
        }
    }

    var isRevoked: Bool { lock.withLock { fd == nil } }

    /// Each syscall is nonblocking and shares this lock with revocation.
    /// No pending read/write holds a lease on a descriptor after suspension.
    func revoke() {
        let waiting = lock.withLock {
            if let descriptor = fd {
                fd = nil
                _ = shutdown(descriptor, SHUT_RDWR)
                _ = close(descriptor)
            }
            let values = Array(readiness.values)
            readiness.removeAll()
            return values
        }
        for registration in waiting { registration.resolve(.revoked) }
    }

    deinit { revoke() }

    /// Nil means the peer's real EOF. Revocation and task cancellation throw.
    func readChunk(maxBytes: Int = 8192) async throws -> Data? {
        guard maxBytes > 0 else { throw Failure.system(operation: .read, errno: EINVAL) }
        var buffer = [UInt8](repeating: 0, count: min(maxBytes, Self.chunkBytes))
        while true {
            try Task.checkCancellation()
            let result = try lock.withLock {
                guard let fd else { throw Failure.revoked }
                return buffer.withUnsafeMutableBytes {
                    environment.read(fd, $0.baseAddress!, $0.count)
                }
            }
            if result.count > 0 { return Data(buffer.prefix(result.count)) }
            if result.count == 0 { return nil }
            switch result.errno {
            case EINTR:
                await environment.yield()
            case EAGAIN, EWOULDBLOCK:
                try await waitForReadiness(.read)
            default:
                throw Failure.system(operation: .read, errno: result.errno)
            }
        }
    }

    /// The optional deadline is absolute across all partial writes and waits.
    /// Ordinary RPC writes supply no deadline; their owner controls lifetime.
    func write(_ bytes: Data, deadline: ContinuousClock.Instant? = nil) async throws {
        var offset = 0
        var progressingWrites = 0
        repeat {
            try Task.checkCancellation()
            let result = try lock.withLock {
                guard let fd else { throw Failure.revoked }
                if let deadline, environment.now() >= deadline { throw Failure.deadlineExceeded }
                guard offset < bytes.count else { return IOResult(count: 0, errno: 0) }
                return bytes.withUnsafeBytes {
                    environment.write(fd, $0.baseAddress!.advanced(by: offset),
                                      min(Self.chunkBytes, $0.count - offset))
                }
            }
            // Even an empty write checks cancellation, revocation and deadline.
            if offset == bytes.count { return }
            if result.count > 0 {
                offset += result.count
                progressingWrites += 1
                if progressingWrites == 16 {
                    progressingWrites = 0
                    await environment.yield()
                }
                continue
            }
            if result.count == 0 { throw Failure.system(operation: .write, errno: EIO) }
            switch result.errno {
            case EINTR:
                await environment.yield()
            case EAGAIN, EWOULDBLOCK:
                try await waitForReadiness(.write, deadline: deadline)
            default:
                throw Failure.system(operation: .write, errno: result.errno)
            }
        } while offset < bytes.count
    }
}
