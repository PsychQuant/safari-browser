import Foundation
import Darwin

// Compiled with the production launch/supervisor sources. No test-only signal
// or lease-monitor implementation: this exercises the actual ownership primitive.
@main struct SupervisorFixture {
    static func main() {
        do { try run() }
        catch { _exit(86) }
    }

    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "supervisor" {
            if args.last == "ignore-term" { signal(SIGTERM, SIG_IGN) }
            let configuredParent = Int32(ProcessInfo.processInfo.environment[MCPWorkerSupervisor.parentKey] ?? "") ?? -1
            let expectedParent = args.last == "invalid-parent" ? -1 : args.last == "wrong-parent" ? configuredParent + 1 : configuredParent
            try MCPWorkerSupervisor.run(
                executable: URL(fileURLWithPath: CommandLine.arguments[0]),
                arguments: Array(args.dropFirst()), environment: ProcessInfo.processInfo.environment,
                expectedParent: expectedParent)
        } else if args.first == "closed-stdio-owner" {
            for fd: Int32 in [0, 1, 2] { Darwin.close(fd) }
            let pair = try MCPWorkerPair.launch(executable: URL(fileURLWithPath: CommandLine.arguments[0]),
                arguments: ["supervisor", "worker", "wait"], environment: ProcessInfo.processInfo.environment)
            defer { _ = pair.child.retire() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !data.contains(10), ProcessInfo.processInfo.systemUptime < deadline {
                var item = pollfd(fd: pair.control, events: Int16(POLLIN), revents: 0)
                if poll(&item, 1, 10) <= 0 { continue }
                let count = Darwin.read(pair.control, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            _ = data.withUnsafeBytes { Darwin.write(3, $0.baseAddress, $0.count) }
        } else if args.first == "controller" {
            signal(SIGTERM, SIG_IGN)
            let ready = Data("ready".utf8)
            _ = ready.withUnsafeBytes { Darwin.write(4, $0.baseAddress!, $0.count) }
            while true { pause() }
        } else if args.first == "descendant" {
            while true { pause() }
        } else if args.first == "worker" {
            let mode = args.dropFirst().first ?? "wait"
            var fd4 = stat(), fd5 = stat()
            var report: [String: Int32] = ["pid": getpid(), "ppid": getppid(), "group": getpgrp(),
                                          "fd4Open": fstat(4, &fd4) == 0 ? 1 : 0,
                                          "fd5Open": fstat(5, &fd5) == 0 ? 1 : 0]
            if mode == "stop-descendant" {
                let descendant = try MCPWorkerSpawn.child(executable: URL(fileURLWithPath: CommandLine.arguments[0]),
                    arguments: ["descendant"], environment: ProcessInfo.processInfo.environment,
                    descriptors: [0: 0, 1: 1, 2: 2], group: .inherit)
                report["descendant"] = descendant.pid
            }
            let data = try JSONSerialization.data(withJSONObject: report)
            _ = (data + Data([10])).withUnsafeBytes { Darwin.write(3, $0.baseAddress!, $0.count) }
            if mode == "close-bootstrap" { for fd: Int32 in [0, 1, 2] { Darwin.close(fd) } }
            if mode == "exit" { exit(23) }
            if mode == "stop" || mode == "stop-descendant" { raise(SIGSTOP) }
            while true { pause() }
        } else { exit(90) }
    }
}
