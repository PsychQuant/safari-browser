import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonRequestPreflightTests: XCTestCase {
    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func record(_ value: Data) { lock.withLock { bytes = value } }
        var received: Data { lock.withLock { bytes } }
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func set() { lock.withLock { stopped = true } }
        var value: Bool { lock.withLock { stopped } }
    }

    /// One owned peer. Only its worker closes descriptors; stop asks it to
    /// finish rather than closing a descriptor that accept/read might reuse.
    private final class Peer: @unchecked Sendable {
        let name = "owned"
        let directory: URL
        let path: String
        let observed = Observation()
        private let stopped = StopFlag()
        private let group = DispatchGroup()

        init(limitJSON: String?, rejectAfterBytes: Int? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("p202-" + String(UUID().uuidString.prefix(8)))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            path = DaemonClient.socketPath(dir: directory.path, name: name)
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw POSIXError(.EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
                close(listener); throw POSIXError(.ENAMETOOLONG)
            }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
            let rc = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0, listen(listener, 2) == 0,
                  fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK) == 0 else {
                close(listener); throw POSIXError(.EIO)
            }
            let observed = observed, stopped = stopped, group = group
            var handshake = String(decoding: DaemonProtocol.encodeHandshake(), as: UTF8.self)
            if let limitJSON {
                // Preserve raw numeric spelling for strict capability tests.
                let root = try JSONSerialization.jsonObject(with: Data(handshake.utf8)) as! [String: Any]
                let proto = root["protocol"] as! [String: Any]
                let version = try JSONSerialization.data(withJSONObject: proto["version"]!)
                handshake = "{\"protocol\":{\"name\":\"persistent-daemon\",\"version\":" + String(decoding: version, as: UTF8.self) + ",\"maxRequestLineBytes\":" + limitJSON + "}}"
            }
            let header = Data((handshake + "\n").utf8)
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { close(listener); group.leave() }
                var client: Int32 = -1
                while !stopped.value {
                    var state = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                    if poll(&state, 1, 20) > 0 {
                        client = Darwin.accept(listener, nil, nil)
                        if client >= 0 { break }
                    }
                }
                guard client >= 0 else { return }
                defer { close(client) }
                var enabled: Int32 = 1, timeout = timeval(tv_sec: 1, tv_usec: 0)
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                guard Self.write(client, header) else { return }
                var request = Data(), byte: UInt8 = 0
                while request.count < (rejectAfterBytes ?? (1024 * 1024)), Darwin.read(client, &byte, 1) == 1 {
                    request.append(byte)
                    if byte == 10 { break }
                }
                observed.record(request)
                if rejectAfterBytes == nil, !request.isEmpty { _ = Self.write(client, Data("{\"requestId\":7,\"result\":true}\n".utf8)) }
            }
        }

        private static func write(_ fd: Int32, _ data: Data) -> Bool {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { return false }
                    offset += n
                }
                return true
            }
        }

        func request(params: Data) async throws -> Data {
            try await DaemonClient.sendRequest(name: name, method: "fixture.request", params: params,
                requestId: 7, timeout: 2, socketDir: directory.path)
        }
        func wait() -> Bool { group.wait(timeout: .now() + 2) == .success }
        func stop() { stopped.set(); _ = group.wait(timeout: .now() + 2) }
        deinit { stop(); unlink(path); try? FileManager.default.removeItem(at: directory) }
    }

    func testAdvertisedLimitRejectsBeforeAnyRequestByte() async throws {
        let peer = try Peer(limitJSON: "\"64\"")
        defer { peer.stop() }
        let params = try JSONSerialization.data(withJSONObject: ["source": String(repeating: "x", count: 100)])
        do {
            _ = try await peer.request(params: params)
            XCTFail("advertised request limit must be checked before transmission")
        } catch let error as DaemonClient.Error {
            XCTAssertTrue(error.description.contains("request too large"))
            XCTAssertNil(error.fallbackReason)
        }
        XCTAssertTrue(peer.wait())
        XCTAssertEqual(peer.observed.received.count, 0)
    }

    func testMalformedAdvertisementsSendNoRequestBytes() async throws {
        for scalar in ["null", "true", "false", "1024", "\"01\"", "\" 1\"", "\"١\"", "\"9223372036854775808\"", "1.5", "0", "-1", "9223372036854775808", "{}", "[]"] {
            let peer = try Peer(limitJSON: scalar)
            defer { peer.stop() }
            do {
                _ = try await peer.request(params: Data("{}".utf8))
                XCTFail("invalid limit accepted: \(scalar)")
            } catch let error as DaemonClient.Error {
                guard case .protocolError(let reason) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(reason, "invalid handshake")
                XCTAssertNotNil(error.fallbackReason, "preserve existing pre-send handshake classification")
            }
            XCTAssertTrue(peer.wait())
            XCTAssertTrue(peer.observed.received.isEmpty, scalar)
        }
    }

    func testExactEncodedBoundaryIncludesEnvelopeEscapesAndUTF8() async throws {
        // Literal frames are independent expected byte counts. Key ordering
        // changes do not affect these examples' encoded size.
        let cases = [
            (#"{}"#, #"{"method":"fixture.request","params":{},"requestId":7}"#),
            (#"{ "value" : "\u53f0\u7063\n\"\\" }"#, #"{"method":"fixture.request","params":{"value":"台灣\n\"\\"},"requestId":7}"#),
            (#"{"value":"台灣\n\"\\"}"#, #"{"method":"fixture.request","params":{"value":"台灣\n\"\\"},"requestId":7}"#)
        ]
        for (paramsText, frameText) in cases {
            let expectedBytes = frameText.utf8.count
            for limit in [expectedBytes, expectedBytes - 1] {
                let peer = try Peer(limitJSON: "\"\(limit)\"")
                defer { peer.stop() }
                do {
                    let result = try await peer.request(params: Data(paramsText.utf8))
                    XCTAssertEqual(limit, expectedBytes, "one byte over limit must reject")
                    XCTAssertEqual(result, Data("true".utf8))
                } catch let error as DaemonClient.Error {
                    guard case .requestTooLarge(let actual, let reportedLimit) = error else { return XCTFail("\(error)") }
                    XCTAssertEqual(limit, expectedBytes - 1)
                    XCTAssertEqual(actual, expectedBytes)
                    XCTAssertEqual(reportedLimit, limit)
                }
                XCTAssertTrue(peer.wait())
                XCTAssertEqual(peer.observed.received.count, limit == expectedBytes ? expectedBytes + 1 : 0)
                if limit == expectedBytes {
                    let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: peer.observed.received) as? [String: Any])
                    let params = try JSONSerialization.jsonObject(with: Data(paramsText.utf8)) as? NSDictionary
                    XCTAssertEqual(frame["params"] as? NSDictionary, params)
                }
            }
        }
    }

    func testKnownOversizeDoesNotFallbackOrDiscloseSource() async throws {
        let peer = try Peer(limitJSON: "\"64\"")
        defer { peer.stop() }
        let secret = "owned-fixture-private-source-" + String(repeating: "q", count: 100)
        let params = try JSONSerialization.data(withJSONObject: ["source": secret])
        var fallbackCalls = 0
        do {
            _ = try await SafariBridge.runViaRouter(source: secret, daemonOptIn: true,
                daemonFn: { _ in String(decoding: try await peer.request(params: params), as: UTF8.self) },
                statelessFn: { _ in fallbackCalls += 1; return "replayed" })
            XCTFail("known oversize request must fail")
        } catch let error as DaemonClient.Error {
            guard case .requestTooLarge = error else { return XCTFail("\(error)") }
            XCTAssertNil(error.fallbackReason)
            XCTAssertTrue(error.description.contains("no request bytes sent for this RPC"))
            XCTAssertTrue(error.description.contains("reduce the request size"))
            XCTAssertFalse(error.description.contains(secret))
            XCTAssertFalse(error.description.contains("requestId"))
        }
        XCTAssertEqual(fallbackCalls, 0)
        XCTAssertTrue(peer.wait())
        XCTAssertTrue(peer.observed.received.isEmpty)
    }

    func testLegacyAndInaccuratePeerRejectionsAfterSendRemainUnknown() async throws {
        for advertisement in [nil, "\"5000000\""] as [String?] {
            for sourceBytes in [4000, 4_000_000] {
                let peer = try Peer(limitJSON: advertisement, rejectAfterBytes: 1025)
                defer { peer.stop() }
                let params = try JSONSerialization.data(withJSONObject: ["source": String(repeating: "x", count: sourceBytes)])
                var fallbackCalls = 0
                do {
                    _ = try await SafariBridge.runViaRouter(source: "owned request", daemonOptIn: true,
                        daemonFn: { _ in String(decoding: try await peer.request(params: params), as: UTF8.self) },
                        statelessFn: { _ in fallbackCalls += 1; return "replayed" })
                    XCTFail("peer rejection cannot succeed")
                } catch let error as DaemonClient.Error {
                    guard case .requestOutcomeUnknown(let reason) = error else { return XCTFail("\(error)") }
                    if sourceBytes == 4_000_000 {
                        XCTAssertTrue(reason.contains("request transmission interrupted"), reason)
                    }
                    XCTAssertNil(error.fallbackReason)
                }
                XCTAssertEqual(fallbackCalls, 0)
                XCTAssertTrue(peer.wait())
                XCTAssertEqual(peer.observed.received.count, 1025, "prove actual transmission before rejection")
            }
        }
    }

    func testLegacyPeerWithoutLimitRetainsExistingRequestBehavior() async throws {
        let peer = try Peer(limitJSON: nil)
        defer { peer.stop() }
        let params = try JSONSerialization.data(withJSONObject: ["source": String(repeating: "x", count: 100)])
        let result = try await peer.request(params: params)
        XCTAssertEqual(result, Data("true".utf8))
        XCTAssertTrue(peer.wait())
        XCTAssertGreaterThan(peer.observed.received.count, 64)
    }
}
