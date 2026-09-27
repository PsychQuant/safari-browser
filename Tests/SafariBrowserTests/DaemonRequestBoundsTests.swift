import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonRequestBoundsTests: XCTestCase {
    private var servers: [DaemonServer.Instance] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for server in servers { await server.stop() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        servers.removeAll()
        directories.removeAll()
        try await super.tearDown()
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func hit() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func pair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        for fd in fds { configure(fd) }
        return (fds[0], fds[1])
    }

    private func configure(_ fd: Int32) {
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(.EIO) }
                offset += n
            }
        }
    }

    private func line(_ fd: Int32) throws -> Data {
        var data = Data()
        while data.count < 4096 {
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) == 1 else { throw POSIXError(.EIO) }
            if byte == 10 { return data }
            data.append(byte)
        }
        throw POSIXError(.EMSGSIZE)
    }

    private func start(limit: Int = DaemonServer.maxRequestLineBytes) async throws -> (DaemonServer.Instance, String, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("r194-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directories.append(directory)
        let name = "owned"
        let path = DaemonClient.socketPath(dir: directory.path, name: name)
        let server = DaemonServer.Instance(requestLineLimit: limit)
        servers.append(server)
        try await server.start(socketPath: path)
        return (server, name, directory.path)
    }

    private func connect(name: String, directory: String) throws -> Int32 {
        let path = DaemonClient.socketPath(dir: directory, name: name)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        configure(fd)
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                for (index, byte) in path.utf8.enumerated() { bytes[index] = byte }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
            _ = try line(fd) // handshake, before the request
            return fd
        } catch { close(fd); throw error }
    }

    func testExactLimitAndCoalescedFollowingLinesSurvive() throws {
        let (r, w) = try pair(); defer { close(r); close(w) }
        try writeAll(w, Data("12345678\n\nnext\n".utf8))
        var reader = DaemonServer.RequestLineReader(maxBytes: 8)
        XCTAssertEqual(try reader.readLine(fd: r), Data("12345678".utf8))
        XCTAssertEqual(try reader.readLine(fd: r), Data())
        XCTAssertEqual(try reader.readLine(fd: r), Data("next".utf8))
    }

    func testExcessWithAndWithoutNewlineIsRejectedAsSizeNotTimeout() throws {
        for suffix in [Data(), Data([10])] {
            let (r, w) = try pair(); defer { close(r); close(w) }
            try writeAll(w, Data(repeating: 65, count: 9) + suffix)
            var reader = DaemonServer.RequestLineReader(maxBytes: 8)
            XCTAssertThrowsError(try reader.readLine(fd: r)) {
                XCTAssertEqual($0 as? DaemonServer.RequestLineReader.ReadError, .lineTooLong)
            }
        }
    }

    func testEOFStillTerminatesAnInLimitFinalLine() throws {
        let (r, w) = try pair(); defer { close(r); close(w) }
        try writeAll(w, Data("12345678".utf8))
        shutdown(w, SHUT_WR)
        var reader = DaemonServer.RequestLineReader(maxBytes: 8)
        XCTAssertEqual(try reader.readLine(fd: r), Data("12345678".utf8))
        XCTAssertNil(try reader.readLine(fd: r))
    }

    func testReadFailureDoesNotMasqueradeAsEOFWithAPartialLine() throws {
        let (r, w) = try pair(); defer { close(r); close(w) }
        XCTAssertEqual(fcntl(r, F_SETFL, fcntl(r, F_GETFL) | O_NONBLOCK), 0)
        try writeAll(w, Data("{}".utf8))
        var reader = DaemonServer.RequestLineReader(maxBytes: 8)
        XCTAssertThrowsError(try reader.readLine(fd: r)) {
            XCTAssertEqual($0 as? DaemonServer.RequestLineReader.ReadError, .readFailed(EAGAIN))
        }
    }

    func testOversizedRequestNeverDispatchesAndAnotherClientStillWorks() async throws {
        let (server, name, directory) = try await start(limit: 1024)
        let counter = Counter()
        await server.register("owned") { _ in counter.hit(); return Data("true".utf8) }
        let fd = try connect(name: name, directory: directory)
        defer { close(fd) }
        var request = Data(#"{"method":"owned","params":{},"requestId":7}"#.utf8)
        request.append(Data(repeating: 32, count: 1025 - request.count))
        request.append(10)
        try writeAll(fd, request)
        var byte: UInt8 = 0
        let rejected = read(fd, &byte, 1)
        XCTAssertTrue(rejected == 0 || (rejected < 0 && errno == ECONNRESET),
                      "oversized request must close before a response or handler")
        XCTAssertEqual(counter.value, 0)
        let reply = try await DaemonClient.sendRequest(name: name, method: "owned", params: Data("{}".utf8),
            requestId: 8, timeout: 2, socketDir: directory)
        XCTAssertEqual(reply, Data("true".utf8))
        XCTAssertEqual(counter.value, 1)
    }
    func testSegmentedLimitAndEINTRKeepTheSameFrame() throws {
        let (r, w) = try pair(); defer { close(r); close(w) }
        try writeAll(w, Data("12345678\n".utf8))
        var reader = DaemonServer.RequestLineReader(maxBytes: 8)
        var reads = 0
        let value = try reader.readLine(fd: r) { fd, buffer, size in
            reads += 1
            if reads == 2 { errno = EINTR; return -1 }
            return Darwin.read(fd, buffer, min(size, 4))
        }
        XCTAssertEqual(value, Data("12345678".utf8))
        XCTAssertGreaterThanOrEqual(reads, 4)
    }

    func testRejectionKeepsAtMostOneExcessByte() throws {
        let (r, w) = try pair(); defer { close(r); close(w) }
        try writeAll(w, Data(repeating: 65, count: 1000))
        var reader = DaemonServer.RequestLineReader(maxBytes: 8)
        XCTAssertThrowsError(try reader.readLine(fd: r))
        XCTAssertEqual(reader.pending.count, 9)
    }

    func testExactLimitFinalEOFAndThenNoMoreData() throws {
        let (r, w) = try pair(); defer { close(r); close(w) }
        try writeAll(w, Data("first\n12345678".utf8))
        shutdown(w, SHUT_WR)
        var reader = DaemonServer.RequestLineReader(maxBytes: 8)
        XCTAssertEqual(try reader.readLine(fd: r), Data("first".utf8))
        XCTAssertEqual(try reader.readLine(fd: r), Data("12345678".utf8))
        XCTAssertNil(try reader.readLine(fd: r))
    }

    func testMultimegabyteLineUsesManyBoundedReads() throws {
        let (r, w) = try pair(); defer { close(r) }
        let payload = Data(repeating: 65, count: 8 * 1024 * 1024) + Data([10])
        let group = DispatchGroup()
        let failed = Counter()
        group.enter()
        DispatchQueue.global().async {
            // The writer owns this fd until its last write, even if a
            // failing test cannot join promptly. Never close beneath it.
            defer { close(w); group.leave() }
            payload.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let n = write(w, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { failed.hit(); return }
                    sent += n
                }
            }
        }
        defer { shutdown(r, SHUT_RDWR); _ = group.wait(timeout: .now() + 3) }
        var reader = DaemonServer.RequestLineReader()
        var reads = 0
        var smallestRequestedChunk = Int.max
        let result = try reader.readLine(fd: r) { fd, buffer, size in
            XCTAssertLessThanOrEqual(size, 8192)
            reads += 1
            smallestRequestedChunk = min(smallestRequestedChunk, size)
            return Darwin.read(fd, buffer, size)
        }
        XCTAssertEqual(result, payload.dropLast())
        XCTAssertGreaterThan(reads, 1000)
        XCTAssertGreaterThan(smallestRequestedChunk, 1, "request chunks without assuming how much the kernel returns")
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(failed.value, 0)
    }

    func testServerAcceptsExactLimitAndDoesNotLoseCoalescedRequests() async throws {
        let (server, name, directory) = try await start(limit: 1024)
        let counter = Counter()
        await server.register("owned") { _ in counter.hit(); return Data("true".utf8) }
        let fd = try connect(name: name, directory: directory)
        defer { close(fd) }
        var first = Data(#"{"method":"owned","params":{},"requestId":7}"#.utf8)
        first.append(Data(repeating: 32, count: 1024 - first.count))
        let second = Data(#"{"method":"owned","params":{},"requestId":8}"#.utf8)
        try writeAll(fd, first + Data([10]) + second + Data([10]))
        for id in [7, 8] {
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: line(fd)) as? [String: Any])
            XCTAssertEqual(reply["requestId"] as? Int, id)
            XCTAssertEqual(reply["result"] as? Bool, true)
        }
        XCTAssertEqual(counter.value, 2)
    }

    func testNoNewlineExcessClosesWithoutWaitingForPeerEOF() async throws {
        let (server, name, directory) = try await start(limit: 1024)
        let counter = Counter()
        await server.register("owned") { _ in counter.hit(); return Data("true".utf8) }
        let fd = try connect(name: name, directory: directory)
        defer { close(fd) }
        var request = Data(#"{"method":"owned","params":{},"requestId":7}"#.utf8)
        request.append(Data(repeating: 32, count: 1025 - request.count))
        try writeAll(fd, request) // Keep the peer open: no LF or EOF can trigger rejection.
        var byte: UInt8 = 0
        let n = read(fd, &byte, 1)
        XCTAssertTrue(n == 0 || (n < 0 && errno == ECONNRESET), "must close, not wait for the fixture timeout")
        XCTAssertEqual(counter.value, 0)
    }

    func testLargeUnicodeRequestReachesHandlerIntact() async throws {
        let (server, name, directory) = try await start()
        let expected = String(repeating: "漢字😀", count: 300_000)
        await server.register("owned") { bytes in
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: String]
            return Data(object?["source"] == expected ? "true".utf8 : "false".utf8)
        }
        let params = try JSONSerialization.data(withJSONObject: ["source": expected])
        XCTAssertGreaterThan(params.count, 3_000_000)
        let result = try await DaemonClient.sendRequest(name: name, method: "owned", params: params,
            requestId: 9, timeout: 10, socketDir: directory)
        XCTAssertEqual(result, Data("true".utf8))
    }

    func testClientRouterDoesNotReplayOversizedRequest() async throws {
        let (server, name, directory) = try await start(limit: 1024)
        let counter = Counter()
        await server.register("owned") { _ in counter.hit(); return Data("true".utf8) }
        for sourceBytes in [4000, 4_000_000] {
            let params = try JSONSerialization.data(withJSONObject: ["source": String(repeating: "x", count: sourceBytes)])
            var fallbackCalls = 0
            do {
                _ = try await SafariBridge.runViaRouter(source: "owned request", daemonOptIn: true,
                    daemonFn: { _ in
                        let data = try await DaemonClient.sendRequest(name: name, method: "owned", params: params,
                            requestId: 7, timeout: 5, socketDir: directory)
                        return String(decoding: data, as: UTF8.self)
                    }, statelessFn: { _ in fallbackCalls += 1; return "replayed" })
                XCTFail("oversized request cannot succeed")
            } catch let error as DaemonClient.Error {
                guard case .requestOutcomeUnknown(let reason) = error else { return XCTFail("unexpected classification: \(error)") }
                if sourceBytes == 4_000_000 {
                    XCTAssertTrue(reason.contains("request transmission interrupted"), "exercise the interrupted-write path: \(reason)")
                }
                XCTAssertNil(error.fallbackReason)
            }
            XCTAssertEqual(counter.value, 0)
            XCTAssertEqual(fallbackCalls, 0)
        }
    }

    func testCoalescedOversizedFrameDoesNotDispatchOrSkipToFollowingFrame() async throws {
        let (server, name, directory) = try await start(limit: 128)
        let counter = Counter()
        await server.register("owned") { _ in counter.hit(); return Data("true".utf8) }
        let fd = try connect(name: name, directory: directory)
        defer { close(fd) }
        let first = Data(#"{"method":"owned","params":{},"requestId":1}"#.utf8)
        var excess = Data(#"{"method":"owned","params":{},"requestId":2}"#.utf8)
        excess.append(Data(repeating: 32, count: 129 - excess.count))
        let last = Data(#"{"method":"owned","params":{},"requestId":3}"#.utf8)
        try writeAll(fd, first + Data([10]) + excess + Data([10]) + last + Data([10]))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: line(fd)) as? [String: Any])
        XCTAssertEqual(response["requestId"] as? Int, 1)
        var byte: UInt8 = 0
        let n = read(fd, &byte, 1)
        XCTAssertTrue(n == 0 || (n < 0 && errno == ECONNRESET), "must terminate at the invalid frame, not skip it")
        XCTAssertEqual(counter.value, 1)
    }

    func testEOFRequestAtLimitDispatchesExactlyOnce() async throws {
        let (server, name, directory) = try await start(limit: 128)
        let counter = Counter()
        await server.register("owned") { _ in counter.hit(); return Data("true".utf8) }
        let fd = try connect(name: name, directory: directory)
        defer { close(fd) }
        var request = Data(#"{"method":"owned","params":{},"requestId":7}"#.utf8)
        request.append(Data(repeating: 32, count: 128 - request.count))
        try writeAll(fd, request)
        shutdown(fd, SHUT_WR)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: line(fd)) as? [String: Any])
        XCTAssertEqual(response["requestId"] as? Int, 7)
        var byte: UInt8 = 0
        XCTAssertEqual(read(fd, &byte, 1), 0)
        XCTAssertEqual(counter.value, 1)
    }

    func testOversizedLifecycleRequestCannotBypassTheReaderLimit() async throws {
        let (server, name, directory) = try await start(limit: 128)
        let shutdowns = Counter()
        await server.setShutdownHook { shutdowns.hit() }
        await server.register("owned") { _ in Data("true".utf8) }
        let fd = try connect(name: name, directory: directory)
        defer { close(fd) }
        var request = Data(#"{"method":"daemon.shutdown","params":{},"requestId":7}"#.utf8)
        request.append(Data(repeating: 32, count: 129 - request.count))
        try writeAll(fd, request + Data([10]))
        var byte: UInt8 = 0
        let n = read(fd, &byte, 1)
        XCTAssertTrue(n == 0 || (n < 0 && errno == ECONNRESET), "lifecycle routing must not parse an oversized frame")
        XCTAssertEqual(shutdowns.value, 0)
        let response = try await DaemonClient.sendRequest(name: name, method: "owned", params: Data("{}".utf8),
            requestId: 8, timeout: 2, socketDir: directory)
        XCTAssertEqual(response, Data("true".utf8))
        XCTAssertEqual(shutdowns.value, 0)
    }

    func testRejectedRequestClosesBeforeBlockedPrivateDiagnosticAndOtherClientWorks() async throws {
        let (server, name, directory) = try await start(limit: 128)
        let sink = DaemonDiagnosticBudgetTests.Sink()
        let entered = expectation(description: "payload-free rejection diagnostic")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await server.setLogWriter({ line in
            sink.append(line)
            if line.contains("request_too_long") {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }, logFull: true)
        let calls = Counter()
        await server.register("owned") { _ in calls.hit(); return Data("true".utf8) }
        let fd = try connect(name: name, directory: directory)
        defer { close(fd) }
        var payload = Data(#"{"method":"owned","params":{"source":"private-prefix-197"},"requestId":7}"#.utf8)
        payload.append(Data(repeating: 32, count: 129 - payload.count))
        try writeAll(fd, payload)
        var byte: UInt8 = 0
        let count = read(fd, &byte, 1)
        XCTAssertTrue(count == 0 || (count < 0 && errno == ECONNRESET))
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(calls.value, 0)
        let result = try await DaemonClient.sendRequest(name: name, method: "owned", params: Data("{}".utf8),
            requestId: 8, timeout: 2, socketDir: directory)
        XCTAssertEqual(result, Data("true".utf8))
        XCTAssertEqual(calls.value, 1)
        XCTAssertFalse(sink.all.joined().contains("private-prefix-197"))
        let diagnostic = try XCTUnwrap(sink.objects.first { $0["event"] as? String == "request_too_long" })
        XCTAssertEqual(Set(diagnostic.keys), ["timestamp", "event", "errno", "disposition", "count"])
        XCTAssertEqual(diagnostic["disposition"] as? String, "closed")
        release.signal()
    }

    func testReadFailureProducesDiagnosticWithoutDispatchingItsPrefix() async throws {
        let (accepted, peer) = try pair(); defer { close(peer) }
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let server = DaemonServer.Instance()
        let sink = DaemonDiagnosticBudgetTests.Sink()
        let logged = expectation(description: "read error diagnostic")
        await server.setLogWriter { line in
            sink.append(line)
            if line.contains("request_read_failed") { logged.fulfill() }
        }
        let calls = Counter()
        await server.register("owned") { _ in calls.hit(); return Data("true".utf8) }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var wake: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&wake), 0)
        defer { close(wake[1]) }
        let script = DaemonAcceptRecoveryTests.ScriptedListener([(accepted, 0)])
        await DaemonServer.Instance.acceptLoop(listenerFd: listener, wakeFd: wake[0], instance: server,
                                               environment: script.environment(realSleep: false))
        _ = try line(peer)
        try writeAll(peer, Data(#"{"method":"owned","params":{"source":"private-prefix-197"},"requestId":7}"#.utf8))
        var byte: UInt8 = 0
        let count = read(peer, &byte, 1)
        XCTAssertTrue(count == 0 || (count < 0 && errno == ECONNRESET))
        await fulfillment(of: [logged], timeout: 1)
        XCTAssertEqual(calls.value, 0)
        XCTAssertFalse(sink.all.joined().contains("private-prefix-197"))
        XCTAssertEqual(sink.objects.first?["errno"] as? Int, Int(EAGAIN))
        await server.stop()
    }

}
