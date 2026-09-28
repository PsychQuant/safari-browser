import Foundation
import Darwin

/// The first kernel spawn receives exactly the original argv and environment
/// size. Only the existing one-byte direct-context value changes from 1 to 2.
/// Parent identity and the deadline travel over private inherited descriptors.
enum MCPIsolatedBootstrap {
    static let contextValue = "2"
    private static let magic: UInt32 = 0x53424931
    static let contextBytes = 16
    static let maxEnvironmentBytes = 8 * 1024 * 1024

    static func context(parent: pid_t, deadline: TimeInterval) throws -> Data {
        guard parent > 1, deadline.isFinite, deadline > 0 else { throw MCPWorkerLaunchError.invalidConfiguration }
        var result = Data()
        for number in [magic, UInt32(parent)] {
            var little = number.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        var bits = deadline.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
        return result
    }

    static func decodeContext(_ data: Data) throws -> (parent: pid_t, deadline: TimeInterval) {
        guard data.count == contextBytes else { throw MCPWorkerLaunchError.supervisorContext }
        let marker = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        let parent = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        let bits = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        let deadline = Double(bitPattern: bits)
        guard marker == magic, parent > 1, parent <= UInt32(Int32.max), deadline.isFinite, deadline > 0 else {
            throw MCPWorkerLaunchError.supervisorContext
        }
        return (pid_t(parent), deadline)
    }

    static func run() throws -> Never {
        guard getpid() == getpgrp(), CommandLine.arguments.count > 0,
              ProcessInfo.processInfo.environment[MCPWorkerContext.directKey] == contextValue else {
            throw MCPWorkerLaunchError.supervisorContext
        }
        for descriptor: Int32 in [3, 4, 5] {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else {
                throw MCPWorkerLaunchError.supervisorContext
            }
        }
        // The parent writes this atomic record before spawning and closes its
        // write end after the bounded environment snapshot. Never block a
        // fresh helper on an untrusted partial header.
        let flags = fcntl(3, F_GETFL)
        guard flags >= 0, fcntl(3, F_SETFL, flags | O_NONBLOCK) == 0 else { throw MCPWorkerLaunchError.descriptors }
        var bytes = [UInt8](repeating: 0, count: contextBytes)
        var count: Int
        repeat { count = Darwin.read(3, &bytes, bytes.count) } while count < 0 && errno == EINTR
        guard count == contextBytes else { throw MCPWorkerLaunchError.supervisorContext }
        let context = try decodeContext(Data(bytes.prefix(count)))
        guard getppid() == context.parent else { throw MCPWorkerLaunchError.supervisorContext }
        let leaseFlags = fcntl(4, F_GETFL)
        guard leaseFlags >= 0, fcntl(4, F_SETFL, leaseFlags | O_NONBLOCK) == 0,
              fcntl(5, F_SETNOSIGPIPE, 1) == 0 else { throw MCPWorkerLaunchError.descriptors }
        // The host blocks TERM at process birth, before any runtime thread can
        // receive it. Keep it pending (SIG_IGN would discard cancellation), so
        // the independent lease monitor and the CLI's TERM grace stay alive.
        var mask = sigset_t()
        guard pthread_sigmask(SIG_BLOCK, nil, &mask) == 0, sigismember(&mask, SIGTERM) == 1 else {
            throw MCPWorkerLaunchError.supervisorContext
        }
        let ownGroup = getpid()
        let monitor = DispatchSource.makeReadSource(fileDescriptor: 4, queue: DispatchQueue(label: "mcp.isolated.lease"))
        monitor.setEventHandler {
            var byte: UInt8 = 0
            let amount = Darwin.read(4, &byte, 1)
            if amount < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
            _ = kill(-ownGroup, SIGKILL)
            _exit(125)
        }
        monitor.resume()
        do {
            guard ProcessInfo.processInfo.systemUptime < context.deadline else { throw MCPWorkerLaunchError.invalidConfiguration }
            // Foundation may add __CF_USER_TEXT_ENCODING before main. Use the
            // parent's exact snapshot, not the helper's mutated environment.
            var environmentData = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                try MCPWorkerSpawn.checkPendingTermination()
                guard ProcessInfo.processInfo.systemUptime < context.deadline else { throw MCPWorkerLaunchError.invalidConfiguration }
                let count = Darwin.read(3, &buffer, buffer.count)
                if count == 0 { break }
                if count > 0 {
                    guard environmentData.count <= maxEnvironmentBytes - count else { throw MCPWorkerLaunchError.supervisorContext }
                    environmentData.append(contentsOf: buffer.prefix(count))
                } else if errno == EINTR { continue }
                else if errno == EAGAIN || errno == EWOULDBLOCK {
                    var item = pollfd(fd: 3, events: Int16(POLLIN), revents: 0)
                    _ = poll(&item, 1, 10)
                } else { throw MCPWorkerLaunchError.supervisorContext }
            }
            Darwin.close(3)
            var environment = try JSONDecoder().decode([String: String].self, from: environmentData)
            guard environment[MCPWorkerContext.directKey] == contextValue,
                  environment[MCPWorkerContext.imageKey] != nil else { throw MCPWorkerLaunchError.supervisorContext }
            environment[MCPWorkerContext.directKey] = "1"
            let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            let worker = try MCPWorkerSpawn.child(executable: executable,
                arguments: Array(CommandLine.arguments.dropFirst()), environment: environment,
                descriptors: [0: 0, 1: 1, 2: 2], group: .inherit, deadline: context.deadline,
                rejectPendingTermination: true)
            for descriptor: Int32 in [0, 1, 2] { Darwin.close(descriptor) }
            var status: Int32 = 0
            var waited: pid_t
            repeat { waited = waitpid(worker.pid, &status, 0) } while waited < 0 && errno == EINTR
            if waited == worker.pid {
                let record = try MCPWorkerWire.TerminationRecord(workerPID: worker.pid, rawWaitStatus: status).encode()
                record.withUnsafeBytes { bytes in
                    var amount: Int
                    repeat { amount = Darwin.write(5, bytes.baseAddress!, bytes.count) } while amount < 0 && errno == EINTR
                }
            }
        } catch {
            // No request retry. The host reports missing status as incomplete.
        }
        return withExtendedLifetime(monitor) { () -> Never in
            _ = kill(-ownGroup, SIGKILL)
            _exit(125)
        }
    }
}

/// Host-owned endpoints for a single isolated supervisor launch.
final class MCPIsolatedChannels {
    let metadata: MCPWorkerFD
    private let metadataWrite: MCPWorkerFD
    private let environmentData: Data
    private var environmentOffset = 0
    let leaseRead: MCPWorkerFD
    let leaseWrite: MCPWorkerFD
    let statusRead: MCPWorkerFD
    let statusWrite: MCPWorkerFD

    init(deadline: TimeInterval, environment: [String: String]) throws {
        environmentData = try JSONEncoder().encode(environment)
        guard environmentData.count <= MCPIsolatedBootstrap.maxEnvironmentBytes else { throw MCPWorkerLaunchError.invalidConfiguration }
        (metadata, metadataWrite) = try MCPWorkerFD.pipePair()
        (leaseRead, leaseWrite) = try MCPWorkerFD.pipePair()
        (statusRead, statusWrite) = try MCPWorkerFD.pipePair()
        try statusRead.nonblocking()
        let data = try MCPIsolatedBootstrap.context(parent: getpid(), deadline: deadline)
        let count = data.withUnsafeBytes { Darwin.write(metadataWrite.value, $0.baseAddress!, $0.count) }
        guard count == data.count else { throw MCPWorkerLaunchError.descriptors }
        try metadataWrite.nonblocking()
        guard fcntl(metadataWrite.value, F_SETNOSIGPIPE, 1) == 0 else { throw MCPWorkerLaunchError.descriptors }
    }

    /// Called by the same host I/O owner that handles timeout and stdio. Never
    /// block on a full metadata pipe while the helper is starting.
    func pumpEnvironment() throws {
        guard metadataWrite.value >= 0 else { return }
        let count = environmentData.withUnsafeBytes { bytes in
            Darwin.write(metadataWrite.value, bytes.baseAddress!.advanced(by: environmentOffset), min(16384, bytes.count - environmentOffset))
        }
        if count > 0 {
            environmentOffset += count
            if environmentOffset == environmentData.count { metadataWrite.close() }
        } else if count < 0, errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
            throw MCPWorkerLaunchError.descriptors
        }
    }

    var pendingMetadataDescriptor: Int32? { metadataWrite.value >= 0 ? metadataWrite.value : nil }

    func didSpawn() { metadata.close(); leaseRead.close(); statusWrite.close() }

    func termination() throws -> MCPWorkerWire.TerminationRecord {
        var bytes = [UInt8](repeating: 0, count: MCPWorkerWire.TerminationRecord.byteCount + 1)
        var count: Int
        repeat { count = Darwin.read(statusRead.value, &bytes, bytes.count) } while count < 0 && errno == EINTR
        guard count == MCPWorkerWire.TerminationRecord.byteCount else { throw MCPWorkerLaunchError.status }
        return try MCPWorkerWire.TerminationRecord.decode(Data(bytes.prefix(count)))
    }
}
