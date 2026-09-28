import Foundation
import Darwin

struct MCPCommandResult: Sendable {
    var stdout: Data = Data()
    var stderr: Data = Data()
    var exitCode: Int32? = nil
    var cancelled = false
    var truncated = false
    var failure: String? = nil
}

protocol MCPCommandRunning: Sendable {
    func run(arguments: [String], input: Data, expectedImage: String) async -> MCPCommandResult
    func shutdown() async -> String?
}

extension MCPCommandRunning {
    func shutdown() async -> String? { nil }
}

/// The runner, including an unconfirmed retirement, has one serial I/O owner.
/// Admission and cancellation never signal, close descriptors, or reap children.
final class MCPProcessRunner: MCPCommandRunning, @unchecked Sendable {
    struct Lifecycle: Sendable {
        var retire: @Sendable (MCPChildReservation) -> MCPChildReservation.Retirement = { $0.retire(timeout: 0) }
        var didLaunch: @Sendable (pid_t) -> Void = { _ in }
    }
    private struct Configuration: Sendable {
        let executable: URL
        let environment: [String: String]
        let workerPrefix: [String]
        let supervisorExecutable: URL?
        let timeout: TimeInterval
        let outputLimit: Int
        let inputLimit: Int
        let invocationDeadline: TimeInterval?
        let cleanupTimeout: TimeInterval
        let lifecycle: Lifecycle
        var valid: Bool {
            timeout.isFinite && (0.001...86400).contains(timeout) && outputLimit > 0 && inputLimit >= 0
                && invocationDeadline?.isFinite != false && cleanupTimeout.isFinite && (0.001...5).contains(cleanupTimeout)
        }
    }
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var done = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
        func finish() {
            let pending = lock.withLock { done = true; let value = waiters; waiters = []; return value }
            for waiter in pending { waiter.resume() }
        }
        func wait() async {
            await withCheckedContinuation { continuation in
                let finished = lock.withLock {
                    if done { return true }
                    waiters.append(continuation); return false
                }
                if finished { continuation.resume() }
            }
        }
    }
    private final class Admission: @unchecked Sendable {
        private let lock = NSLock()
        private var active: Request?
        private var stopped = false
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
    private let config: Configuration
    private let admission = Admission()
    private let state: State

    init(executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
         workerPrefix: [String] = ["__mcp-exec"], supervisorExecutable: URL? = nil,
         timeout: TimeInterval = 300, outputLimit: Int = 2 * 1024 * 1024, inputLimit: Int = 4 * 1024 * 1024,
         invocationDeadline: TimeInterval? = nil, cleanupTimeout: TimeInterval = 2, lifecycle: Lifecycle = Lifecycle()) {
        config = Configuration(executable: executable, environment: environment, workerPrefix: workerPrefix,
            supervisorExecutable: supervisorExecutable, timeout: timeout, outputLimit: outputLimit, inputLimit: inputLimit,
            invocationDeadline: invocationDeadline, cleanupTimeout: cleanupTimeout, lifecycle: lifecycle)
        state = State(config)
    }
    deinit {
        let owner = state
        owner.queue.async { owner.dispose() }
    }

    func run(arguments: [String], input: Data, expectedImage: String) async -> MCPCommandResult {
        await run(arguments: arguments, input: input, expectedImage: expectedImage, deadline: config.invocationDeadline)
    }
    func run(arguments: [String], input: Data, expectedImage: String, deadline: TimeInterval?) async -> MCPCommandResult {
        guard config.valid, deadline?.isFinite != false else { return MCPCommandResult(failure: "Invalid worker limits.") }
        let request = Request()
        if let failure = admission.begin(request) { return MCPCommandResult(failure: failure) }
        let absoluteDeadline = min(deadline ?? .infinity, ProcessInfo.processInfo.systemUptime + config.timeout)
        defer { admission.finish(request) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.queue.async { [state] in
                    continuation.resume(returning: state.execute(arguments: arguments, input: input, image: expectedImage,
                                                                 request: request, deadline: absoluteDeadline))
                }
            }
        } onCancel: { request.cancel() }
    }

    /// The persistent facade calls this before choosing *either* engine. An old
    /// one-shot reservation must not be hidden by starting a fresh warm pair.
    func prepareForInvocation() async -> String? {
        await withCheckedContinuation { continuation in
            state.queue.async { [state] in continuation.resume(returning: state.retireRetained()) }
        }
    }

    func shutdown() async -> String? {
        if let request = admission.stop() { request.cancel(); await request.wait() }
        return await prepareForInvocation()
    }

    private final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "safari-browser.mcp.isolated-owner", qos: .userInitiated)
        let config: Configuration
        var child: MCPChildReservation?
        var supervision: MCPIsolatedChannels?
        var lostOwnership = false
        init(_ config: Configuration) { self.config = config }
        private let pendingMessage = "Worker cleanup is pending; its process reservation is retained."
        private let lostMessage = "Worker ownership was lost; cleanup cannot be confirmed."

        func retireRetained() -> String? {
            if lostOwnership { return lostMessage }
            guard let child else { return nil }
            let deadline = ProcessInfo.processInfo.systemUptime + config.cleanupTimeout
            repeat {
                switch config.lifecycle.retire(child) {
                case .reaped:
                    self.child = nil; supervision = nil; return nil
                case .ownershipLost:
                    lostOwnership = true; self.child = nil; supervision = nil; return lostMessage
                case .pending: break
                }
                if ProcessInfo.processInfo.systemUptime >= deadline { return pendingMessage }
                usleep(5_000)
            } while true
        }
        func dispose() {
            _ = retireRetained()
            if child != nil, !lostOwnership { queue.asyncAfter(deadline: .now() + 1) { self.dispose() } }
        }

        func execute(arguments: [String], input: Data, image: String, request: Request, deadline: TimeInterval) -> MCPCommandResult {
            var result = MCPCommandResult()
            if let failure = retireRetained() { return MCPCommandResult(failure: failure + " Command was not executed.") }
            guard input.count <= config.inputLimit else { return MCPCommandResult(failure: "Worker stdin exceeds the input limit; command was not executed.") }
            var environment = config.environment
            environment[MCPWorkerContext.directKey] = MCPIsolatedBootstrap.contextValue
            environment[MCPWorkerContext.imageKey] = image
            let arguments = config.workerPrefix + arguments
            guard ([config.executable.path] + arguments).allSatisfy({ !$0.utf8.contains(0) }),
                  environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
                return MCPCommandResult(failure: "Worker argv or environment contains an invalid string; command was not executed.")
            }
            if request.isCancelled { return MCPCommandResult(cancelled: true, failure: "Command cancelled before execution; command was not executed.") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return MCPCommandResult(failure: "Command timed out before execution; command was not executed.") }

            // Stack-owned stream endpoints close on every return. An unfinished
            // process reservation and its lease remain on State across returns.
            let channels: MCPIsolatedChannels
            let streams: [MCPWorkerFD]
            do {
                channels = try MCPIsolatedChannels(deadline: deadline, environment: environment)
                let input = try MCPWorkerFD.pipePair(), output = try MCPWorkerFD.pipePair(), error = try MCPWorkerFD.pipePair()
                streams = [input.0, input.1, output.0, output.1, error.0, error.1]
                for index in [1, 2, 4] { try streams[index].nonblocking() }
                guard fcntl(streams[1].value, F_SETNOSIGPIPE, 1) == 0 else { throw MCPWorkerLaunchError.descriptors }
            } catch { return MCPCommandResult(failure: "Worker supervision or streams could not be prepared.") }
            defer { for stream in streams { stream.close() } }
            let owned: MCPChildReservation
            do {
                if request.isCancelled { return MCPCommandResult(cancelled: true, failure: "Command cancelled before execution; command was not executed.") }
                owned = try MCPWorkerSpawn.child(executable: config.supervisorExecutable ?? config.executable,
                    arguments: arguments, environment: environment,
                    descriptors: [0: streams[0].value, 1: streams[3].value, 2: streams[5].value,
                                  3: channels.metadata.value, 4: channels.leaseRead.value, 5: channels.statusWrite.value],
                    deadline: deadline, argument0: config.executable.path, blockTermination: true)
            } catch MCPWorkerLaunchError.spawnSystemError(let code) {
                return MCPCommandResult(failure: "Worker launch failed: \(String(cString: strerror(code))).")
            } catch {
                return MCPCommandResult(failure: ProcessInfo.processInfo.systemUptime >= deadline
                    ? "Command timed out before execution; command was not executed." : "Worker launch could not be prepared; command was not executed.")
            }
            child = owned; supervision = channels
            channels.didSpawn()
            config.lifecycle.didLaunch(owned.pid)
            for index in [0, 3, 5] { streams[index].close() }
            if input.isEmpty { streams[1].close() }
            var retirementStarted: TimeInterval?
            var retired = false
            var inputOffset = 0
            var buffer = [UInt8](repeating: 0, count: 8192)
            func stop(_ failure: String?) {
                if result.failure == nil { result.failure = failure }
                if retirementStarted == nil { retirementStarted = ProcessInfo.processInfo.systemUptime }
                streams[1].close()
            }
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                if request.isCancelled {
                    result.cancelled = true
                    stop("Command cancelled; earlier side effects may already have occurred.")
                }
                if now >= deadline { stop("Command timed out; earlier side effects may already have occurred.") }
                if !retired {
                    do { if try owned.observe() == .exited { stop(nil) } }
                    catch MCPWorkerLaunchError.ownershipLost {
                        lostOwnership = true; child = nil; supervision = nil
                        result.failure = lostMessage; return result
                    } catch { stop("Worker status could not be read; cleanup cannot be confirmed.") }
                }
                if retirementStarted == nil {
                    do { try channels.pumpEnvironment() }
                    catch { stop("Worker startup context could not be delivered; command outcome is unknown.") }
                }
                for index in [2, 4] where streams[index].value >= 0 {
                    for _ in 0..<32 {
                        let count = Darwin.read(streams[index].value, &buffer, buffer.count)
                        if count > 0 {
                            let existing = index == 2 ? result.stdout.count : result.stderr.count
                            let kept = min(count, config.outputLimit - existing)
                            if index == 2 { result.stdout.append(contentsOf: buffer.prefix(kept)) }
                            else { result.stderr.append(contentsOf: buffer.prefix(kept)) }
                            if kept < count { result.truncated = true; stop("Worker output exceeded the capture limit; output is incomplete.") }
                        } else if count == 0 { streams[index].close(); break }
                        else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        else if errno != EINTR { stop("Worker output could not be read; output is incomplete."); streams[index].close(); break }
                    }
                }
                if streams[1].value >= 0 {
                    let count = input.withUnsafeBytes { bytes in
                        Darwin.write(streams[1].value, bytes.baseAddress!.advanced(by: inputOffset), min(16384, bytes.count - inputOffset))
                    }
                    if count > 0 { inputOffset += count; if inputOffset == input.count { streams[1].close() } }
                    else if count < 0, errno == EPIPE { streams[1].close() }
                    else if count < 0, errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { stop("Worker stdin could not be delivered.") }
                }
                if let retirementStarted {
                    if !retired {
                        switch config.lifecycle.retire(owned) {
                        case .reaped: retired = true; child = nil
                        case .ownershipLost:
                            lostOwnership = true; child = nil; supervision = nil
                            result.failure = lostMessage; return result
                        case .pending: break
                        }
                    }
                    if retired, streams[2].value < 0, streams[4].value < 0 { break }
                    if ProcessInfo.processInfo.systemUptime - retirementStarted >= config.cleanupTimeout {
                        if !retired {
                            result.failure = (result.failure.map { $0 + " " } ?? "") + pendingMessage
                            return result // State retains child + lease; no new work.
                        }
                        result.failure = result.failure ?? "Worker output remained open after termination; capture is incomplete."
                        break
                    }
                }
                var items: [pollfd] = []
                if retirementStarted == nil, let metadata = channels.pendingMetadataDescriptor {
                    items.append(pollfd(fd: metadata, events: Int16(POLLOUT), revents: 0))
                }
                for index in [2, 4] where streams[index].value >= 0 { items.append(pollfd(fd: streams[index].value, events: Int16(POLLIN), revents: 0)) }
                if streams[1].value >= 0 { items.append(pollfd(fd: streams[1].value, events: Int16(POLLOUT), revents: 0)) }
                _ = poll(&items, nfds_t(items.count), 10)
            }
            supervision = nil
            do {
                let status = try channels.termination().rawWaitStatus
                let signal = status & 0x7f
                if signal == 0 { result.exitCode = (status >> 8) & 0xff }
                else {
                    result.exitCode = 128 + signal
                    result.failure = result.failure ?? "Worker terminated by signal \(signal); earlier side effects may already have occurred."
                }
            } catch { result.failure = result.failure ?? "Worker ended without a valid status record; output may be incomplete." }
            return result
        }
    }
}
