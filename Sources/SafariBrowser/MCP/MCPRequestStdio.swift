import Foundation
import Darwin

enum MCPRequestStdioError: Error { case unavailable, inputLimit, setup }

/// Owns process-global stdio for the lifetime of one persistent worker. Never
/// instantiate this in the MCP host or a shared application/test process.
final class MCPRequestStdio {
    struct Outcome { let exitCode: Int32; let streamsComplete: Bool }
    private final class Admission: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.withLock {
                guard !claimed else { return false }
                claimed = true
                return true
            }
        }
    }
    // A damaged scope cannot be replaced with a new object and reused. Only
    // creating a new worker process resets this lifetime claim.
    private static let admission = Admission()
    private let null: MCPWorkerFD
    private var capturing = false
    private var poisoned = false

    private final class RelayState: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        private var sealing = false
        func fail() { lock.withLock { failed = true } }
        func seal() { lock.withLock { sealing = true } }
        var isSealing: Bool { lock.withLock { sealing } }
        var isFailed: Bool { lock.withLock { failed } }
    }

    private final class Join: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ complete: Bool) {
            let pending = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(returning: complete)
        }
    }

    init() throws {
        guard Self.admission.claim() else { throw MCPRequestStdioError.unavailable }
        let descriptor = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { throw MCPRequestStdioError.setup }
        defer { Darwin.close(descriptor) }
        null = try MCPWorkerFD(duplicating: descriptor)
        guard fflush(nil) == 0 else { throw MCPRequestStdioError.setup }
        for target: Int32 in [0, 1, 2] {
            guard dup2(null.value, target) >= 0 else { throw MCPRequestStdioError.setup }
        }
        clearerr(stdin); clearerr(stdout); clearerr(stderr)
        _ = fpurge(stdin)
    }

    /// The worker loop is the sole caller. This object is deliberately not
    /// Sendable: relays receive only their own descriptor and locked metadata.
    /// An incomplete outcome requires process retirement, never another call.
    func capture(input: Data, sealTimeout: TimeInterval = 1,
                 output: @escaping @Sendable (MCPWorkerWire.Stream, Data) throws -> Void,
                 operation: () async -> Int32) async throws -> Outcome {
        guard input.count <= MCPWorkerWire.maxInputBytes else { throw MCPRequestStdioError.inputLimit }
        guard sealTimeout.isFinite, (0.001...5).contains(sealTimeout) else { throw MCPRequestStdioError.setup }
        guard !capturing, !poisoned else { throw MCPRequestStdioError.unavailable }
        capturing = true
        defer { capturing = false }
        // Remains poisoned until every producer has actually left its boundary.
        poisoned = true
        let (inputRead, inputWrite) = try MCPWorkerFD.pipePair()
        let (outputRead, outputWrite) = try MCPWorkerFD.pipePair()
        let (errorRead, errorWrite) = try MCPWorkerFD.pipePair()
        try inputWrite.nonblocking()
        guard fcntl(inputWrite.value, F_SETNOSIGPIPE, 1) == 0 else { throw MCPRequestStdioError.setup }
        let state = RelayState()
        let group = DispatchGroup()
        func relay(_ descriptor: MCPWorkerFD, stream: MCPWorkerWire.Stream) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { descriptor.close(); group.leave() }
                var buffer = [UInt8](repeating: 0, count: MCPWorkerWire.maxOutputChunkBytes)
                while true {
                    let amount = Darwin.read(descriptor.value, &buffer, buffer.count)
                    if amount == 0 { return }
                    if amount < 0 {
                        if errno == EINTR { continue }
                        state.fail(); return
                    }
                    // A failed control writer must not leave the CLI blocked on
                    // a full stdout pipe. Drain/discard until it exits or is killed.
                    if !state.isFailed {
                        do { try output(stream, Data(buffer.prefix(amount))) }
                        catch { state.fail() }
                    }
                }
            }
        }
        guard dup2(inputRead.value, 0) >= 0, dup2(outputWrite.value, 1) >= 0,
              dup2(errorWrite.value, 2) >= 0 else { throw MCPRequestStdioError.setup }
        inputRead.close(); outputWrite.close(); errorWrite.close()
        // libc can retain unread input and EOF/error state across a dup2. The
        // CLI currently uses FileHandle stdin, but this boundary covers both.
        _ = fpurge(stdin)
        clearerr(stdin); clearerr(stdout); clearerr(stderr)
        relay(outputRead, stream: .stdout)
        relay(errorRead, stream: .stderr)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { inputWrite.close(); group.leave() }
            input.withUnsafeBytes { bytes in
                var offset = 0
                while offset < input.count, !state.isSealing {
                    let amount = Darwin.write(inputWrite.value, bytes.baseAddress!.advanced(by: offset), min(16384, input.count - offset))
                    if amount > 0 { offset += amount; continue }
                    if amount < 0, errno == EINTR { continue }
                    if amount < 0, errno == EPIPE { return } // command may ignore stdin
                    if amount < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        var item = pollfd(fd: inputWrite.value, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&item, 1, 10)
                        continue
                    }
                    state.fail(); return
                }
            }
        }
        let code = await operation()
        if fflush(nil) != 0 { state.fail() }
        state.seal()
        for target: Int32 in [0, 1, 2] {
            if dup2(null.value, target) < 0 { state.fail() }
        }
        _ = fpurge(stdin)
        clearerr(stdin); clearerr(stdout); clearerr(stderr)
        // The relays own their fds. A timed-out join never closes a descriptor
        // underneath a still-running read/write or gives it to another request.
        let joined = await withCheckedContinuation { continuation in
            let join = Join(continuation)
            group.notify(queue: .global(qos: .utility)) { join.finish(true) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + sealTimeout) { join.finish(false) }
        }
        let complete = joined && !state.isFailed
        poisoned = !complete
        return Outcome(exitCode: code, streamsComplete: complete)
    }
}
