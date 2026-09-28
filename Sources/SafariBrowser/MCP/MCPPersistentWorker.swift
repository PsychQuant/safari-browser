import ArgumentParser
import Darwin
import Foundation

/// Private worker state machine. Dependencies separate process-global CLI stdio
/// from the decision to admit another request; production and fault tests use
/// this same loop. No branch retries a request or queues a second invocation.
enum MCPPersistentWorkerLoop {
    typealias Output = @Sendable (MCPWorkerWire.Stream, Data) throws -> Void
    typealias Execution = ([String], Data, @escaping Output) async throws -> MCPRequestStdio.Outcome
    static func run(image: String, workerPID: Int32, supervisorPID: Int32,
                    next: () async throws -> Data?, send: @escaping @Sendable (MCPWorkerWire.ServerMessage) throws -> Void,
                    execute: Execution, validateImage: () throws -> Void,
                    onlyOwnedProcesses: () -> Bool, axIsQuiescent: () -> Bool) async throws {
        try send(.hello(image: image, workerPID: workerPID, supervisorPID: supervisorPID))
        while let frame = try await next() {
            switch try MCPWorkerWire.decodeClient(frame) {
            case .shutdown: return
            case .request(let id, let arguments, let input):
                do { try validateImage() }
                catch {
                    let diagnostic = CLIExecution.diagnostic(for: MCPWorkerContext.imageChangedError)
                    for start in stride(from: 0, to: diagnostic.bytes.count, by: MCPWorkerWire.maxOutputChunkBytes) {
                        let end = min(start + MCPWorkerWire.maxOutputChunkBytes, diagnostic.bytes.count)
                        try send(.output(id: id, stream: .stderr, bytes: diagnostic.bytes.subdata(in: start..<end)))
                    }
                    try send(.complete(id: id, exitCode: diagnostic.exitCode & 0xff, reusable: false))
                    return
                }
                let outcome: MCPRequestStdio.Outcome
                do {
                    outcome = try await execute(arguments, input) { stream, bytes in
                        try send(.output(id: id, stream: stream, bytes: bytes))
                    }
                } catch {
                    try send(.retire(id: id, reason: .io, exitCode: nil))
                    return
                }
                // Match the status observable from an exited CLI (low 8 bits).
                let code = outcome.exitCode & 0xff
                guard outcome.streamsComplete else {
                    try send(.retire(id: id, reason: .io, exitCode: code)); return
                }
                guard onlyOwnedProcesses() else {
                    try send(.retire(id: id, reason: .descendants, exitCode: code)); return
                }
                let reusable = axIsQuiescent()
                try send(.complete(id: id, exitCode: code, reusable: reusable))
                if !reusable { return }
            }
        }
    }
}

/// Two relay threads can send output. The lock covers the entire frame, not
/// individual writes. A partial/failed write permanently disables this sender.
/// Backpressure blocks at most one frame per relay; no unbounded task queue.
final class MCPWorkerControlWriter: @unchecked Sendable {
    private let descriptor: MCPWorkerFD
    private let lock = NSLock()
    private var failed = false
    init(fileDescriptor: Int32) throws {
        descriptor = try MCPWorkerFD(duplicating: fileDescriptor)
        try descriptor.nonblocking()
        var yes: Int32 = 1
        guard setsockopt(descriptor.value, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw MCPWorkerLaunchError.descriptors
        }
    }
    func send(_ message: MCPWorkerWire.ServerMessage) throws {
        let data = try MCPWorkerWire.encodeServer(message) + Data([10])
        try lock.withLock {
            guard !failed else { throw MCPStdioError.closed }
            do {
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(descriptor.value, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count > 0 { offset += count; continue }
                        if count < 0, errno == EINTR { continue }
                        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                            var item = pollfd(fd: descriptor.value, events: Int16(POLLOUT), revents: 0)
                            // The parent owns the invocation deadline/cancellation;
                            // its supervisor also kills a blocked writer on lease EOF.
                            let status = poll(&item, 1, 50)
                            if status >= 0 || errno == EINTR { continue }
                        }
                        throw MCPStdioError.closed
                    }
                }
            } catch { failed = true; throw error }
        }
    }
}

private enum MCPPersistentWorkerContext {
    static func parent(_ key: String, environment: [String: String]) throws -> pid_t {
        guard environment[MCPWorkerContext.directKey] == "1",
              let image = environment[MCPWorkerContext.imageKey], !image.isEmpty,
              let text = environment[key], let pid = Int32(text), pid > 1, String(pid) == text else {
            throw ValidationError("This command is an internal MCP worker")
        }
        return pid
    }
}

struct MCPSupervisorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__mcp-supervise", shouldDisplay: false)
    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let parent = try MCPPersistentWorkerContext.parent(MCPWorkerSupervisor.parentKey, environment: environment)
        try MCPWorkerSupervisor.run(executable: MCPWorkerContext.executableURL(), arguments: ["__mcp-worker"],
                                    environment: environment, expectedParent: parent)
    }
}

struct MCPPersistentWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__mcp-worker", shouldDisplay: false)
    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let supervisor = try MCPPersistentWorkerContext.parent(MCPWorkerSupervisor.workerParentKey, environment: environment)
        guard getppid() == supervisor, getpgrp() == supervisor else { throw MCPWorkerLaunchError.supervisorContext }
        var metadata = stat()
        let flags = fcntl(3, F_GETFD)
        guard fstat(3, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK,
              flags >= 0, fcntl(3, F_SETFD, flags | FD_CLOEXEC) == 0 else { throw MCPWorkerLaunchError.descriptors }
        defer { Darwin.close(3) }
        let executable = try MCPWorkerContext.executableURL()
        let architecture = try MCPExecutableIdentity.currentArchitecture()
        let image = try MCPWorkerContext.currentImageIdentifier()
        let worker = getpid()
        let reader = try MCPStdioReader(fileDescriptor: 3, maximumFrameBytes: MCPWorkerWire.maxClientFrameBytes)
        do {
            let writer = try MCPWorkerControlWriter(fileDescriptor: 3)
            let stdio = try MCPRequestStdio()
            try await MCPPersistentWorkerLoop.run(image: image, workerPID: worker, supervisorPID: supervisor,
                next: { try await reader.next() }, send: { try writer.send($0) },
                execute: { arguments, input, output in
                    try await stdio.capture(input: input, output: output) {
                        await CLIExecution.execute(arguments: arguments, mode: .persistent, environment: environment)
                    }
                }, validateImage: {
                    try MCPWorkerContext.validate(environment: environment, currentImage: MCPWorkerContext.currentImageIdentifier)
                    guard try MCPExecutableIdentity.readImage(at: executable, architecture: architecture) == image else {
                        throw MCPWorkerContext.imageChangedError
                    }
                }, onlyOwnedProcesses: {
                    getppid() == supervisor && getpgrp() == supervisor
                        && MCPWorkerGroup.containsOnly(group: supervisor, allowed: [supervisor, worker])
                }, axIsQuiescent: { BoundedAXWorker.shared.isQuiescent })
            await reader.close()
        } catch {
            await reader.close()
            throw error
        }
    }
}
