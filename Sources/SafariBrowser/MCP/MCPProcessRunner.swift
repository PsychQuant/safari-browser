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
}

struct MCPProcessRunner: MCPCommandRunning {
    let executable: URL
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var workerPrefix: [String] = ["__mcp-exec"]
    var timeout: TimeInterval = 300
    var outputLimit: Int = 2 * 1024 * 1024
    var inputLimit: Int = 4 * 1024 * 1024

    func run(arguments: [String], input: Data, expectedImage: String) async -> MCPCommandResult {
        let cancellation = MCPCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: execute(arguments: arguments, input: input, expectedImage: expectedImage, cancellation: cancellation))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(arguments: [String], input: Data, expectedImage: String, cancellation: MCPCancellation) -> MCPCommandResult {
        var result = MCPCommandResult()
        guard timeout.isFinite, timeout >= 0.001, timeout <= 86400, outputLimit > 0, inputLimit >= 0 else {
            result.failure = "Invalid worker limits."
            return result
        }
        guard input.count <= inputLimit else {
            result.failure = "Worker stdin exceeds the input limit; command was not executed."
            return result
        }
        var childEnvironment = environment
        childEnvironment["SAFARI_BROWSER_MCP_DIRECT"] = "1"
        childEnvironment["SAFARI_BROWSER_MCP_IMAGE_ID"] = expectedImage
        let argv = [executable.path] + workerPrefix + arguments
        guard argv.allSatisfy({ !$0.utf8.contains(0) }),
              childEnvironment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            result.failure = "Worker argv or environment contains an invalid string; command was not executed."
            return result
        }
        if cancellation.isCancelled {
            result.cancelled = true
            result.failure = "Command cancelled before execution."
            return result
        }

        // Reserve descriptors above stdio and make all unused ends close-on-exec.
        var descriptors: [Int32] = []
        defer { for fd in descriptors where fd >= 0 { Darwin.close(fd) } }
        for _ in 0..<3 {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else {
                result.failure = "Worker pipe creation failed: \(String(cString: strerror(errno)))."
                return result
            }
            for original in pair {
                let owned = fcntl(original, F_DUPFD_CLOEXEC, 3)
                let savedError = errno
                Darwin.close(original)
                if owned < 0 {
                    // The remaining original pipe end has not yet been closed.
                    if original == pair[0] { Darwin.close(pair[1]) }
                    result.failure = "Worker pipe descriptor failed: \(String(cString: strerror(savedError)))."
                    return result
                }
                descriptors.append(owned)
            }
        }
        // stdin read/write, stdout read/write, stderr read/write.
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            result.failure = "Worker spawn actions could not be initialized."
            return result
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            result.failure = "Worker spawn attributes could not be initialized."
            return result
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var setupError = posix_spawn_file_actions_adddup2(&actions, descriptors[0], STDIN_FILENO)
        setupError |= posix_spawn_file_actions_adddup2(&actions, descriptors[3], STDOUT_FILENO)
        setupError |= posix_spawn_file_actions_adddup2(&actions, descriptors[5], STDERR_FILENO)
        for fd in descriptors { setupError |= posix_spawn_file_actions_addclose(&actions, fd) }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGPIPE)
        setupError |= posix_spawnattr_setsigmask(&attributes, &emptyMask)
        setupError |= posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        setupError |= posix_spawnattr_setpgroup(&attributes, 0)
        setupError |= posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        // Parent pipe writes must not raise SIGPIPE; this does not change global signal state.
        for index in [1, 2, 4] {
            let fd = descriptors[index]
            let flags = fcntl(fd, F_GETFL)
            if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 { setupError |= 1 }
        }
        if fcntl(descriptors[1], F_SETNOSIGPIPE, 1) < 0 { setupError |= 1 }
        guard setupError == 0 else {
            result.failure = "Worker pipe or process-group configuration failed."
            return result
        }
        let argvPointers = argv.map { strdup($0) } + [nil]
        let envPointers = childEnvironment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argvPointers { free(pointer) }
            for pointer in envPointers { free(pointer) }
        }
        guard argvPointers.dropLast().allSatisfy({ $0 != nil }), envPointers.dropLast().allSatisfy({ $0 != nil }) else {
            result.failure = "Worker argument allocation failed."
            return result
        }
        var pid: pid_t = 0
        let spawnError = argvPointers.withUnsafeBufferPointer { argvBuffer in
            envPointers.withUnsafeBufferPointer { envBuffer in
                posix_spawn(&pid, executable.path, &actions, &attributes, argvBuffer.baseAddress!, envBuffer.baseAddress!)
            }
        }
        guard spawnError == 0 else {
            result.failure = "Worker launch failed: \(String(cString: strerror(spawnError)))."
            return result
        }
        func closeDescriptor(_ index: Int) {
            if descriptors[index] >= 0 { Darwin.close(descriptors[index]); descriptors[index] = -1 }
        }
        for index in [0, 3, 5] { closeDescriptor(index) }
        let start = ProcessInfo.processInfo.systemUptime
        var stoppedAt: TimeInterval?
        var killed = false
        var killedAt: TimeInterval?
        var reservationLost = false
        var leaderExited = false
        var inputOffset = 0
        var buffer = [UInt8](repeating: 0, count: 8192)
        if input.isEmpty { closeDescriptor(1) }
        func stop(_ reason: String) {
            if result.failure == nil { result.failure = reason }
            if stoppedAt == nil {
                stoppedAt = ProcessInfo.processInfo.systemUptime
                kill(-pid, SIGTERM)
                closeDescriptor(1)
            }
        }

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if cancellation.isCancelled {
                result.cancelled = true
                stop("Command cancelled; earlier side effects may already have occurred.")
            }
            if now - start >= timeout { stop("Command timed out; earlier side effects may already have occurred.") }
            if let stoppedAt, now - stoppedAt >= 0.15, !killed {
                kill(-pid, SIGKILL)
                killed = true
                killedAt = now
            }
            // WNOWAIT keeps the leader (and therefore its process-group ID) reserved
            // until all signals and pipe cleanup finish. No delayed signal follows waitpid.
            if !leaderExited {
                var info = siginfo_t()
                let waitResult = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if waitResult == 0, info.si_pid == pid { leaderExited = true }
                else if waitResult < 0, errno != EINTR {
                    // If another reaper violated ownership, the PID is no longer
                    // reserved. Never signal a potentially reused group ID.
                    if errno == ECHILD {
                        reservationLost = true
                        result.failure = "Worker ownership was lost before cleanup."
                        break
                    }
                    stop("Worker status could not be read.")
                }
            }
            if leaderExited, !killed {
                // A returned command does not leave inherited workers behind. Detached
                // daemon services have their own group and are deliberately unaffected.
                kill(-pid, SIGKILL)
                killed = true
                killedAt = now
                closeDescriptor(1)
            }
            for index in [2, 4] where descriptors[index] >= 0 {
                // Bound each drain turn so a producer cannot starve cancellation/stdin.
                for _ in 0..<32 {
                    let count = Darwin.read(descriptors[index], &buffer, buffer.count)
                    if count > 0 {
                        let existing = index == 2 ? result.stdout.count : result.stderr.count
                        let retained = min(count, outputLimit - existing)
                        if index == 2 { result.stdout.append(contentsOf: buffer.prefix(retained)) }
                        else { result.stderr.append(contentsOf: buffer.prefix(retained)) }
                        if retained < count {
                            result.truncated = true
                            stop("Worker output exceeded the capture limit; output is incomplete.")
                        }
                    } else if count == 0 { closeDescriptor(index); break }
                    else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else if errno != EINTR {
                        stop("Worker output could not be read; output is incomplete.")
                        closeDescriptor(index)
                        break
                    }
                }
            }
            if descriptors[1] >= 0 {
                let written = input.withUnsafeBytes { bytes in
                    Darwin.write(descriptors[1], bytes.baseAddress!.advanced(by: inputOffset), min(16384, input.count - inputOffset))
                }
                if written > 0 {
                    inputOffset += written
                    if inputOffset == input.count { closeDescriptor(1) }
                } else if written < 0, errno == EPIPE { closeDescriptor(1) }
                else if written < 0, errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                    stop("Worker stdin could not be delivered.")
                }
            }
            if leaderExited, descriptors[2] < 0, descriptors[4] < 0 { break }
            // Escaped descendants could retain a pipe. They are outside the owned
            // process group: bound cleanup and report incomplete capture explicitly.
            if let killedAt, now - killedAt > 1 {
                result.failure = result.failure ?? "Worker output remained open after termination; capture is incomplete."
                closeDescriptor(2)
                closeDescriptor(4)
                if leaderExited { break }
            }
            var pollItems: [pollfd] = []
            for index in [2, 4] where descriptors[index] >= 0 { pollItems.append(pollfd(fd: descriptors[index], events: Int16(POLLIN), revents: 0)) }
            if descriptors[1] >= 0 { pollItems.append(pollfd(fd: descriptors[1], events: Int16(POLLOUT), revents: 0)) }
            _ = poll(&pollItems, nfds_t(pollItems.count), 10)
        }
        // Last group signal happens while the child is still reserved. Reap once.
        if reservationLost { return result }
        if !killed { kill(-pid, SIGKILL) }
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited < 0 && errno == EINTR
        if waited == pid {
            let signal = status & 0x7f
            if signal == 0 { result.exitCode = (status >> 8) & 0xff }
            else {
                result.exitCode = 128 + signal
                result.failure = result.failure ?? "Worker terminated by signal \(signal); earlier side effects may already have occurred."
            }
        } else { result.failure = result.failure ?? "Worker could not be reaped." }
        return result
    }
}

private final class MCPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
