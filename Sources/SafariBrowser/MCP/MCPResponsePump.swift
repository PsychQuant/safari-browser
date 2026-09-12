import Foundation

enum MCPResponsePumpError: Error, LocalizedError, Equatable, Sendable {
    case invalidLimit
    case closed
    case queueFull

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "MCP response queue limits must be positive."
        case .closed:
            return "MCP response transport is closed; no further output can be queued."
        case .queueFull:
            return "MCP response queue reached its configured frame or byte limit; the transport is closing instead of buffering more output."
        }
    }
}

/// Separates request processing from stdout backpressure. Admission is bounded and
/// returns without waiting for the client to read. A full queue terminates the
/// transport: silently dropping a response or retaining unbounded output is unsafe.
actor MCPResponsePump {
    typealias Write = @Sendable (Data) async throws -> Void
    typealias CloseOutput = @Sendable () async -> Void
    typealias OnFailure = @Sendable () async -> Void

    private let maximumQueuedFrames: Int
    private let maximumQueuedBytes: Int
    private let writeOutput: Write
    private let closeOutput: CloseOutput
    private let onFailure: OnFailure
    private var frames: [Data] = []
    private var queuedBytes = 0
    private var drainTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var closing = false
    private var failure: Error?

    init(
        writer: MCPStdioWriter,
        maximumQueuedFrames: Int = 64,
        maximumQueuedBytes: Int = 16 * 1024 * 1024,
        onFailure: @escaping OnFailure = {}
    ) throws {
        guard maximumQueuedFrames > 0, maximumQueuedBytes > 0 else {
            throw MCPResponsePumpError.invalidLimit
        }
        self.maximumQueuedFrames = maximumQueuedFrames
        self.maximumQueuedBytes = maximumQueuedBytes
        writeOutput = { try await writer.write($0) }
        closeOutput = { await writer.close() }
        self.onFailure = onFailure
    }

    /// Injectable output boundary for tests; production uses the writer initializer.
    init(
        maximumQueuedFrames: Int = 64,
        maximumQueuedBytes: Int = 16 * 1024 * 1024,
        write: @escaping Write,
        closeOutput: @escaping CloseOutput,
        onFailure: @escaping OnFailure = {}
    ) throws {
        guard maximumQueuedFrames > 0, maximumQueuedBytes > 0 else {
            throw MCPResponsePumpError.invalidLimit
        }
        self.maximumQueuedFrames = maximumQueuedFrames
        self.maximumQueuedBytes = maximumQueuedBytes
        writeOutput = write
        self.closeOutput = closeOutput
        self.onFailure = onFailure
    }

    func enqueue(_ frame: Data) throws {
        if let failure { throw failure }
        guard !closing else { throw MCPResponsePumpError.closed }
        // The active write remains at frames[0] until it completes. Include its
        // bytes and the LF added by MCPStdioWriter in both admission limits.
        guard frames.count < maximumQueuedFrames,
              frame.count < maximumQueuedBytes,
              frame.count + 1 <= maximumQueuedBytes - queuedBytes else {
            fail(MCPResponsePumpError.queueFull)
            throw MCPResponsePumpError.queueFull
        }
        queuedBytes += frame.count + 1
        frames.append(frame)
        if drainTask == nil {
            drainTask = Task { await self.drain() }
        }
    }

    func failureDescription() -> String? {
        failure?.localizedDescription
    }

    /// Aborts pending output, including a write blocked on an unread client pipe.
    /// Repeated callers await the same cleanup. No response is retried.
    func close() async {
        await beginClose().value
    }

    private func beginClose() -> Task<Void, Never> {
        if let closeTask { return closeTask }
        closing = true
        let drain = drainTask
        drain?.cancel()
        frames.removeAll(keepingCapacity: false)
        queuedBytes = 0
        let finishOutput = closeOutput
        let task = Task {
            await finishOutput()
            await drain?.value
        }
        closeTask = task
        return task
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        _ = beginClose()
        // Do not await a callback from the drain task itself. It may wake the input
        // loop, which in turn calls close() and joins the drain during shutdown.
        let notify = onFailure
        Task { await notify() }
    }

    private func drain() async {
        while !closing, let frame = frames.first {
            do {
                try await writeOutput(frame)
            } catch {
                if !closing { fail(error) }
                drainTask = nil
                return
            }
            guard !closing else {
                drainTask = nil
                return
            }
            frames.removeFirst()
            queuedBytes -= frame.count + 1
        }
        drainTask = nil
    }
}
