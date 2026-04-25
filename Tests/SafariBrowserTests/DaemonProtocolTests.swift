import XCTest
import Foundation
@testable import SafariBrowser

/// Task 6.3 — wire-level protocol helpers. Covers handshake encoding,
/// handshake parsing, the `versionMismatch` error code's classification
/// as fallback-worthy, and a raw end-to-end flow where a listener emits
/// a wrong-version handshake and the client surfaces `remoteError`.
final class DaemonProtocolTests: XCTestCase {

    // MARK: - encode / decode round trip

    func testEncodeHandshake_containsVersion() throws {
        let data = DaemonProtocol.encodeHandshake()
        let obj = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let proto = obj?["protocol"] as? [String: Any]
        // Section 5: version is now a structured dict with semver/commit/dirty/vendor.
        let versionDict = proto?["version"] as? [String: Any]
        XCTAssertEqual(versionDict?["semver"] as? String, DaemonProtocol.currentVersion.semver)
        XCTAssertEqual(versionDict?["commit"] as? String, DaemonProtocol.currentVersion.commit)
    }

    func testEncodeHandshake_containsProtocolName() throws {
        let data = DaemonProtocol.encodeHandshake()
        let obj = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let proto = obj?["protocol"] as? [String: Any]
        XCTAssertEqual(proto?["name"] as? String, "persistent-daemon")
    }

    func testDecodeHandshake_validLine_returnsVersion() {
        let v = DaemonProtocol.Version(semver: "2.1.3", commit: "abcdef12", dirty: false, vendor: .git)
        let data = DaemonProtocol.encodeHandshake(version: v)
        XCTAssertEqual(DaemonProtocol.decodeHandshakeVersion(data), v)
    }

    func testDecodeHandshake_missingProtocolKey_returnsNil() {
        let data = Data(#"{"result":{}}"#.utf8)
        XCTAssertNil(DaemonProtocol.decodeHandshakeVersion(data))
    }

    func testDecodeHandshake_garbageLine_returnsNil() {
        let data = Data("not json".utf8)
        XCTAssertNil(DaemonProtocol.decodeHandshakeVersion(data))
    }

    func testDecodeHandshake_protocolButNoVersion_returnsNil() {
        let data = Data(#"{"protocol":{"name":"x"}}"#.utf8)
        XCTAssertNil(DaemonProtocol.decodeHandshakeVersion(data))
    }

    // MARK: - versionMismatch classification

    func testVersionMismatchError_isFallbackWorthy() {
        let err = DaemonClient.Error.remoteError(
            code: "versionMismatch",
            message: "daemon v0.1.0, client v1.0.0"
        )
        XCTAssertNotNil(err.fallbackReason,
            "version mismatch must trigger silent fallback to stateless path")
    }

    // MARK: - End-to-end: a listener that emits wrong version

    /// Spin up a raw POSIX listener that accepts exactly one connection,
    /// writes a handshake with a bogus version, and closes. `DaemonClient.sendRequest`
    /// must surface the mismatch as `remoteError("versionMismatch", ...)`.
    func testSendRequest_mismatchedServerVersion_raisesVersionMismatch() async throws {
        let name = "mm-\(UUID().uuidString.prefix(8))"
        let socketPath = DaemonClient.socketPath(name: String(name))

        let listenerFd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listenerFd, 0)
        defer { close(listenerFd); unlink(socketPath) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() { buf[i] = b }
            buf[pathBytes.count] = 0
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenerFd, sa, addrLen)
            }
        }
        XCTAssertEqual(bindRC, 0)
        XCTAssertEqual(Darwin.listen(listenerFd, 4), 0)

        // Ignore SIGPIPE so the close-after-handshake doesn't kill the test.
        var enable: Int32 = 1
        _ = setsockopt(listenerFd, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size))

        // Accept one connection in the background, write bogus handshake, close.
        let acceptTask = Task.detached {
            let clientFd = accept(listenerFd, nil, nil)
            guard clientFd >= 0 else { return }
            var enableC: Int32 = 1
            _ = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &enableC, socklen_t(MemoryLayout<Int32>.size))
            let bogusVersion = DaemonProtocol.Version(
                semver: "99.99.99",
                commit: "deadbeef",
                dirty: false,
                vendor: .git
            )
            let bogus = DaemonProtocol.encodeHandshake(version: bogusVersion)
            var payload = Data(bogus)
            payload.append(0x0A)
            _ = payload.withUnsafeBytes { rawBuf -> Int in
                write(clientFd, rawBuf.baseAddress, rawBuf.count)
            }
            close(clientFd)
        }
        defer { acceptTask.cancel() }

        do {
            _ = try await DaemonClient.sendRequest(
                name: String(name),
                method: "anything",
                params: Data("{}".utf8),
                requestId: 1,
                timeout: 2.0
            )
            XCTFail("expected versionMismatch remoteError")
        } catch DaemonClient.Error.remoteError(let code, _) {
            XCTAssertEqual(code, "versionMismatch")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
