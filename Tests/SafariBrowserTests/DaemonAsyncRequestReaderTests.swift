import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonAsyncRequestReaderTests: XCTestCase {
    private func pair() throws -> (DaemonConnection, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        return (try DaemonConnection(adopting: fds[0]), fds[1])
    }

    func testCoalescedExactLimitAndRealEOFPreserveExistingFrames() async throws {
        let (connection, peer) = try pair()
        defer { connection.revoke(); close(peer) }
        let bytes = Data("first\n12345678\nlast".utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(peer, $0.baseAddress!, $0.count) }, bytes.count)
        XCTAssertEqual(shutdown(peer, SHUT_WR), 0)
        var reader = DaemonServer.RequestLineReader(maxBytes: 8)
        let first = try await reader.readLine(connection: connection)
        let exact = try await reader.readLine(connection: connection)
        let eof = try await reader.readLine(connection: connection)
        let empty = try await reader.readLine(connection: connection)
        XCTAssertEqual(first, Data("first".utf8))
        XCTAssertEqual(exact, Data("12345678".utf8))
        XCTAssertEqual(eof, Data("last".utf8))
        XCTAssertNil(empty)
    }

    func testOneExcessByteWithoutNewlineIsRejected() async throws {
        let (connection, peer) = try pair()
        defer { connection.revoke(); close(peer) }
        let bytes = Data("123456789".utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(peer, $0.baseAddress!, $0.count) }, bytes.count)
        XCTAssertEqual(shutdown(peer, SHUT_WR), 0)
        var reader = DaemonServer.RequestLineReader(maxBytes: 8)
        do {
            _ = try await reader.readLine(connection: connection)
            XCTFail("one excess byte must be rejected before waiting for LF")
        } catch { XCTAssertEqual(error as? DaemonServer.RequestLineReader.ReadError, .lineTooLong) }
    }

    func testRevocationRejectsAnAlreadyBufferedSecondFrame() async throws {
        let (connection, peer) = try pair()
        defer { connection.revoke(); close(peer) }
        let bytes = Data("one\ntwo\n".utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(peer, $0.baseAddress!, $0.count) }, bytes.count)
        var reader = DaemonServer.RequestLineReader(maxBytes: 100)
        let first = try await reader.readLine(connection: connection)
        XCTAssertEqual(first, Data("one".utf8))
        connection.revoke()
        do {
            _ = try await reader.readLine(connection: connection)
            XCTFail("a revoked connection cannot return another buffered request")
        } catch { XCTAssertEqual(error as? DaemonConnection.Failure, .revoked) }
    }

    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private let bytes: Data
        private var offset = 0
        private var yields = 0
        init(_ bytes: Data) { self.bytes = bytes }
        func read(_ buffer: UnsafeMutableRawPointer, _ count: Int) -> DaemonConnection.IOResult {
            lock.withLock {
                let length = min(count, bytes.count - offset)
                bytes.withUnsafeBytes { raw in
                    if length > 0 { buffer.copyMemory(from: raw.baseAddress!.advanced(by: offset), byteCount: length) }
                }
                offset += length
                return .init(count: length, errno: 0)
            }
        }
        func yielded() { lock.withLock { yields += 1 } }
        var yieldCount: Int { lock.withLock { yields } }
    }

    func testLongAvailableInputYieldsWithoutChangingPayload() async throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        let payload = Data(repeating: 97, count: 17 * 8192)
        var wire = payload; wire.append(10)
        let feed = Feed(wire)
        let connection = try DaemonConnection(adopting: fds[0], environment: .init(read: { _, buffer, count in
            feed.read(buffer, count)
        }))
        defer { connection.revoke(); close(fds[1]) }
        var reader = DaemonServer.RequestLineReader(maxBytes: payload.count)
        let output = try await reader.readLine(connection: connection, yieldAfterProgress: {
            feed.yielded(); await Task.yield()
        })
        XCTAssertEqual(output, payload)
        XCTAssertGreaterThan(feed.yieldCount, 0, "available bulk input must leave scheduling opportunities")
    }
}
