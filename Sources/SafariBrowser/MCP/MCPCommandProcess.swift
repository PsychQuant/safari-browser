import Foundation
import Darwin

/// Keeps MCP descendants in their parent's owned process group. Foundation's
/// macOS Process launcher creates a new group, which would escape cancellation.
/// Outside MCP, launches and observation still use Foundation Process.
final class MCPCommandProcess: @unchecked Sendable {
    var executableURL: URL?
    var arguments: [String]?
    var environment: [String: String]?
    var standardInput: Any? = FileHandle.standardInput
    var standardOutput: Any? = FileHandle.standardOutput
    var standardError: Any? = FileHandle.standardError

    private let useMCPIsolation: Bool
    private let ordinary = Process()
    private let condition = NSCondition()
    private var started = false
    private var childPID: pid_t = 0
    private var running = false
    private var status: Int32 = 0

    init(useMCPIsolation: Bool? = nil) {
        let env = ProcessInfo.processInfo.environment
        self.useMCPIsolation = useMCPIsolation ?? (env[MCPWorkerContext.directKey] == "1" && env[MCPWorkerContext.imageKey] != nil)
    }

    var processIdentifier: Int32 {
        if !useMCPIsolation { return ordinary.processIdentifier }
        condition.lock(); defer { condition.unlock() }
        return childPID
    }

    var terminationStatus: Int32 {
        if !useMCPIsolation { return ordinary.terminationStatus }
        condition.lock(); defer { condition.unlock() }
        return status
    }

    var isRunning: Bool {
        if !useMCPIsolation { return ordinary.isRunning }
        condition.lock(); defer { condition.unlock() }
        return running
    }

    private func failure(_ code: Int32, _ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }

    func run() throws {
        condition.lock(); defer { condition.unlock() }
        guard !started else { throw failure(EINVAL, "A command process can only be launched once") }
        guard let executableURL, executableURL.isFileURL else {
            throw failure(EINVAL, "Command executable must be a local file URL")
        }
        let streams = [standardInput, standardOutput, standardError]
        guard streams.allSatisfy({ $0 == nil || $0 is Pipe || $0 is FileHandle }) else {
            throw failure(EINVAL, "Command streams must be Pipe, FileHandle or nil")
        }
        if !useMCPIsolation {
            ordinary.executableURL = executableURL
            ordinary.arguments = arguments
            ordinary.environment = environment
            ordinary.standardInput = standardInput
            ordinary.standardOutput = standardOutput
            ordinary.standardError = standardError
            try ordinary.run()
            started = true
            return
        }

        let inherited = ProcessInfo.processInfo.environment
        var childEnvironment = environment ?? inherited
        // Call-site overrides must not silently drop the current worker context.
        for key in [MCPWorkerContext.directKey, MCPWorkerContext.imageKey] {
            if let value = inherited[key] { childEnvironment[key] = value }
        }
        let childArguments = try MCPWorkerContext.subprocessArguments(
            executable: executableURL, arguments: arguments ?? [], environment: childEnvironment)
        let argv = [executableURL.path] + childArguments
        guard argv.allSatisfy({ !$0.utf8.contains(0) }), childEnvironment.allSatisfy({
            !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0)
        }) else { throw failure(EINVAL, "Command arguments or environment contain invalid strings") }

        var descriptors: [Int32] = []
        var childPipeEnds: [FileHandle] = []
        defer { for fd in descriptors { Darwin.close(fd) } }
        for (index, stream) in streams.enumerated() {
            let original: Int32
            var ownedOriginal = false
            if let pipe = stream as? Pipe {
                let end = index == 0 ? pipe.fileHandleForReading : pipe.fileHandleForWriting
                original = end.fileDescriptor
                childPipeEnds.append(end)
            } else if let handle = stream as? FileHandle {
                original = handle.fileDescriptor
            } else {
                original = Darwin.open("/dev/null", index == 0 ? O_RDONLY : O_WRONLY)
                ownedOriginal = true
            }
            guard original >= 0 else { throw failure(EBADF, "Command stream descriptor is invalid") }
            let duplicate = fcntl(original, F_DUPFD_CLOEXEC, 3)
            let savedError = errno
            if ownedOriginal { Darwin.close(original) }
            guard duplicate >= 0 else { throw failure(savedError, "Command stream could not be duplicated") }
            descriptors.append(duplicate)
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var error = posix_spawn_file_actions_init(&actions)
        guard error == 0 else { throw failure(error, "Command spawn actions could not be initialized") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        error = posix_spawnattr_init(&attributes)
        guard error == 0 else { throw failure(error, "Command spawn attributes could not be initialized") }
        defer { posix_spawnattr_destroy(&attributes) }
        for (index, fd) in descriptors.enumerated() {
            error = posix_spawn_file_actions_adddup2(&actions, fd, Int32(index))
            guard error == 0 else { throw failure(error, "Command stream could not be configured") }
        }
        for fd in descriptors {
            error = posix_spawn_file_actions_addclose(&actions, fd)
            guard error == 0 else { throw failure(error, "Command descriptor cleanup could not be configured") }
        }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGPIPE)
        error = posix_spawnattr_setsigmask(&attributes, &emptyMask)
        guard error == 0 else { throw failure(error, "Command signal mask could not be configured") }
        error = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        guard error == 0 else { throw failure(error, "Command default signals could not be configured") }
        // Deliberately omit SETPGROUP: the child belongs to the owned group
        // continuously from creation, with no post-launch join race.
        error = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        guard error == 0 else { throw failure(error, "Command spawn flags could not be configured") }
        let argvPointers = argv.map { strdup($0) } + [nil]
        let envPointers = childEnvironment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argvPointers { free(pointer) }
            for pointer in envPointers { free(pointer) }
        }
        guard argvPointers.dropLast().allSatisfy({ $0 != nil }), envPointers.dropLast().allSatisfy({ $0 != nil }) else {
            throw failure(ENOMEM, "Command argument allocation failed")
        }
        var pid: pid_t = 0
        error = argvPointers.withUnsafeBufferPointer { argvBuffer in
            envPointers.withUnsafeBufferPointer { envBuffer in
                posix_spawn(&pid, executableURL.path, &actions, &attributes, argvBuffer.baseAddress!, envBuffer.baseAddress!)
            }
        }
        guard error == 0 else { throw failure(error, "Command launch failed: \(String(cString: strerror(error)))") }
        started = true
        childPID = pid
        running = true
        // Like Foundation, Pipe transfers its child-facing end on successful
        // launch. Borrowed FileHandle objects remain open in the caller.
        for end in childPipeEnds { try? end.close() }
        DispatchQueue.global(qos: .utility).async { self.reap(pid) }
    }

    private func reap(_ pid: pid_t) {
        var info = siginfo_t()
        var observed: Int32
        repeat { observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) }
        while observed < 0 && errno == EINTR
        condition.lock(); defer { condition.unlock() }
        if observed == 0 {
            // The child remains reserved until this lock is acquired. Signals
            // use the same lock, so none can race with PID release by waitpid.
            var waitStatus: Int32 = 0
            var waited: pid_t
            repeat { waited = waitpid(pid, &waitStatus, 0) } while waited < 0 && errno == EINTR
            if waited == pid {
                let signal = waitStatus & 0x7f
                status = signal == 0 ? (waitStatus >> 8) & 0xff : signal
            } else { status = 127 }
        } else { status = 127 }
        running = false
        condition.broadcast()
    }

    func waitUntilExit() {
        if !useMCPIsolation { ordinary.waitUntilExit(); return }
        condition.lock(); defer { condition.unlock() }
        while running { condition.wait() }
    }

    func terminate() {
        if !useMCPIsolation { ordinary.terminate(); return }
        signalOwnedChild(SIGTERM)
    }

    func forceKill() {
        if !useMCPIsolation {
            // Preserve the existing ordinary-CLI watchdog behavior. Foundation
            // has no public force-kill operation or externally lockable reaper.
            if ordinary.isRunning { kill(ordinary.processIdentifier, SIGKILL) }
            return
        }
        signalOwnedChild(SIGKILL)
    }

    private func signalOwnedChild(_ signal: Int32) {
        condition.lock(); defer { condition.unlock() }
        if running { kill(childPID, signal) }
    }
}
