import Foundation
import Darwin

@main struct RequestStdioFixture {
    final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        func send(_ message: MCPWorkerWire.ServerMessage) throws {
            let data = try MCPWorkerWire.encodeServer(message) + Data([10])
            try lock.withLock { try Self.write(3, data) }
        }
        static func write(_ descriptor: Int32, _ bytes: Data) throws {
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw MCPRequestStdioError.setup }
                    offset += count
                }
            }
        }
    }
    static func main() async {
        do { try await run() } catch { _exit(86) }
    }
    static func run() async throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "healthy"
        let wire = Wire()
        let scope = try MCPRequestStdio()
        try wire.send(.hello(image: "fixture", workerPID: getpid(), supervisorPID: getppid()))
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        if mode == "healthy" {
            let input = Data((0..<200_000).map { UInt8($0 % 256) })
            let one = try await scope.capture(input: input, output: { try wire.send(.output(id: first, stream: $0, bytes: $1)) }) {
                print("buffered-first")
                try? Wire.write(1, Data(repeating: 65, count: 200_000))
                try? Wire.write(2, Data(repeating: 255, count: 200_000))
                try? Wire.write(1, FileHandle.standardInput.readDataToEndOfFile())
                return 23
            }
            try wire.send(.complete(id: first, exitCode: one.exitCode, reusable: one.streamsComplete))
            let two = try await scope.capture(input: Data("second".utf8), output: { try wire.send(.output(id: second, stream: $0, bytes: $1)) }) {
                try? Wire.write(1, FileHandle.standardInput.readDataToEndOfFile())
                print("-end")
                try? Wire.write(2, Data("second-error".utf8))
                return 0
            }
            try wire.send(.complete(id: second, exitCode: two.exitCode, reusable: two.streamsComplete))
        } else if mode == "idle-buffer" {
            let one = try await scope.capture(input: Data(), output: { try wire.send(.output(id: first, stream: $0, bytes: $1)) }) {
                print("first")
                return 0
            }
            try wire.send(.complete(id: first, exitCode: one.exitCode, reusable: one.streamsComplete))
            print("idle-buffer-must-not-enter-next-request")
            let two = try await scope.capture(input: Data(), output: { try wire.send(.output(id: second, stream: $0, bytes: $1)) }) {
                print("second")
                return 0
            }
            try wire.send(.complete(id: second, exitCode: two.exitCode, reusable: two.streamsComplete))
        } else if mode == "c-stdin" || mode == "c-eof" {
            let initial = mode == "c-eof" ? Data() : Data(repeating: 97, count: 100)
            for (id, bytes) in [(first, initial), (second, Data([98]))] {
                let result = try await scope.capture(input: bytes, output: { try wire.send(.output(id: id, stream: $0, bytes: $1)) }) {
                    let value = fgetc(stdin)
                    print(value)
                    return 0
                }
                try wire.send(.complete(id: id, exitCode: result.exitCode, reusable: result.streamsComplete))
            }
        } else if mode == "ignored-input" {
            let result = try await scope.capture(input: Data(repeating: 1, count: 4 * 1024 * 1024), output: { try wire.send(.output(id: first, stream: $0, bytes: $1)) }) {
                print("done")
                return 0
            }
            try wire.send(.complete(id: first, exitCode: result.exitCode, reusable: result.streamsComplete))
        } else if mode == "failed-output" {
            let result = try await scope.capture(input: Data(), output: { _, _ in throw MCPRequestStdioError.setup }) {
                try? Wire.write(1, Data(repeating: 42, count: 200_000))
                return 0
            }
            try wire.send(.complete(id: first, exitCode: result.exitCode, reusable: result.streamsComplete))
            do {
                _ = try await scope.capture(input: Data(), output: { _, _ in }) { 0 }
                try wire.send(.complete(id: second, exitCode: 1, reusable: true))
            } catch {
                try wire.send(.retire(id: second, reason: .io, exitCode: nil))
            }
        } else if mode == "late-writer" {
            var late: Task<Void, Never>?
            let result = try await scope.capture(input: Data(), sealTimeout: 0.02, output: { try wire.send(.output(id: first, stream: $0, bytes: $1)) }) {
                let held = fcntl(1, F_DUPFD_CLOEXEC, 6)
                late = Task.detached {
                    try? await Task.sleep(for: .milliseconds(200))
                    try? Wire.write(held, Data("late".utf8))
                    Darwin.close(held)
                }
                return 0
            }
            try wire.send(.complete(id: first, exitCode: result.exitCode, reusable: result.streamsComplete))
            do {
                _ = try await scope.capture(input: Data(), output: { _, _ in }) { 0 }
                try wire.send(.complete(id: second, exitCode: 1, reusable: true))
            } catch { try wire.send(.retire(id: second, reason: .io, exitCode: nil)) }
            await late?.value
        } else if mode == "second-scope" {
            do {
                _ = try MCPRequestStdio()
                try wire.send(.complete(id: first, exitCode: 1, reusable: true))
            } catch MCPRequestStdioError.unavailable {
                try wire.send(.retire(id: first, reason: .scope, exitCode: nil))
            }
        } else if mode == "input-limit" {
            do {
                _ = try await scope.capture(input: Data(repeating: 0, count: 4 * 1024 * 1024 + 1), output: { _, _ in }) { 0 }
                try wire.send(.complete(id: first, exitCode: 1, reusable: true))
            } catch MCPRequestStdioError.inputLimit {
                try wire.send(.retire(id: first, reason: .io, exitCode: nil))
            }
        } else { _exit(89) }
    }
}
