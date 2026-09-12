import Darwin
import Foundation

enum MCPStdioError: Error, LocalizedError, Equatable, Sendable {
    case invalidLimit
    case systemCall(String, Int32)
    case frameTooLarge
    case unterminatedFrame
    case closed
    case concurrentRead
    case embeddedNewline
    case writeQueueFull

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "MCP frame byte limit must be positive and within the supported integer range."
        case .systemCall(let operation, let code):
            var message = [CChar](repeating: 0, count: 256)
            let result = strerror_r(code, &message, message.count)
            let detail = result == 0 ? String(cString: message) : "unknown operating-system error"
            return "MCP \(operation) failed (errno \(code)): \(detail)."
        case .frameTooLarge:
            return "MCP frame exceeds the configured byte limit."
        case .unterminatedFrame:
            return "MCP input ended before the frame's required newline delimiter."
        case .closed:
            return "MCP standard I/O stream is closed."
        case .concurrentRead:
            return "MCP input already has a pending read; only one read may be active."
        case .embeddedNewline:
            return "MCP output frame contains a literal newline; the framing layer must append the delimiter."
        case .writeQueueFull:
            return "MCP output queue reached its configured frame or byte limit."
        }
    }
}

final class MCPStdioReader: @unchecked Sendable {
    private let state: ReadState
    private let admission = StdioAdmission(maximumCount: 1, maximumBytes: 0)

    /// Duplicates the descriptor. O_NONBLOCK is shared with the caller's descriptor;
    /// the caller must not use another reader for this stream while this object lives.
    init(fileDescriptor: Int32, maximumFrameBytes: Int = 8 * 1024 * 1024) throws {
        state = try ReadState(fileDescriptor: fileDescriptor, limit: maximumFrameBytes)
    }

    /// One frame at a time, excluding LF. Empty frames are returned to the JSON layer.
    /// EOF with an unfinished frame is an error. Cancellation terminates this reader.
    func next() async throws -> Data? {
        guard admission.reserve(bytes: 0) else { throw MCPStdioError.concurrentRead }
        defer { admission.release(bytes: 0) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.queue.async { [state] in state.begin(continuation) }
            }
        } onCancel: {
            state.queue.async { [state] in state.finish(.failure(CancellationError())) }
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            state.queue.async { [state] in
                state.finish(.failure(MCPStdioError.closed))
                continuation.resume()
            }
        }
    }
}

final class MCPStdioWriter: @unchecked Sendable {
    private let state: WriteState
    private let admission: StdioAdmission

    /// Duplicates the descriptor and sets O_NONBLOCK and per-descriptor NOSIGPIPE.
    /// Concurrent writes are serialized, with at most 64 frames / two maximum-sized
    /// frames retained. The caller must not write to this stream outside this object.
    init(fileDescriptor: Int32, maximumFrameBytes: Int = 8 * 1024 * 1024) throws {
        state = try WriteState(fileDescriptor: fileDescriptor, limit: maximumFrameBytes)
        admission = StdioAdmission(maximumCount: 64, maximumBytes: 2 * (maximumFrameBytes + 1))
    }

    /// Adds LF and returns only after all bytes have entered the output stream.
    /// Cancellation closes the writer: an interrupted partial frame cannot be retried
    /// or followed by another message without corrupting the protocol stream.
    func write(_ frame: Data) async throws {
        guard frame.count <= state.limit else { throw MCPStdioError.frameTooLarge }
        guard !frame.contains(10) else { throw MCPStdioError.embeddedNewline }
        // Reserve before dispatching a closure that retains the payload. Checking
        // only the serial queue's array would leave its incoming closures unbounded.
        guard admission.reserve(bytes: frame.count + 1) else { throw MCPStdioError.writeQueueFull }
        defer { admission.release(bytes: frame.count + 1) }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.queue.async { [state] in state.begin(frame, continuation: continuation) }
            }
        } onCancel: {
            state.queue.async { [state] in state.finish(CancellationError()) }
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            state.queue.async { [state] in
                state.finish(MCPStdioError.closed)
                continuation.resume()
            }
        }
    }
}

private final class StdioAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumCount: Int
    private let maximumBytes: Int
    private var count = 0
    private var bytes = 0

    init(maximumCount: Int, maximumBytes: Int) {
        self.maximumCount = maximumCount
        self.maximumBytes = maximumBytes
    }

    func reserve(bytes amount: Int) -> Bool {
        lock.withLock {
            guard count < maximumCount, amount <= maximumBytes - bytes else { return false }
            count += 1
            bytes += amount
            return true
        }
    }

    func release(bytes amount: Int) {
        lock.withLock {
            count -= 1
            bytes -= amount
        }
    }
}

private func duplicateNonblocking(_ original: Int32, forWriting: Bool, limit: Int) throws -> Int32 {
    guard limit > 0, limit <= (Int.max - 2) / 2 else { throw MCPStdioError.invalidLimit }
    let fd = fcntl(original, F_DUPFD_CLOEXEC, 0)
    guard fd >= 0 else { throw MCPStdioError.systemCall("dup", errno) }
    do {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw MCPStdioError.systemCall("fcntl(O_NONBLOCK)", errno)
        }
        if forWriting, fcntl(fd, F_SETNOSIGPIPE, 1) != 0 {
            throw MCPStdioError.systemCall("fcntl(F_SETNOSIGPIPE)", errno)
        }
        return fd
    } catch {
        Darwin.close(fd)
        throw error
    }
}

/// Every mutable field is confined to queue. Sources are suspended when no caller
/// is waiting, so an idle readable/writable descriptor never creates a busy loop.
private final class ReadState: @unchecked Sendable {
    let queue = DispatchQueue(label: "safari-browser.mcp.stdin")
    let fd: Int32
    let limit: Int
    private var source: DispatchSourceRead!
    private var suspended = true
    private var terminal: Result<Void, Error>?
    private var pending: CheckedContinuation<Data?, Error>?
    private var buffer = Data()
    private var scannedBytes = 0

    init(fileDescriptor: Int32, limit: Int) throws {
        self.limit = limit
        fd = try duplicateNonblocking(fileDescriptor, forWriting: false, limit: limit)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
    }

    deinit {
        source.cancel()
        if suspended { source.resume() }
    }

    func begin(_ continuation: CheckedContinuation<Data?, Error>) {
        if let terminal {
            continuation.resume(with: terminal.map { nil })
            return
        }
        guard pending == nil else {
            continuation.resume(throwing: MCPStdioError.concurrentRead)
            return
        }
        pending = continuation
        drain()
        if pending != nil, suspended {
            suspended = false
            source.resume()
        }
    }

    private func deliverBufferedFrame() -> Bool {
        let unscanned = buffer.index(buffer.startIndex, offsetBy: scannedBytes)..<buffer.endIndex
        if let newline = buffer[unscanned].firstIndex(of: 10) {
            let size = buffer.distance(from: buffer.startIndex, to: newline)
            guard size <= limit else {
                finish(.failure(MCPStdioError.frameTooLarge))
                return true
            }
            let frame = Data(buffer[..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            scannedBytes = 0
            let continuation = pending
            pending = nil
            if !suspended {
                source.suspend()
                suspended = true
            }
            continuation?.resume(returning: frame)
            return true
        }
        scannedBytes = buffer.count
        if buffer.count > limit {
            finish(.failure(MCPStdioError.frameTooLarge))
            return true
        }
        return false
    }

    private func drain() {
        guard pending != nil, terminal == nil else { return }
        if deliverBufferedFrame() { return }
        while pending != nil {
            // One extra byte distinguishes an exact-limit frame followed by LF
            // from an oversized frame without waiting for a delimiter or EOF.
            var bytes = [UInt8](repeating: 0, count: min(16 * 1024, limit + 1 - buffer.count))
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(count))
                if deliverBufferedFrame() { return }
            } else if count == 0 {
                finish(buffer.isEmpty ? .success(()) : .failure(MCPStdioError.unterminatedFrame))
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                finish(.failure(MCPStdioError.systemCall("read", errno)))
                return
            }
        }
    }

    func finish(_ result: Result<Void, Error>) {
        guard terminal == nil else { return }
        terminal = result
        buffer.removeAll(keepingCapacity: false)
        scannedBytes = 0
        let continuation = pending
        pending = nil
        source.cancel()
        if suspended {
            suspended = false
            source.resume()
        }
        continuation?.resume(with: result.map { nil })
    }
}

private final class WriteState: @unchecked Sendable {
    struct Pending {
        let bytes: Data
        var offset: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    let queue = DispatchQueue(label: "safari-browser.mcp.stdout")
    let fd: Int32
    let limit: Int
    private var source: DispatchSourceWrite!
    private var suspended = true
    private var terminalError: Error?
    private var pending: [Pending] = []
    private var queuedBytes = 0

    init(fileDescriptor: Int32, limit: Int) throws {
        self.limit = limit
        fd = try duplicateNonblocking(fileDescriptor, forWriting: true, limit: limit)
        source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
    }

    deinit {
        source.cancel()
        if suspended { source.resume() }
    }

    func begin(_ frame: Data, continuation: CheckedContinuation<Void, Error>) {
        if let terminalError {
            continuation.resume(throwing: terminalError)
            return
        }
        guard pending.count < 64, frame.count + 1 <= 2 * (limit + 1) - queuedBytes else {
            continuation.resume(throwing: MCPStdioError.writeQueueFull)
            return
        }
        var bytes = frame
        bytes.append(10)
        queuedBytes += bytes.count
        pending.append(Pending(bytes: bytes, offset: 0, continuation: continuation))
        drain()
        if !pending.isEmpty, suspended {
            suspended = false
            source.resume()
        }
    }

    private func drain() {
        guard terminalError == nil else { return }
        while !pending.isEmpty {
            let item = pending[0]
            let count = item.bytes.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: item.offset), $0.count - item.offset)
            }
            if count > 0 {
                pending[0].offset += count
                if pending[0].offset == item.bytes.count {
                    pending.removeFirst()
                    queuedBytes -= item.bytes.count
                    item.continuation.resume()
                }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                finish(MCPStdioError.systemCall("write", count == 0 ? EIO : errno))
                return
            }
        }
        if !suspended {
            source.suspend()
            suspended = true
        }
    }

    func finish(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        let interrupted = pending
        pending.removeAll(keepingCapacity: false)
        queuedBytes = 0
        source.cancel()
        if suspended {
            suspended = false
            source.resume()
        }
        for item in interrupted { item.continuation.resume(throwing: error) }
    }
}
