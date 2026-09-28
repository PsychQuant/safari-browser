import Foundation
import Darwin
import XCTest
@testable import SafariBrowser

final class MCPWorkerControlWriterTests: XCTestCase {
    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    func testConcurrentRelayFramesRemainWholeUnderPartialSocketWrites() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { for descriptor in sockets where descriptor >= 0 { Darwin.close(descriptor) } }
        var size: Int32 = 1024
        XCTAssertEqual(setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)), 0)
        let writer = try MCPWorkerControlWriter(fileDescriptor: sockets[0])
        Darwin.close(sockets[0]); sockets[0] = -1
        let jobs = DispatchGroup(), failures = Failures()
        let id = UUID()
        for stream in [MCPWorkerWire.Stream.stdout, .stderr] {
            jobs.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { jobs.leave() }
                do {
                    for _ in 0..<12 {
                        try writer.send(.output(id: id, stream: stream, bytes: Data(repeating: stream == .stdout ? 65 : 66, count: 8192)))
                    }
                } catch { failures.record() }
            }
        }
        defer {
            _ = Darwin.shutdown(sockets[1], SHUT_RDWR)
            XCTAssertEqual(jobs.wait(timeout: .now() + 2), .success)
        }
        var buffer = Data(), bytes = [UInt8](repeating: 0, count: 333)
        var stdout = 0, stderr = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while stdout + stderr < 24, ProcessInfo.processInfo.systemUptime < deadline {
            var item = pollfd(fd: sockets[1], events: Int16(POLLIN), revents: 0)
            if poll(&item, 1, 10) <= 0 { continue }
            let count = Darwin.read(sockets[1], &bytes, bytes.count)
            guard count > 0 else { XCTFail("Socket ended early"); break }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let data = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard case .output(let token, let stream, let payload) = try MCPWorkerWire.decodeServer(data) else {
                    return XCTFail("Unexpected frame")
                }
                XCTAssertEqual(token, id)
                XCTAssertEqual(payload, Data(repeating: stream == .stdout ? 65 : 66, count: 8192))
                if stream == .stdout { stdout += 1 } else { stderr += 1 }
            }
        }
        XCTAssertEqual(stdout, 12); XCTAssertEqual(stderr, 12)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(jobs.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(failures.count, 0)
    }

    func testDisconnectedPeerThrowsWithoutSIGPIPE() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { Darwin.close(sockets[0]) }
        let writer = try MCPWorkerControlWriter(fileDescriptor: sockets[0])
        Darwin.close(sockets[1])
        let frame = MCPWorkerWire.ServerMessage.hello(image: "fixture", workerPID: 20, supervisorPID: 19)
        XCTAssertThrowsError(try writer.send(frame))
        XCTAssertThrowsError(try writer.send(frame))
    }
}
