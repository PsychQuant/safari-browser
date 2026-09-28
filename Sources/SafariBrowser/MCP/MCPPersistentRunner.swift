import Foundation
import Darwin

/// A single serial I/O owner holds every process reservation and descriptor.
/// Admission/cancellation only publish intent; they never signal, close or reap.
final class MCPPersistentRunner: MCPCommandRunning, @unchecked Sendable {
    struct Lifecycle: Sendable {
        var supervisorArguments = ["__mcp-supervise"]
        var retire: @Sendable (MCPChildReservation) -> MCPChildReservation.Retirement = { $0.retire(timeout: 0) }
        var didLaunch: @Sendable (pid_t) -> Void = { _ in }
        var beforeRequestSend: @Sendable () throws -> Void = {}
    }
    private struct Configuration: Sendable {
        let executable: URL
        let environment: [String: String]
        let timeout: TimeInterval
        let idleTimeout: TimeInterval
        let outputLimit: Int
        let inputLimit: Int
        let cleanupTimeout: TimeInterval
        let lifecycle: Lifecycle
        var valid: Bool {
            executable.isFileURL && (0.001...86400).contains(timeout) && timeout.isFinite
                && (0.001...86400).contains(idleTimeout) && idleTimeout.isFinite
                && (0.001...5).contains(cleanupTimeout) && cleanupTimeout.isFinite
                && (1...2 * 1024 * 1024).contains(outputLimit) && (0...4 * 1024 * 1024).contains(inputLimit)
        }
        func environment(image: String) -> [String: String] {
            var value = environment
            value[MCPWorkerContext.directKey] = "1"
            value[MCPWorkerContext.imageKey] = image
            return value
        }
        func needsKernelAdmission(arguments: [String], image: String) -> Bool {
            let maximum = sysconf(_SC_ARG_MAX)
            guard maximum > 0 else { return true }
            var remaining = maximum / 2
            func reserve(_ count: Int) -> Bool {
                guard count <= remaining else { return false }
                remaining -= count; return true
            }
            let pointer = MemoryLayout<UnsafeRawPointer?>.size
            guard reserve(2 * pointer) else { return true }
            for value in [executable.path, "__mcp-exec"] + arguments {
                if !reserve(value.utf8.count) || !reserve(1 + pointer) { return true }
            }
            for (key, value) in environment(image: image) {
                if !reserve(key.utf8.count) || !reserve(value.utf8.count) || !reserve(2 + pointer) { return true }
            }
            return false
        }
    }
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var done = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isolated: Task<MCPCommandResult, Never>?
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() {
            let task = lock.withLock { cancelled = true; return isolated }
            task?.cancel()
        }
        func attach(_ task: Task<MCPCommandResult, Never>) {
            let stop = lock.withLock { isolated = task; return cancelled }
            if stop { task.cancel() }
        }
        func finish() {
            let pending = lock.withLock {
                done = true; isolated = nil
                let pending = waiters; waiters = []
                return pending
            }
            for waiter in pending { waiter.resume() }
        }
        func wait() async {
            await withCheckedContinuation { continuation in
                let complete = lock.withLock {
                    if done { return true }
                    waiters.append(continuation); return false
                }
                if complete { continuation.resume() }
            }
        }
    }
    private final class Admission: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var active: Request?
        func begin(_ request: Request) -> String? {
            lock.withLock {
                guard !stopped else { return "MCP runner is shut down; command was not executed." }
                guard active == nil else { return "MCP worker is busy; command was not executed." }
                active = request; return nil
            }
        }
        func finish(_ request: Request) {
            lock.withLock { if active === request { active = nil } }
            request.finish()
        }
        func stop() -> Request? { lock.withLock { stopped = true; return active } }
    }
    private enum Step: Sendable { case result(MCPCommandResult), isolated(deadline: TimeInterval) }
    private let config: Configuration
    private let admission = Admission()
    private let state: State

    init(executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
         timeout: TimeInterval = 300, idleTimeout: TimeInterval = 30,
         outputLimit: Int = 2 * 1024 * 1024, inputLimit: Int = 4 * 1024 * 1024,
         cleanupTimeout: TimeInterval = 2, lifecycle: Lifecycle = Lifecycle()) {
        config = Configuration(executable: executable, environment: environment, timeout: timeout,
                               idleTimeout: idleTimeout, outputLimit: outputLimit, inputLimit: inputLimit,
                               cleanupTimeout: cleanupTimeout, lifecycle: lifecycle)
        state = State(config)
    }
    deinit {
        let owner = state
        owner.queue.async { owner.dispose() }
    }

    func run(arguments: [String], input: Data, expectedImage: String) async -> MCPCommandResult {
        guard config.valid else { return MCPCommandResult(failure: "Invalid worker limits; command was not executed.") }
        guard input.count <= config.inputLimit else {
            return MCPCommandResult(failure: "Worker stdin exceeds the input limit; command was not executed.")
        }
        guard ([config.executable.path] + arguments).allSatisfy({ !$0.utf8.contains(0) }),
              config.environment(image: expectedImage).allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            return MCPCommandResult(failure: "Worker argv or environment contains an invalid string; command was not executed.")
        }
        let request = Request()
        if let failure = admission.begin(request) { return MCPCommandResult(failure: failure) }
        let deadline = ProcessInfo.processInfo.systemUptime + config.timeout
        // The caller cannot observe completion until admission has been released.
        defer { admission.finish(request) }
        return await withTaskCancellationHandler {
            let step: Step = await withCheckedContinuation { continuation in
                state.queue.async { [state] in
                    continuation.resume(returning: state.execute(arguments, input: input, image: expectedImage, request: request, deadline: deadline))
                }
            }
            switch step {
            case .result(let value): return value
            case .isolated(let deadline):
                let config = config
                let task = Task {
                    await MCPProcessRunner(executable: config.executable, environment: config.environment,
                                           timeout: config.timeout, outputLimit: config.outputLimit, inputLimit: config.inputLimit, invocationDeadline: deadline)
                        .run(arguments: arguments, input: input, expectedImage: expectedImage)
                }
                request.attach(task)
                return await task.value
            }
        } onCancel: { request.cancel() }
    }

    func shutdown() async -> String? {
        if let request = admission.stop() { request.cancel(); await request.wait() }
        return await withCheckedContinuation { continuation in
            state.queue.async { [state] in
                state.invalidateIdle()
                continuation.resume(returning: state.retire(collecting: nil))
            }
        }
    }

    private enum Failure: Error { case message(String) }
    private final class Invocation {
        let id = UUID()
        var result = MCPCommandResult()
        var sent = 0
        var complete = false
        var reusable = false
        var frameSize = 0
        var sendPrepared = false
    }
    private final class Generation {
        let pair: MCPWorkerPair
        var workerPID: Int32?
        var buffer = Data()
        var statusBytes = Data()
        var statusRecord: MCPWorkerWire.TerminationRecord?
        var controlOpen = true
        var diagnosticsOpen = true
        var statusOpen = true
        var retiring = false
        init(_ pair: MCPWorkerPair) { self.pair = pair }
    }
    private final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "safari-browser.mcp.persistent-owner", qos: .userInitiated)
        let config: Configuration
        var generation: Generation?
        var catalogImage: String?
        var invalidatedImage = false
        var lostOwnership = false
        var idleEpoch: UInt64 = 0
        var idle: DispatchWorkItem?
        init(_ config: Configuration) { self.config = config }

        func invalidateIdle() { idleEpoch &+= 1; idle?.cancel(); idle = nil }
        func armIdle() {
            guard let current = generation, !current.retiring else { return }
            idleEpoch &+= 1
            let epoch = idleEpoch
            let work = DispatchWorkItem { [weak self, weak current] in
                guard let self, let current, self.idleEpoch == epoch, self.generation === current else { return }
                _ = self.retire(collecting: nil)
            }
            idle = work
            queue.asyncAfter(deadline: .now() + config.idleTimeout, execute: work)
        }
        func dispose() {
            invalidateIdle()
            _ = retire(collecting: nil)
            if generation != nil, !lostOwnership {
                // Keep the unreaped owner reserved if the OS has not finished.
                queue.asyncAfter(deadline: .now() + 1) { self.dispose() }
            }
        }
        func execute(_ arguments: [String], input: Data, image: String, request: Request, deadline: TimeInterval) -> Step {
            let invocation = Invocation()
            if request.isCancelled {
                invocation.result.cancelled = true
                invocation.result.failure = "Command cancelled before execution; command was not executed."
                return .result(invocation.result)
            }
            invalidateIdle()
            if generation?.retiring == true || lostOwnership {
                if let failure = retire(collecting: nil) {
                    return .result(MCPCommandResult(failure: failure + " Command was not executed."))
                }
            }
            do {
                try check(request, deadline: deadline, sent: 0)
                if catalogImage == nil { catalogImage = image }
                do {
                    guard !invalidatedImage, catalogImage == image,
                          try MCPExecutableIdentity.readImage(at: config.executable, architecture: MCPExecutableIdentity.currentArchitecture()) == image else {
                        throw MCPWorkerContext.imageChangedError
                    }
                } catch {
                    invalidatedImage = true
                    let diagnostic = CLIExecution.diagnostic(for: MCPWorkerContext.imageChangedError)
                    invocation.result.exitCode = diagnostic.exitCode
                    try append(diagnostic.bytes, stream: .stderr, invocation: invocation)
                    throw Failure.message("MCP executable changed; restart the MCP server before calling tools. The command was not executed.")
                }
                try check(request, deadline: deadline, sent: 0)
                if config.needsKernelAdmission(arguments: arguments, image: image) {
                    if let failure = retire(collecting: nil) { throw Failure.message(failure + " Command was not executed.") }
                    try check(request, deadline: deadline, sent: 0)
                    return .isolated(deadline: deadline) // Same invocation budget; selected before any bytes, never a retry.
                }
                let frame: Data
                do {
                    frame = try MCPWorkerWire.encodeClient(.request(id: invocation.id, arguments: arguments, input: input)) + Data([10])
                } catch MCPWorkerWire.WireError.clientFrameTooLarge {
                    // Private base64/JSON expansion must not narrow the public
                    // input contract. Select once before sending any bytes.
                    if let failure = retire(collecting: nil) { throw Failure.message(failure + " Command was not executed.") }
                    try check(request, deadline: deadline, sent: 0)
                    return .isolated(deadline: deadline)
                }
                invocation.frameSize = frame.count
                if generation == nil {
                    let pair = try MCPWorkerPair.launch(executable: config.executable,
                        arguments: config.lifecycle.supervisorArguments, environment: config.environment(image: image))
                    generation = Generation(pair)
                    config.lifecycle.didLaunch(pair.child.pid)
                }
                guard let current = generation else { throw Failure.message("Worker launch failed; command was not executed.") }
                // An idle worker that died between calls may be replaced before
                // transmission. This is not a retry of an executing invocation.
                if current.workerPID != nil {
                    try drainAuxiliary(current, invocation: nil)
                    try drainControl(current, invocation: nil, image: image)
                    guard current.buffer.isEmpty else { throw MCPWorkerWire.WireError.invalidFrame }
                    let exited = try current.pair.child.observe() == .exited
                    if !current.controlOpen || exited {
                        if let failure = retire(collecting: nil) { throw Failure.message(failure + " Command was not executed.") }
                        try check(request, deadline: deadline, sent: 0)
                        let pair = try MCPWorkerPair.launch(executable: config.executable,
                            arguments: config.lifecycle.supervisorArguments, environment: config.environment(image: image))
                        generation = Generation(pair); config.lifecycle.didLaunch(pair.child.pid)
                    }
                }
                guard let current = generation else { throw MCPWorkerLaunchError.spawn }
                while !invocation.complete {
                    try check(request, deadline: deadline, sent: invocation.sent)
                    try drainAuxiliary(current, invocation: invocation)
                    try drainControl(current, invocation: invocation, image: image)
                    if invocation.complete { break }
                    if !current.controlOpen { throw Failure.message(unknown("Worker channel ended without completion", sent: invocation.sent)) }
                    if try current.pair.child.observe() == .exited {
                        throw Failure.message(unknown("Worker exited without completion", sent: invocation.sent))
                    }
                    if current.workerPID != nil, !current.diagnosticsOpen, invocation.sent < frame.count {
                        guard current.buffer.isEmpty else { throw MCPWorkerWire.WireError.invalidFrame }
                        if !invocation.sendPrepared {
                            try config.lifecycle.beforeRequestSend()
                            invocation.sendPrepared = true
                        }
                        try check(request, deadline: deadline, sent: invocation.sent)
                        let count = frame.withUnsafeBytes { bytes in
                            Darwin.write(current.pair.control, bytes.baseAddress!.advanced(by: invocation.sent), min(16384, frame.count - invocation.sent))
                        }
                        if count > 0 { invocation.sent += count }
                        else if count < 0, errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                            throw Failure.message(unknown("Worker request could not be delivered", sent: invocation.sent))
                        }
                    }
                    poll(current, writable: current.workerPID != nil && !current.diagnosticsOpen && invocation.sent < frame.count,
                         deadline: deadline)
                }
                guard current.buffer.isEmpty else { throw MCPWorkerWire.WireError.invalidFrame }
                let leaderExited = try current.pair.child.observe() == .exited
                if !invocation.reusable || !current.controlOpen || leaderExited {
                    if let failure = retire(collecting: invocation) { invocation.result.failure = failure }
                } else { armIdle() }
                return .result(invocation.result)
            } catch {
                invocation.result.cancelled = request.isCancelled
                if case Failure.message(let message) = error { invocation.result.failure = invocation.result.failure ?? message }
                else { invocation.result.failure = invocation.result.failure ?? unknown("Worker channel or ownership failed", sent: invocation.sent) }
                if let failure = retire(collecting: invocation) {
                    invocation.result.failure = (invocation.result.failure ?? "Worker failed.") + " " + failure
                }
                return .result(invocation.result)
            }
        }

        private func unknown(_ message: String, sent: Int) -> String {
            sent == 0 ? message + "; command was not executed."
                : message + "; output is incomplete and earlier side effects may already have occurred."
        }
        private func check(_ request: Request, deadline: TimeInterval, sent: Int) throws {
            if request.isCancelled { throw Failure.message(unknown("Command cancelled", sent: sent)) }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure.message(unknown("Command timed out", sent: sent)) }
        }
        private func append(_ bytes: Data, stream: MCPWorkerWire.Stream, invocation: Invocation) throws {
            let count = stream == .stdout ? invocation.result.stdout.count : invocation.result.stderr.count
            let retained = min(bytes.count, max(0, config.outputLimit - count))
            if stream == .stdout { invocation.result.stdout.append(bytes.prefix(retained)) }
            else { invocation.result.stderr.append(bytes.prefix(retained)) }
            if retained < bytes.count {
                invocation.result.truncated = true
                invocation.result.failure = "Worker output exceeded the capture limit; output is incomplete."
                throw Failure.message(invocation.result.failure!)
            }
        }
        private func drainControl(_ current: Generation, invocation: Invocation?, image: String?, discard: Bool = false) throws {
            guard current.controlOpen else { return }
            var bytes = [UInt8](repeating: 0, count: 8192)
            for _ in 0..<32 {
                let count = Darwin.read(current.pair.control, &bytes, bytes.count)
                if count == 0 {
                    current.controlOpen = false
                    if !discard, !current.buffer.isEmpty { throw MCPWorkerWire.WireError.invalidFrame }
                    return
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    current.controlOpen = false; throw MCPStdioError.closed
                }
                if discard { continue }
                current.buffer.append(contentsOf: bytes.prefix(count))
                while let newline = current.buffer.firstIndex(of: 10) {
                    let data = Data(current.buffer[..<newline]); current.buffer.removeSubrange(...newline)
                    let message = try MCPWorkerWire.decodeServer(data)
                    if current.workerPID == nil {
                        guard case .hello(let actual, let worker, let supervisor) = message,
                              actual == image, supervisor == current.pair.child.pid, worker > 1, worker != supervisor else {
                            throw MCPWorkerWire.WireError.invalidFrame
                        }
                        if let record = current.statusRecord, record.workerPID != worker { throw MCPWorkerWire.WireError.invalidFrame }
                        current.workerPID = worker
                    } else {
                        guard let invocation, invocation.sent == invocation.frameSize, !invocation.complete else {
                            throw MCPWorkerWire.WireError.invalidFrame
                        }
                        switch message {
                        case .output(let id, let stream, let payload):
                            guard id == invocation.id else { throw MCPWorkerWire.WireError.invalidFrame }
                            try append(payload, stream: stream, invocation: invocation)
                        case .complete(let id, let code, let reusable):
                            guard id == invocation.id else { throw MCPWorkerWire.WireError.invalidFrame }
                            invocation.result.exitCode = code; invocation.complete = true; invocation.reusable = reusable
                        case .retire(let id, let reason, let code):
                            guard id == invocation.id else { throw MCPWorkerWire.WireError.invalidFrame }
                            invocation.result.exitCode = code
                            if reason == .image {
                                invalidatedImage = true
                                throw Failure.message("MCP executable changed; restart the MCP server before calling tools. The command was not executed.")
                            }
                            throw Failure.message("Worker retired (\(reason.rawValue)); output is incomplete and earlier side effects may already have occurred.")
                        case .hello: throw MCPWorkerWire.WireError.invalidFrame
                        }
                    }
                }
                guard current.buffer.count <= MCPWorkerWire.maxServerFrameBytes else { throw MCPWorkerWire.WireError.invalidFrame }
            }
        }
        private func drainAuxiliary(_ current: Generation, invocation: Invocation?) throws {
            var bytes = [UInt8](repeating: 0, count: 8192)
            if current.diagnosticsOpen {
                for _ in 0..<32 {
                    let count = Darwin.read(current.pair.diagnostics, &bytes, bytes.count)
                    if count == 0 { current.diagnosticsOpen = false; break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        current.diagnosticsOpen = false; throw MCPStdioError.closed
                    }
                    if let invocation { try append(Data(bytes.prefix(count)), stream: .stderr, invocation: invocation) }
                }
            }
            if current.statusOpen {
                for _ in 0..<2 {
                    let count = Darwin.read(current.pair.status, &bytes, 13)
                    if count == 0 {
                        current.statusOpen = false
                        if !current.statusBytes.isEmpty, current.statusBytes.count != MCPWorkerWire.TerminationRecord.byteCount {
                            throw MCPWorkerWire.WireError.invalidFrame
                        }
                        break
                    }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        current.statusOpen = false; throw MCPStdioError.closed
                    }
                    guard count <= MCPWorkerWire.TerminationRecord.byteCount - current.statusBytes.count else {
                        current.statusOpen = false
                        throw MCPWorkerWire.WireError.invalidFrame
                    }
                    current.statusBytes.append(contentsOf: bytes.prefix(count))
                    if current.statusBytes.count == MCPWorkerWire.TerminationRecord.byteCount {
                        let record = try MCPWorkerWire.TerminationRecord.decode(current.statusBytes)
                        if let worker = current.workerPID, worker != record.workerPID { throw MCPWorkerWire.WireError.invalidFrame }
                        current.statusRecord = record
                    }
                }
            }
        }
        private func poll(_ current: Generation, writable: Bool, deadline: TimeInterval) {
            var items: [pollfd] = []
            if current.controlOpen { items.append(pollfd(fd: current.pair.control, events: Int16(POLLIN | (writable ? POLLOUT : 0)), revents: 0)) }
            if current.diagnosticsOpen { items.append(pollfd(fd: current.pair.diagnostics, events: Int16(POLLIN), revents: 0)) }
            if current.statusOpen { items.append(pollfd(fd: current.pair.status, events: Int16(POLLIN), revents: 0)) }
            let remaining = max(0, min(0.01, deadline - ProcessInfo.processInfo.systemUptime))
            _ = Darwin.poll(&items, nfds_t(items.count), Int32((remaining * 1000).rounded(.up)))
        }

        func retire(collecting invocation: Invocation?) -> String? {
            invalidateIdle()
            if lostOwnership { return "Worker ownership was lost; cleanup cannot be confirmed." }
            guard let current = generation else { return nil }
            current.retiring = true
            let deadline = ProcessInfo.processInfo.systemUptime + config.cleanupTimeout
            var retired = false
            var captureFailed = false
            repeat {
                do {
                    try drainAuxiliary(current, invocation: invocation)
                    try drainControl(current, invocation: invocation, image: catalogImage,
                                     discard: invocation == nil || invocation?.result.truncated == true || captureFailed)
                } catch {
                    captureFailed = true
                    current.buffer.removeAll(keepingCapacity: false)
                }
                if !retired {
                    switch config.lifecycle.retire(current.pair.child) {
                    case .reaped: retired = true
                    case .pending: break
                    case .ownershipLost:
                        lostOwnership = true
                        current.pair.closeChannels()
                        return "Worker ownership was lost; cleanup cannot be confirmed."
                    }
                }
                if retired, !current.controlOpen, !current.diagnosticsOpen, !current.statusOpen { break }
                poll(current, writable: false, deadline: deadline)
            } while ProcessInfo.processInfo.systemUptime < deadline
            if !retired { return "Worker cleanup is pending; its process reservation is retained." }
            let remainingOutput = current.controlOpen || current.diagnosticsOpen
            current.pair.closeChannels()
            generation = nil
            if remainingOutput { return "Worker output remained open after termination; capture is incomplete." }
            if captureFailed, invocation?.complete == true { return "Worker termination metadata or trailing output was invalid." }
            return nil
        }
    }
}
