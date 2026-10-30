import Darwin
import Foundation
import XCTest

@testable import SafariBrowser

/// #304 verify round 1: once two builds really do mismatch, `daemon stop` and
/// `daemon status` must still reach a daemon of another build. Before the fix
/// the client refused before sending anything, so the documented recovery
/// (`daemon stop`, then `daemon start`) timed out after an upgrade.
final class DaemonLifecycleAcrossBuildsTests: XCTestCase {

    /// A daemon of another build: it sends a handshake with a different
    /// identity, records the one request line it gets, and answers it.
    private final class OtherBuildDaemon: @unchecked Sendable {
        let name = "x304"
        let directory: URL
        private let lock = NSLock()
        private var received = Data()
        private let done = DispatchSemaphore(value: 0)

        init(version: DaemonProtocol.Version) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("x304-" + String(UUID().uuidString.prefix(8)))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let path = DaemonClient.socketPath(dir: directory.path, name: name)
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw POSIXError(.EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
            let rc = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0, listen(listener, 1) == 0 else { close(listener); throw POSIXError(.EIO) }
            var header = DaemonProtocol.encodeHandshake(version: version)
            header.append(10)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { close(listener); done.signal() }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                var on: Int32 = 1, timeout = timeval(tv_sec: 2, tv_usec: 0)
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = header.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                var line = Data(), byte: UInt8 = 0
                while read(client, &byte, 1) == 1 {
                    line.append(byte)
                    if byte == 10 { break }
                }
                lock.withLock { received = line }
                if !line.isEmpty {
                    let reply = Data("{\"requestId\":1,\"result\":{\"pid\":4242}}\n".utf8)
                    _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                }
            }
        }

        func request(_ method: String, observer: (@Sendable (DaemonProtocol.Version) -> Void)? = nil) async throws -> Data {
            try await DaemonClient.sendRequest(name: name, method: method, params: Data("{}".utf8), requestId: 1,
                                               timeout: 2, socketDir: directory.path, handshakeObserver: observer)
        }

        /// The request line the daemon got (empty when nothing was sent).
        func receivedLine() -> String {
            _ = done.wait(timeout: .now() + 3)
            return lock.withLock { String(decoding: received, as: UTF8.self) }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// Another build by construction: this test binary's own identity with a
    /// different commit (verify round 2: a fixed value could equal the stamp).
    private let otherBuild = DaemonProtocol.Version(
        semver: DaemonProtocol.currentVersion.semver, commit: DaemonProtocol.currentVersion.commit + "-other",
        dirty: false, vendor: DaemonProtocol.currentVersion.vendor)

    func testShutdownReachesADaemonOfAnotherBuild() async throws {
        XCTAssertFalse(DaemonProtocol.versionsMatch(server: otherBuild, client: DaemonProtocol.currentVersion))
        let daemon = try OtherBuildDaemon(version: otherBuild)
        _ = try await daemon.request("daemon.shutdown")
        XCTAssertTrue(daemon.receivedLine().contains("\"daemon.shutdown\""))
    }

    func testStatusReachesADaemonOfAnotherBuildAndReportsItsIdentity() async throws {
        let daemon = try OtherBuildDaemon(version: otherBuild)
        let seen = LockedBox<DaemonProtocol.Version?>(nil)
        let reply = try await daemon.request("daemon.status", observer: { seen.set($0) })
        XCTAssertTrue(daemon.receivedLine().contains("\"daemon.status\""))
        XCTAssertEqual(seen.get(), otherBuild)
        let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        XCTAssertEqual(object?["pid"] as? Int, 4242)
    }

    /// Every other method keeps the gate: nothing is sent, and the mismatch is
    /// a fallback reason, not an unknown outcome.
    func testOtherMethodsStillSendNothingToAnotherBuild() async throws {
        for method in ["js", "snapshot", "exec.runScript", "daemon.statuses", "DAEMON.SHUTDOWN"] {
            let daemon = try OtherBuildDaemon(version: otherBuild)
            do {
                _ = try await daemon.request(method)
                XCTFail("\(method): expected versionMismatch")
            } catch DaemonClient.Error.remoteError(let code, _) {
                XCTAssertEqual(code, "versionMismatch", method)
            }
            XCTAssertEqual(daemon.receivedLine(), "", method)
        }
    }

    /// The exemption is a closed list of two; a lifecycle method added to the
    /// server later fails here until someone decides whether it may cross builds.
    func testTheExemptMethodsAreExactlyTheServersLifecycleMethods() {
        XCTAssertEqual(DaemonProtocol.buildIndependentMethods, ["daemon.shutdown", "daemon.status"])
        XCTAssertEqual(Set(DaemonServer.Instance.LifecycleMethod.allCases.map(\.rawValue)),
                       DaemonProtocol.buildIndependentMethods)
        XCTAssertTrue(DaemonProtocol.isBuildIndependent(method: "daemon.shutdown"))
        XCTAssertTrue(DaemonProtocol.isBuildIndependent(method: "daemon.status"))
        for other in ["js", "daemon.start", "daemon.logs", "", "daemon.status "] {
            XCTAssertFalse(DaemonProtocol.isBuildIndependent(method: other), other)
        }
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.withLock { value = v } }
    func get() -> T { lock.withLock { value } }
}
