import Foundation
import Darwin

/// Fixed diagnostics: neither argv nor environment data belong in launch errors.
enum MCPWorkerLaunchError: Error, LocalizedError {
    case invalidConfiguration, descriptors, spawn, ownershipLost, status, supervisorContext
    case spawnSystemError(Int32)
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Invalid private worker launch configuration."
        case .descriptors: "Private worker descriptors could not be prepared."
        case .spawn: "Private worker could not be launched."
        case .spawnSystemError(let code): "Private worker launch failed: \(String(cString: strerror(code)))."
        case .ownershipLost: "Private worker ownership was lost before cleanup."
        case .status: "Private worker status could not be observed."
        case .supervisorContext: "Invalid private worker supervisor context."
        }
    }
}

/// One serial I/O owner must retain this object until retirement is confirmed.
/// In particular, a cleanup timeout does not release the PID reservation.
final class MCPChildReservation {
    enum Observation: Equatable { case running, exited }
    enum Retirement: Equatable { case reaped(Int32), pending, ownershipLost }
    let pid: pid_t
    private let group: Bool
    private var terminal: Retirement?
    private var stopStarted: TimeInterval?
    private var killSent = false

    // Only a successful local spawn can create signal authority.
    fileprivate init(pid: pid_t, group: Bool) { self.pid = pid; self.group = group }

    func observe() throws -> Observation {
        if let terminal {
            if case .reaped = terminal { return .exited }
            throw MCPWorkerLaunchError.ownershipLost
        }
        var info = siginfo_t()
        var result: Int32
        repeat { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) }
        while result < 0 && errno == EINTR
        if result < 0 {
            if errno == ECHILD {
                terminal = .ownershipLost
                throw MCPWorkerLaunchError.ownershipLost
            }
            throw MCPWorkerLaunchError.status
        }
        // Darwin can report CLD_STOPPED even with WEXITED here. A PID alone
        // is not proof of exit; retain the grace period for stopped children.
        let exited = info.si_pid == pid && [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(info.si_code)
        return exited ? .exited : .running
    }

    private var groupIsQuiescent: Bool {
        !group || MCPWorkerGroup.containsOnly(group: pid, allowed: [pid], allowZombies: true)
    }

    /// Sends the final group signal *before* releasing the direct child's PID.
    /// All waits use WNOHANG. A later call continues an unfinished retirement.
    func retire(timeout: TimeInterval = 2) -> Retirement {
        if let terminal { return terminal }
        guard timeout.isFinite, timeout >= 0, timeout <= 60 else { return .pending }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var firstTurn = true
        repeat {
            if !firstTurn, ProcessInfo.processInfo.systemUptime >= deadline { return .pending }
            firstTurn = false
            let observation: Observation
            do { observation = try observe() }
            catch {
                if let terminal { return terminal }
                return .pending // Cannot confirm authority: do not signal blindly.
            }
            let now = ProcessInfo.processInfo.systemUptime
            let target = group ? -pid : pid
            if observation == .exited || (stopStarted.map { now - $0 >= 0.15 } ?? false) {
                // Fork/group-membership changes can finish after the first
                // signal. Keep killing live members while this leader is reserved.
                if !killSent || !groupIsQuiescent {
                    // Darwin may return EPERM when only zombies remain.
                    // A group snapshot, not that errno, proves retirement.
                    let result = kill(target, SIGKILL)
                    killSent = result == 0 || errno == ESRCH
                    if !killSent, observation == .exited, groupIsQuiescent { killSent = true }
                }
            } else if stopStarted == nil {
                _ = kill(target, SIGTERM)
                stopStarted = now
            }
            if observation == .exited, killSent, groupIsQuiescent {
                var status: Int32 = 0
                var reaped: pid_t
                repeat { reaped = waitpid(pid, &status, WNOHANG) } while reaped < 0 && errno == EINTR
                if reaped == pid { terminal = .reaped(status); return terminal! }
                if reaped < 0, errno == ECHILD { terminal = .ownershipLost; return terminal! }
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { return .pending }
            usleep(5_000)
        } while true
    }
}

/// Fail closed if the bounded snapshot is full or a member cannot be inspected.
/// PID membership is read-only evidence, never new signal authority.
enum MCPWorkerGroup {
    static func containsOnly(group: pid_t, allowed: Set<pid_t>, allowZombies: Bool = false) -> Bool {
        guard group > 1 else { return false }
        var members = [pid_t](repeating: 0, count: 4096)
        let capacity = Int32(members.count * MemoryLayout<pid_t>.size)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &members, capacity)
        guard bytes >= 0, bytes < capacity, bytes % Int32(MemoryLayout<pid_t>.size) == 0 else { return false }
        for member in members.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where member > 0 && !allowed.contains(member) {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let amount = proc_pidinfo(member, PROC_PIDTBSDINFO, 0, &info, size)
            if amount == 0, errno == ESRCH { continue }
            guard amount == size else { return false }
            if info.pbi_pgid != UInt32(group) { continue }
            if allowZombies, info.pbi_status == SZOMB { continue }
            return false
        }
        return true
    }
}

/// Each descriptor has a single I/O owner, including when moved into a relay.
/// Descriptors always live above all six inherited slots, even if caller stdio
/// is closed. RAII closes only locally owned copies, never borrowed descriptors.
final class MCPWorkerFD: @unchecked Sendable {
    private(set) var value: Int32
    init(duplicating descriptor: Int32) throws {
        value = fcntl(descriptor, F_DUPFD_CLOEXEC, 6)
        guard value >= 6 else { throw MCPWorkerLaunchError.descriptors }
    }
    deinit { close() }
    func close() { if value >= 0 { Darwin.close(value); value = -1 } }
    static func pipePair() throws -> (MCPWorkerFD, MCPWorkerFD) {
        var pair: [Int32] = [-1, -1]
        guard pipe(&pair) == 0 else { throw MCPWorkerLaunchError.descriptors }
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        return try (MCPWorkerFD(duplicating: pair[0]), MCPWorkerFD(duplicating: pair[1]))
    }
    static func socketPair() throws -> (MCPWorkerFD, MCPWorkerFD) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw MCPWorkerLaunchError.descriptors }
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        for descriptor in pair {
            var yes: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw MCPWorkerLaunchError.descriptors
            }
        }
        return try (MCPWorkerFD(duplicating: pair[0]), MCPWorkerFD(duplicating: pair[1]))
    }
    func nonblocking() throws {
        let flags = fcntl(value, F_GETFL)
        guard flags >= 0, fcntl(value, F_SETFL, flags | O_NONBLOCK) == 0 else { throw MCPWorkerLaunchError.descriptors }
    }
}

enum MCPWorkerSpawn {
    enum Group { case create, inherit }

    /// `descriptors` maps inherited target slots to borrowed source descriptors.
    /// All sources are duplicated before constructing any dup2/close action.
    static func child(executable: URL, arguments: [String], environment: [String: String],
                      descriptors: [Int32: Int32], group: Group = .create, deadline: TimeInterval? = nil, argument0: String? = nil) throws -> MCPChildReservation {
        let argv = [argument0 ?? executable.path] + arguments
        guard executable.isFileURL, !executable.path.isEmpty,
              argv.allSatisfy({ !$0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }),
              descriptors.keys.allSatisfy({ (0...5).contains($0) }) else { throw MCPWorkerLaunchError.invalidConfiguration }
        let owned = try descriptors.sorted(by: { $0.key < $1.key }).map { (target: $0.key, source: try MCPWorkerFD(duplicating: $0.value)) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw MCPWorkerLaunchError.spawn }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw MCPWorkerLaunchError.spawn }
        defer { posix_spawnattr_destroy(&attributes) }
        var error: Int32 = 0
        for mapping in owned {
            error |= posix_spawn_file_actions_adddup2(&actions, mapping.source.value, mapping.target)
            error |= posix_spawn_file_actions_addclose(&actions, mapping.source.value)
        }
        var emptyMask = sigset_t(), defaults = sigset_t()
        sigemptyset(&emptyMask); sigemptyset(&defaults)
        for number in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGCHLD] { sigaddset(&defaults, number) }
        error |= posix_spawnattr_setsigmask(&attributes, &emptyMask)
        error |= posix_spawnattr_setsigdefault(&attributes, &defaults)
        var flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        if group == .create {
            flags |= Int16(POSIX_SPAWN_SETPGROUP)
            error |= posix_spawnattr_setpgroup(&attributes, 0)
        }
        error |= posix_spawnattr_setflags(&attributes, flags)
        guard error == 0 else { throw MCPWorkerLaunchError.spawn }
        let argvPointers = argv.map { strdup($0) } + [nil]
        let envPointers = environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argvPointers + envPointers { free(pointer) } }
        guard argvPointers.dropLast().allSatisfy({ $0 != nil }), envPointers.dropLast().allSatisfy({ $0 != nil }) else {
            throw MCPWorkerLaunchError.spawn
        }
        if let deadline {
            guard deadline.isFinite, ProcessInfo.processInfo.systemUptime < deadline else { throw MCPWorkerLaunchError.invalidConfiguration }
        }
        var pid: pid_t = 0
        let result = argvPointers.withUnsafeBufferPointer { argv in
            envPointers.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, executable.path, &actions, &attributes, argv.baseAddress!, environment.baseAddress!)
            }
        }
        guard result == 0 else { throw MCPWorkerLaunchError.spawnSystemError(result) }
        guard pid > 0 else { throw MCPWorkerLaunchError.spawn }
        // Keep the copies alive until posix_spawn has consumed its actions.
        withExtendedLifetime(owned) {}
        return MCPChildReservation(pid: pid, group: group == .create)
    }
}

final class MCPWorkerPair {
    let child: MCPChildReservation
    private let controlFD: MCPWorkerFD
    private let statusFD: MCPWorkerFD
    private let diagnosticsFD: MCPWorkerFD
    private let lifetimeFD: MCPWorkerFD
    var control: Int32 { controlFD.value }
    var status: Int32 { statusFD.value }
    var diagnostics: Int32 { diagnosticsFD.value }
    var lifetimeWriter: Int32 { lifetimeFD.value }

    private init(child: MCPChildReservation, control: MCPWorkerFD, status: MCPWorkerFD,
                 diagnostics: MCPWorkerFD, lifetime: MCPWorkerFD) {
        self.child = child; controlFD = control; statusFD = status
        diagnosticsFD = diagnostics; lifetimeFD = lifetime
    }

    static func launch(executable: URL, arguments: [String], environment: [String: String]) throws -> MCPWorkerPair {
        let (hostControl, workerControl) = try MCPWorkerFD.socketPair()
        let (leaseRead, leaseWrite) = try MCPWorkerFD.pipePair()
        let (statusRead, statusWrite) = try MCPWorkerFD.pipePair()
        let (diagnosticsRead, diagnosticsWrite) = try MCPWorkerFD.pipePair()
        let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard null >= 0 else { throw MCPWorkerLaunchError.descriptors }
        defer { Darwin.close(null) }
        for descriptor in [hostControl, statusRead, diagnosticsRead] { try descriptor.nonblocking() }
        var childEnvironment = environment
        childEnvironment[MCPWorkerSupervisor.parentKey] = String(getpid())
        let child = try MCPWorkerSpawn.child(executable: executable, arguments: arguments, environment: childEnvironment,
            descriptors: [0: null, 1: diagnosticsWrite.value, 2: diagnosticsWrite.value,
                          3: workerControl.value, 4: leaseRead.value, 5: statusWrite.value])
        return MCPWorkerPair(child: child, control: hostControl, status: statusRead,
                             diagnostics: diagnosticsRead, lifetime: leaseWrite)
    }

    func closeLifetime() { lifetimeFD.close() }
    func closeChannels() { controlFD.close(); statusFD.close(); diagnosticsFD.close(); lifetimeFD.close() }
}

enum MCPWorkerSupervisor {
    static let parentKey = "SAFARI_BROWSER_MCP_SUPERVISOR_PARENT"
    static let workerParentKey = "SAFARI_BROWSER_MCP_WORKER_PARENT"

    /// Called only in the fresh supervisor. The EOF monitor has its own dispatch
    /// thread; it does not depend on the CLI worker running or acknowledging.
    static func run(executable: URL, arguments: [String], environment: [String: String], expectedParent: pid_t) throws -> Never {
        guard expectedParent > 1, getppid() == expectedParent, getpid() == getpgrp() else {
            throw MCPWorkerLaunchError.supervisorContext
        }
        for (descriptor, kind) in [(Int32(3), mode_t(S_IFSOCK)), (4, mode_t(S_IFIFO)), (5, mode_t(S_IFIFO))] {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == kind else {
                throw MCPWorkerLaunchError.supervisorContext
            }
        }
        let flags = fcntl(4, F_GETFL)
        guard flags >= 0, fcntl(4, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(5, F_SETNOSIGPIPE, 1) == 0 else { throw MCPWorkerLaunchError.descriptors }
        let ownGroup = getpid()
        let monitor = DispatchSource.makeReadSource(fileDescriptor: 4, queue: DispatchQueue(label: "mcp.supervisor.lease"))
        monitor.setEventHandler {
            var byte: UInt8 = 0
            let amount = Darwin.read(4, &byte, 1)
            if amount < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
            // EOF, an invalid lease write, or a broken descriptor all retire.
            // This process remains its group's live leader until this signal.
            _ = kill(-ownGroup, SIGKILL)
            _exit(125)
        }
        monitor.resume()
        var childEnvironment = environment
        childEnvironment.removeValue(forKey: parentKey)
        childEnvironment[workerParentKey] = String(ownGroup)
        do {
            let worker = try MCPWorkerSpawn.child(executable: executable, arguments: arguments, environment: childEnvironment,
                                                  descriptors: [0: 0, 1: 1, 2: 2, 3: 3], group: .inherit)
            // Worker alone owns control and bootstrap stdio from this point.
            Darwin.close(3)
            for descriptor: Int32 in [0, 1, 2] { Darwin.close(descriptor) }
            var status: Int32 = 0
            var waited: pid_t
            repeat { waited = waitpid(worker.pid, &status, 0) } while waited < 0 && errno == EINTR
            if waited == worker.pid {
                let record = try MCPWorkerWire.TerminationRecord(workerPID: worker.pid, rawWaitStatus: status).encode()
                // The fresh status pipe has room for one atomic 12-byte record.
                // Host disconnect cannot SIGPIPE the supervisor before group cleanup.
                record.withUnsafeBytes { bytes in
                    var result: Int
                    repeat { result = Darwin.write(5, bytes.baseAddress!, bytes.count) } while result < 0 && errno == EINTR
                }
            }
        } catch {
            // Failed startup must also retire children, if any; no caller retry.
        }
        return withExtendedLifetime(monitor) { () -> Never in
            _ = kill(-ownGroup, SIGKILL)
            _exit(125)
        }
    }
}
