import XCTest
import Foundation
import Darwin
@testable import SafariBrowser

final class DaemonTransportDeadlineTests: XCTestCase {
    func testTrickleResponseCannotExtendWholeRequestDeadline() async throws {
        let peer = try DeadlinePeer { fd in
            DeadlinePeer.handshake(fd)
            _ = DeadlinePeer.readRequest(fd)
            for byte in #"{"requestId":7,"result":{"ok":true}}"#.utf8 {
                guard DeadlinePeer.write(fd, Data([byte])) else { break }
                usleep(30_000)
            }
            _ = DeadlinePeer.write(fd, Data([10]))
        }
        defer { peer.stop() }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await peer.request(timeout: 0.1)
            XCTFail("a trickling response must not extend the request deadline")
        } catch let error as DaemonClient.Error {
            XCTAssertNil(error.fallbackReason, "a fully transmitted operation must not replay")
            XCTAssertTrue(error.description.contains("timeout"), "\(error)")
        }
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, 0.8)
    }

    func testTruncatedJSONWithoutNewlineIsNotAcceptedAsSuccess() async throws {
        try await assertUnknownResponse(#"{"requestId":7,"result":{"ok":true}}"#)
    }

    func testMismatchedResponseCannotAuthorizeRetryOrSuccess() async throws {
        try await assertUnknownResponse(#"{"requestId":8,"result":{"ok":true}}"# + "\n")
    }

    func testMissingOrBooleanRequestIDCannotAuthorizeSuccess() async throws {
        try await assertUnknownResponse(#"{"result":{}}"# + "\n")
        try await assertUnknownResponse(#"{"requestId":true,"result":{}}"# + "\n", requestId: 1)
    }

    func testMalformedResponseAfterTransmissionCannotReplay() async throws {
        try await assertUnknownResponse("not-json\n")
        try await assertUnknownResponse(#"{"requestId":7}"# + "\n")
        try await assertUnknownResponse(#"{"requestId":7,"result":{},"error":{"code":"handlerError","message":"bad"}}"# + "\n")
    }

    func testCompleteMutationThenEOFNeverCallsStatelessFallback() async throws {
        let peer = try DeadlinePeer { fd in
            DeadlinePeer.handshake(fd)
            _ = DeadlinePeer.readRequest(fd)
        }
        defer { peer.stop() }
        var fallbackCalls = 0
        do {
            _ = try await SafariBridge.runViaRouter(
                source: "mutate", daemonOptIn: true,
                daemonFn: { _ in String(decoding: try await peer.request(timeout: 0.1), as: UTF8.self) },
                statelessFn: { _ in fallbackCalls += 1; return "replayed" },
                warnWriter: { _ in }
            )
            XCTFail("lost response must surface an unknown outcome")
        } catch let error as DaemonClient.Error {
            XCTAssertNil(error.fallbackReason)
        }
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testHandshakeAndResponseShareDeadline() async throws {
        let peer = try DeadlinePeer { fd in
            usleep(180_000)
            DeadlinePeer.handshake(fd)
            _ = DeadlinePeer.readRequest(fd)
            usleep(180_000)
            _ = DeadlinePeer.write(fd, Data((#"{"requestId":7,"result":{}}"# + "\n").utf8))
        }
        defer { peer.stop() }
        do {
            _ = try await peer.request(timeout: 0.25)
            XCTFail("handshake must consume the response time budget")
        } catch let error as DaemonClient.Error {
            XCTAssertNil(error.fallbackReason)
            XCTAssertTrue(error.description.contains("timeout"))
        }
    }

    func testWriteAndHandshakeShareDeadlineBeforeFrameIsComplete() async throws {
        let peer = try DeadlinePeer { fd in
            usleep(150_000)
            DeadlinePeer.handshake(fd)
            usleep(400_000) // Deliberately never consume the large request.
        }
        defer { peer.stop() }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await peer.request(timeout: 0.2, params: Data(("{\"value\":\"" + String(repeating: "x", count: 2_000_000) + "\"}").utf8))
            XCTFail("write should reach deadline")
        } catch let error as DaemonClient.Error {
            XCTAssertNil(error.fallbackReason, "a partial request can execute on a peer that accepts EOF as framing")
            XCTAssertTrue(error.description.contains("timeout"))
        }
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, 0.32)
    }

    func testInvalidTimeoutIsRejectedBeforeConnecting() async {
        for value in [Double.nan, .infinity, -.infinity, -1, 0, 0.0001, 86401] {
            do {
                _ = try await DaemonClient.sendRequest(name: "absent", method: "echo", params: Data("{}".utf8), requestId: 1, timeout: value, socketDir: "/tmp")
                XCTFail("invalid timeout accepted")
            } catch let error as DaemonClient.Error {
                XCTAssertNil(error.fallbackReason, "invalid input must not trigger a stateless operation")
                XCTAssertTrue(error.description.contains("invalid timeout"), "\(error)")
            } catch { XCTFail("\(error)") }
        }
    }

    func testValidatedSuccessAndErrorForwardDiagnosticsBeforeReturning() async throws {
        for envelope in [
            #"{"requestId":7,"result":{"ok":true},"diagnostics":["first","second\n"]}"#,
            #"{"requestId":7,"error":{"code":"handlerError","message":"after mutation"},"diagnostics":["first","second\n"]}"#
        ] {
            let peer = try DeadlinePeer { fd in
                DeadlinePeer.handshake(fd)
                _ = DeadlinePeer.readRequest(fd)
                _ = DeadlinePeer.write(fd, Data((envelope + "\n").utf8))
            }
            defer { peer.stop() }
            let captured = DiagnosticCapture()
            do {
                let data = try await DaemonClient.sendRequest(
                    name: peer.name, method: "mutate", params: Data("{}".utf8), requestId: 7,
                    timeout: 0.2, socketDir: "/tmp", diagnosticsWriter: { captured.append($0) }
                )
                XCTAssertTrue(envelope.contains("result"))
                XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: Bool], ["ok": true])
            } catch DaemonClient.Error.remoteError(let code, _) {
                XCTAssertEqual(code, "handlerError")
            }
            XCTAssertEqual(captured.values, ["first\n", "second\n"])
        }
    }

    func testUncorrelatedOrInvalidEnvelopeEmitsNoDiagnostics() async throws {
        for envelope in [
            #"{"requestId":8,"result":{},"diagnostics":["wrong request"]}"#,
            #"{"requestId":7,"result":{},"diagnostics":["must not leak",false]}"#,
            #"{"requestId":7,"error":{"code":"handlerError"},"diagnostics":["invalid response"]}"#
        ] {
            let peer = try DeadlinePeer { fd in
                DeadlinePeer.handshake(fd)
                _ = DeadlinePeer.readRequest(fd)
                _ = DeadlinePeer.write(fd, Data((envelope + "\n").utf8))
            }
            defer { peer.stop() }
            let captured = DiagnosticCapture()
            do {
                _ = try await DaemonClient.sendRequest(
                    name: peer.name, method: "mutate", params: Data("{}".utf8), requestId: 7,
                    timeout: 0.2, socketDir: "/tmp", diagnosticsWriter: { captured.append($0) }
                )
                XCTFail("invalid response accepted")
            } catch let error as DaemonClient.Error {
                XCTAssertNil(error.fallbackReason)
            }
            XCTAssertTrue(captured.values.isEmpty)
        }
    }

    func testBridgeHonorsShorterCallerDeadlineWithoutDoubling() async throws {
        let peer = try DeadlinePeer(directory: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") { fd in
            DeadlinePeer.handshake(fd)
            let request = DeadlinePeer.readRequest(fd)
            let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
            usleep(200_000)
            let response: [String: Any] = ["requestId": object?["requestId"] ?? 0, "result": ["status": "ok", "output": "done"]]
            if var data = try? JSONSerialization.data(withJSONObject: response) {
                data.append(10)
                _ = DeadlinePeer.write(fd, data)
            }
        }
        defer { peer.stop() }
        let oldName = ProcessInfo.processInfo.environment["SAFARI_BROWSER_NAME"]
        setenv("SAFARI_BROWSER_NAME", peer.name, 1)
        defer {
            if let oldName { setenv("SAFARI_BROWSER_NAME", oldName, 1) }
            else { unsetenv("SAFARI_BROWSER_NAME") }
        }
        do {
            _ = try await SafariBridge.executeAppleScriptViaDaemon(source: "return 42", timeout: 0.1)
            XCTFail("bridge must not extend caller's deadline")
        } catch DaemonClient.Error.requestOutcomeUnknown(let reason) {
            XCTAssertTrue(reason.contains("timeout"))
        }
    }

    func testMalformedAppleScriptPayloadNeverReturnsSuccessOrReplays() async throws {
        for payload in ["null", "{}", #"{"status":"other"}"#,
                        #"{"status":"ok","output":7}"#, #"{"status":"error"}"#] {
            let peer = try DeadlinePeer(directory: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") { fd in
                DeadlinePeer.handshake(fd)
                let request = DeadlinePeer.readRequest(fd)
                let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
                let result = try! JSONSerialization.jsonObject(with: Data(payload.utf8), options: [.fragmentsAllowed])
                var response = try! JSONSerialization.data(withJSONObject: ["requestId": object?["requestId"] ?? 0, "result": result])
                response.append(10)
                _ = DeadlinePeer.write(fd, response)
            }
            defer { peer.stop() }
            let oldName = ProcessInfo.processInfo.environment["SAFARI_BROWSER_NAME"]
            setenv("SAFARI_BROWSER_NAME", peer.name, 1)
            defer {
                if let oldName { setenv("SAFARI_BROWSER_NAME", oldName, 1) }
                else { unsetenv("SAFARI_BROWSER_NAME") }
            }
            var fallbackCalls = 0
            do {
                _ = try await SafariBridge.runViaRouter(source: "mutate", daemonOptIn: true,
                    daemonFn: { _ in try await SafariBridge.executeAppleScriptViaDaemon(source: "return 42", timeout: 1) },
                    statelessFn: { _ in fallbackCalls += 1; return "replayed" })
                XCTFail("malformed payload accepted: \(payload)")
            } catch let error as DaemonClient.Error {
                XCTAssertNil(error.fallbackReason)
                guard case .requestOutcomeUnknown = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(fallbackCalls, 0)
        }
    }

    private func assertUnknownResponse(_ response: String, requestId: Int = 7) async throws {
        let peer = try DeadlinePeer { fd in
            DeadlinePeer.handshake(fd)
            _ = DeadlinePeer.readRequest(fd)
            _ = DeadlinePeer.write(fd, Data(response.utf8))
        }
        defer { peer.stop() }
        do {
            _ = try await peer.request(timeout: 0.2, requestId: requestId)
            XCTFail("unvalidated response must not count as success: \(response)")
        } catch let error as DaemonClient.Error {
            XCTAssertNil(error.fallbackReason, "unvalidated response must not authorize replay")
        } catch { XCTFail("expected typed unknown outcome, got \(error)") }
    }
}

/// One real Unix socket peer per test. Socket-level control exercises the client
/// framing/deadline contract without relying on Safari or daemon handler timing.
private final class DeadlinePeer: @unchecked Sendable {
    let name = "deadline-" + String(UUID().uuidString.prefix(8))
    let listener: Int32
    let path: String
    let directory: String
    let finished = DispatchSemaphore(value: 0)

    init(directory: String = "/tmp", handler: @escaping @Sendable (Int32) -> Void) throws {
        self.directory = directory
        path = DaemonClient.socketPath(dir: directory, name: name)
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
            buffer[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(self.listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0, Darwin.listen(listener, 1) == 0 else {
            Darwin.close(listener)
            throw POSIXError(.EIO)
        }
        let listener = self.listener
        let finished = self.finished
        DispatchQueue.global().async {
            defer { finished.signal() }
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }
            var enabled: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            handler(fd)
        }
    }

    func request(timeout: Double, requestId: Int = 7, params: Data = Data("{}".utf8)) async throws -> Data {
        try await DaemonClient.sendRequest(name: name, method: "mutate", params: params, requestId: requestId, timeout: timeout, socketDir: directory)
    }

    func stop() {
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        _ = finished.wait(timeout: .now() + 3)
        unlink(path)
    }

    static func handshake(_ fd: Int32) {
        var bytes = DaemonProtocol.encodeHandshake()
        bytes.append(10)
        _ = write(fd, bytes)
    }

    static func readRequest(_ fd: Int32) -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            data.append(byte)
            if byte == 10 { break }
        }
        return data
    }

    static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

private final class DiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ text: String) { lock.withLock { storage.append(text) } }
    var values: [String] { lock.withLock { storage } }
}

// MARK: - #174: bounded reply lines

extension DaemonTransportDeadlineTests {
    private func pair() -> (reader: Int32, writer: Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        var enabled: Int32 = 1
        _ = setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        // The real client reads a non-blocking socket and waits through its
        // deadline; a blocking fd here would hang instead of timing out.
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        return (fds[0], fds[1])
    }

    func testLineOfExactlyTheLimitIsAccepted() throws {
        let (r, w) = pair(); defer { close(r); close(w) }
        XCTAssertTrue(DeadlinePeer.write(w, Data(repeating: 65, count: 1000) + Data([10])))
        var reader = DaemonClient.LineReader()
        let line = try reader.readLine(fd: r, deadline: DaemonClient.Deadline(timeout: 2), maxBytes: 1000)
        XCTAssertEqual(line.count, 1000)
    }

    func testLineOneByteOverTheLimitIsRejected() {
        let (r, w) = pair(); defer { close(r); close(w) }
        XCTAssertTrue(DeadlinePeer.write(w, Data(repeating: 65, count: 1001) + Data([10])))
        var reader = DaemonClient.LineReader()
        XCTAssertThrowsError(try reader.readLine(fd: r, deadline: DaemonClient.Deadline(timeout: 2), maxBytes: 1000))
    }

    func testOversizedLineWithoutNewlineIsRejectedBeforeTheDeadline() {
        // The peer keeps the connection open and never sends a newline: the
        // reader must stop at the limit, not buffer until the deadline.
        let (r, w) = pair()
        // Written from another thread: 64 KiB exceeds the socket buffer, so a
        // same-thread write would block until the reader drains it.
        let writerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = DeadlinePeer.write(w, Data(repeating: 65, count: 64 * 1024))
            writerDone.signal()
        }
        defer {
            close(r)                                   // unblocks the writer (EPIPE)
            _ = writerDone.wait(timeout: .now() + 2)
            close(w)
        }
        var reader = DaemonClient.LineReader()
        let start = Date()
        XCTAssertThrowsError(try reader.readLine(fd: r, deadline: DaemonClient.Deadline(timeout: 5), maxBytes: 4096))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testSegmentedLineAndSecondLineInTheSameReadBothSurvive() throws {
        let (r, w) = pair(); defer { close(r); close(w) }
        DispatchQueue.global().async {
            _ = DeadlinePeer.write(w, Data("{\"a\":".utf8)); usleep(20_000)
            _ = DeadlinePeer.write(w, Data("1}\n{\"b\":2}\n".utf8))
        }
        var reader = DaemonClient.LineReader()
        let deadline = DaemonClient.Deadline(timeout: 2)
        XCTAssertEqual(String(decoding: try reader.readLine(fd: r, deadline: deadline, maxBytes: 64), as: UTF8.self), "{\"a\":1}")
        XCTAssertEqual(String(decoding: try reader.readLine(fd: r, deadline: deadline, maxBytes: 64), as: UTF8.self), "{\"b\":2}")
    }

    func testEOFBeforeNewlineIsStillAnError() {
        let (r, w) = pair(); defer { close(r) }
        XCTAssertTrue(DeadlinePeer.write(w, Data("partial".utf8)))
        close(w)
        var reader = DaemonClient.LineReader()
        XCTAssertThrowsError(try reader.readLine(fd: r, deadline: DaemonClient.Deadline(timeout: 2), maxBytes: 64))
    }

    func testOversizedReplyAfterTransmissionIsOutcomeUnknownNotReplayed() async throws {
        let peer = try DeadlinePeer { fd in
            DeadlinePeer.handshake(fd)
            _ = DeadlinePeer.readRequest(fd)
            _ = DeadlinePeer.write(fd, Data(repeating: 65, count: 8192))   // no newline, over the test limit
        }
        defer { peer.stop() }
        do {
            _ = try await DaemonClient.sendRequest(name: peer.name, method: "mutate", params: Data("{}".utf8),
                                                   requestId: 7, timeout: 2, socketDir: peer.directory,
                                                   responseLineLimit: 1024)
            XCTFail("an oversized reply must not count as success")
        } catch let error as DaemonClient.Error {
            XCTAssertNil(error.fallbackReason, "the request was transmitted: an oversized reply must not authorize replay")
        }
    }

    func testOversizedHandshakeFailsBeforeTheRequestIsSent() async throws {
        let sent = ExecSubprocessOutputTests.Output()
        let peer = try DeadlinePeer { fd in
            _ = DeadlinePeer.write(fd, Data(repeating: 65, count: DaemonClient.maxHandshakeLineBytes + 1))
            let request = DeadlinePeer.readRequest(fd)
            if !request.isEmpty { sent.append("request") }
        }
        defer { peer.stop() }
        do {
            _ = try await peer.request(timeout: 1)
            XCTFail("an oversized handshake must fail")
        } catch let error as DaemonClient.Error {
            XCTAssertNotNil(error.fallbackReason, "nothing was sent yet, so the stateless path stays available")
        }
        XCTAssertTrue(sent.text.isEmpty, "the request must never be written after an oversized handshake")
    }

    func testDefaultLimitsAreGenerousForLegitimateOutput() {
        XCTAssertEqual(DaemonClient.maxHandshakeLineBytes, 64 * 1024)
        XCTAssertEqual(DaemonClient.maxResponseLineBytes, 128 * 1024 * 1024)
    }

    func testLegitimateMultiMegabyteLineAcrossManyReadsIsAcceptedInLinearTime() throws {
        // Verify R1: every accepted line above was one read() long. A real
        // `get source` / `snapshot` reply is one multi-megabyte JSON line
        // assembled from thousands of reads — the path the incremental newline
        // scan exists for. Rescanning from the start after each 8 KiB read
        // would touch ~150 GB for this line; a linear scan touches 48 MiB.
        let size = 48 * 1024 * 1024
        let (r, w) = pair()
        let writerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var body = Data(repeating: 66, count: size)
            body[0] = 65
            body[size - 1] = 67
            _ = DeadlinePeer.write(w, body + Data([10]))
            writerDone.signal()
        }
        defer {
            close(r)
            _ = writerDone.wait(timeout: .now() + 5)
            close(w)
        }
        var reader = DaemonClient.LineReader()
        let start = Date()
        let line = try reader.readLine(fd: r, deadline: DaemonClient.Deadline(timeout: 30), maxBytes: 64 * 1024 * 1024)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the newline scan must stay linear in the line length")
        XCTAssertEqual(line.count, size)
        XCTAssertEqual(line.first, 65)
        XCTAssertEqual(line.last, 67)
    }

    func testRejectionBuffersAtMostOneByteBeyondTheLimit() {
        // Verify R1: reads were a fixed 8 KiB, so a line without a newline was
        // rejected only after up to 8 KiB past the limit had been buffered.
        let (r, w) = pair()
        // 20 KB exceeds the 8 KiB socket buffer: write from another thread.
        let writerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = DeadlinePeer.write(w, Data(repeating: 65, count: 20_000))
            writerDone.signal()
        }
        defer {
            close(r)
            _ = writerDone.wait(timeout: .now() + 2)
            close(w)
        }
        var reader = DaemonClient.LineReader()
        XCTAssertThrowsError(try reader.readLine(fd: r, deadline: DaemonClient.Deadline(timeout: 2), maxBytes: 1000))
        XCTAssertLessThanOrEqual(reader.pending.count, 1001)
    }
}
