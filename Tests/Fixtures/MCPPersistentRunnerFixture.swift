import Foundation
import Darwin

@main struct RunnerFixture {
    static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw MCPWorkerLaunchError.status }
                offset += count
            }
        }
    }
    static func send(_ frame: MCPWorkerWire.ServerMessage) throws { try write(3, MCPWorkerWire.encodeServer(frame) + Data([10])) }
    static func appendMarker(_ path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw MCPWorkerLaunchError.status }
        defer { Darwin.close(fd) }
        try write(fd, Data("effect\n".utf8))
    }
    static func main() {
        do { try run() } catch { _exit(86) }
    }
    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let environment = ProcessInfo.processInfo.environment
        if args.first == "supervisor" {
            try MCPWorkerSupervisor.run(executable: URL(fileURLWithPath: CommandLine.arguments[0]), arguments: ["worker"],
                environment: environment, expectedParent: Int32(environment[MCPWorkerSupervisor.parentKey] ?? "") ?? -1)
        }
        if args.first == "__mcp-exec" {
            // Owned fixture for cancellation after large-argv preselection.
            if args.count > 2, args[1] == "block" { try appendMarker(args[2]); while true { pause() } }
            try write(1, Data("isolated\n".utf8)); return
        }
        guard args.first == "worker" else { _exit(89) }
        for fd: Int32 in [0, 1, 2] { Darwin.close(fd) }
        try send(.hello(image: environment["SAFARI_BROWSER_MCP_IMAGE_ID"] ?? "", workerPID: getpid(), supervisorPID: getppid()))
        var buffer = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            while !buffer.contains(10) {
                let count = Darwin.read(3, &bytes, bytes.count)
                if count == 0 { return }
                if count < 0 { if errno == EINTR { continue }; throw MCPWorkerLaunchError.status }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= MCPWorkerWire.maxClientFrameBytes + 1 else { throw MCPWorkerWire.WireError.invalidFrame }
            }
            let end = buffer.firstIndex(of: 10)!
            let data = Data(buffer[..<end]); buffer.removeSubrange(...end)
            switch try MCPWorkerWire.decodeClient(data) {
            case .shutdown: return
            case .request(let id, let args, _):
                let mode = args.first ?? "ok"
                if mode.hasPrefix("effect-") {
                    try appendMarker(args[1])
                    try send(.output(id: id, stream: .stdout, bytes: Data("prefix".utf8)))
                    switch mode {
                    case "effect-crash": _exit(73)
                    case "effect-partial": try write(3, Data("{\"kind\":\"complete\"".utf8)); return
                    case "effect-wrong-id": try send(.complete(id: UUID(), exitCode: 0, reusable: true)); while true { pause() }
                    case "effect-oversized-frame": try write(3, Data(repeating: 32, count: 65537)); while true { pause() }
                    default: try send(.retire(id: id, reason: .scope, exitCode: 17)); while true { pause() }
                    }
                }
                if mode == "flood-stdout" || mode == "flood-stderr" {
                    for _ in 0..<100 { try send(.output(id: id, stream: mode == "flood-stdout" ? .stdout : .stderr, bytes: Data(repeating: 65, count: 8192))) }
                    while true { pause() }
                }
                if mode == "exact-limit" {
                    try send(.output(id: id, stream: .stdout, bytes: Data(repeating: 65, count: 1024)))
                    try send(.complete(id: id, exitCode: 0, reusable: true)); continue
                }
                if mode == "complete-exit" { try send(.complete(id: id, exitCode: 17, reusable: false)); return }
                if mode == "complete-trailing" {
                    try write(3, MCPWorkerWire.encodeServer(.complete(id: id, exitCode: 0, reusable: false)) + Data("\n{bad\n".utf8))
                    return
                }
                try send(.output(id: id, stream: .stdout, bytes: Data(String(getpid()).utf8)))
                try send(.complete(id: id, exitCode: 0, reusable: true))
                if mode == "close-idle" {
                    while !FileManager.default.fileExists(atPath: args[1]) { usleep(1000) }
                    _ = Darwin.shutdown(3, SHUT_WR)
                    try Data("ready".utf8).write(to: URL(fileURLWithPath: args[2]))
                    while true { pause() }
                }
            }
        }
    }
}
