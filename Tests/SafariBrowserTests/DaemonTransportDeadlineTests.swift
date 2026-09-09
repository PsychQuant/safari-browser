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
            XCTAssertNotNil(error.fallbackReason, "no full newline-delimited request reached peer")
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
