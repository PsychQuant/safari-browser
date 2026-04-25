import Foundation
import Darwin

/// Client side of the persistent-daemon IPC.
///
/// Task 2.2 implements NAME resolution and a minimal one-shot `sendRequest`
/// helper: open socket, write one JSON line, read one JSON line, close.
/// Silent-fallback integration into `SafariBridge` lands in task 5.1 / 5.2;
/// connection pooling is out of scope for Phase 1.
enum DaemonClient {
    static let envNameKey = "SAFARI_BROWSER_NAME"
    static let defaultName = "default"
    static let socketPrefix = "safari-browser-"
    static let socketSuffix = ".sock"

    enum Error: Swift.Error, CustomStringConvertible {
        case connectFailed(String)
        case ioError(String)
        case protocolError(String)
        case remoteError(code: String, message: String)

        var description: String {
            switch self {
            case .connectFailed(let r): return "daemon connect failed: \(r)"
            case .ioError(let r):       return "daemon io error: \(r)"
            case .protocolError(let r): return "daemon protocol error: \(r)"
            case .remoteError(let c, let m): return "daemon remote error [\(c)]: \(m)"
            }
        }

        /// Set of error code strings that represent Safari domain semantics
        /// rather than daemon transport or infrastructure failures.
        /// When the daemon returns one of these, falling back to the
        /// stateless path would produce the same error (Safari itself is
        /// reporting the condition) so we propagate instead.
        ///
        /// Keep this aligned with `SafariBrowserError` cases that represent
        /// user-facing semantics. Transport-level / daemon-protocol errors
        /// (`parseError`, `methodNotFound`, `handlerError`) are deliberately
        /// NOT in this set so they trigger fallback.
        static let domainErrorCodes: Set<String> = [
            // Section 6 of daemon-security-hardening: a request cancelled by
            // `daemon.shutdown` SHALL surface as `cancelled` to the caller
            // — the request was interrupted intentionally, retrying via the
            // stateless path would race with the dying daemon and produce
            // no useful result. Caller propagates the cancellation.
            "cancelled",
            "ambiguousWindowMatch",
            "documentNotFound",
            "elementNotFound",
            "elementAmbiguous",
            "elementIndexOutOfRange",
            "elementZeroSize",
            "elementOutsideViewport",
            "elementSelectorInvalid",
            "elementHasNoSrc",
            "unsupportedElement",
            "backgroundTabNotCapturable",
            "noSafariWindow",
            "invalidTabIndex",
            "windowIdentityAmbiguous",
            "accessibilityRequired",
            "accessibilityNotGranted",
            "webAreaNotFound",
            "imageCroppingFailed",
            "downloadFailed",
            "downloadSizeCapExceeded",
            "unsupportedURLScheme",
            "systemEventsNotResponding",
            "fileNotFound",
        ]

        /// Classification helper for the silent-fallback router.
        /// Returns the reason to include in the `[daemon fallback: ...]`
        /// stderr warning when this error should trigger fallback, or `nil`
        /// when the error should propagate (Safari domain errors).
        var fallbackReason: String? {
            switch self {
            case .connectFailed(let r):  return "connect: \(r)"
            case .ioError(let r):        return "io: \(r)"
            case .protocolError(let r):  return "protocol: \(r)"
            case .remoteError(let code, let message):
                if Self.domainErrorCodes.contains(code) {
                    return nil
                }
                return message.isEmpty ? "remote \(code)" : "remote \(code): \(message)"
            }
        }
    }

    /// Resolve the daemon namespace from flag / env / default.
    /// Empty strings in either slot are treated as unset (fall through).
    static func resolveName(flag: String?, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let f = flag, !f.isEmpty { return f }
        if let e = env[envNameKey], !e.isEmpty { return e }
        return defaultName
    }

    /// Build the socket path under `$TMPDIR` (fallback `/tmp`) for a given NAME.
    static func socketPath(name: String) -> String {
        return pathUnderTmp(prefix: socketPrefix, name: name, suffix: socketSuffix)
    }

    /// Build the pid file path for a given NAME.
    static func pidPath(name: String) -> String {
        return pathUnderTmp(prefix: socketPrefix, name: name, suffix: ".pid")
    }

    /// Build the log file path for a given NAME.
    static func logPath(name: String) -> String {
        return pathUnderTmp(prefix: socketPrefix, name: name, suffix: ".log")
    }

    /// Build the socket path under an explicit directory. Used when the
    /// caller has an `--socket-dir` override and has already resolved
    /// (or chosen to bypass) the world-writable safety check.
    static func socketPath(dir: String, name: String) -> String {
        return DaemonPaths.composeSocketPath(dir: dir, prefix: socketPrefix, name: name, suffix: socketSuffix)
    }

    /// Build the pid file path under an explicit directory.
    static func pidPath(dir: String, name: String) -> String {
        return DaemonPaths.composeSocketPath(dir: dir, prefix: socketPrefix, name: name, suffix: ".pid")
    }

    /// Build the log file path under an explicit directory.
    static func logPath(dir: String, name: String) -> String {
        return DaemonPaths.composeSocketPath(dir: dir, prefix: socketPrefix, name: name, suffix: ".log")
    }

    private static func pathUnderTmp(prefix: String, name: String, suffix: String) -> String {
        let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        let normalized = tmpDir.hasSuffix("/") ? tmpDir : tmpDir + "/"
        return "\(normalized)\(prefix)\(name)\(suffix)"
    }

    /// Default I/O timeout for daemon requests. Matches the
    /// `Silent fallback to stateless path on daemon failure` spec which
    /// lists 15 seconds as the fifth failure mode.
    static let defaultTimeoutSeconds: TimeInterval = 15.0

    /// Send a single JSON-lines request and await the matching response.
    ///
    /// Opens a fresh connection per request (no pooling in Phase 1).
    /// Throws `Error.connectFailed` if the daemon is unreachable,
    /// `Error.remoteError` if the daemon returns an `error` envelope,
    /// `Error.protocolError` if the response is malformed,
    /// `Error.ioError("timeout")` if the daemon does not respond within
    /// `timeout` seconds.
    static func sendRequest(
        name: String,
        method: String,
        params: Data,
        requestId: Int,
        timeout: TimeInterval = defaultTimeoutSeconds,
        socketDir: String? = nil
    ) async throws -> Data {
        let path: String
        if let dir = socketDir, !dir.isEmpty {
            path = socketPath(dir: dir, name: name)
        } else {
            path = socketPath(name: name)
        }
        let fd = try connectUnixSocket(path: path)
        defer { close(fd) }
        try applySocketTimeout(fd: fd, seconds: timeout)

        // Consume the server's handshake line and verify the protocol
        // version. Mismatch surfaces as a remoteError("versionMismatch")
        // which `Error.fallbackReason` classifies as fallback-worthy.
        guard let handshakeLine = readLine(fd: fd) else {
            throw Error.ioError("no handshake from daemon")
        }
        guard let serverVersion = DaemonProtocol.decodeHandshakeVersion(handshakeLine) else {
            throw Error.protocolError("invalid handshake")
        }
        // Section 5 of daemon-security-hardening: comparison consults
        // dirty + vendor in addition to semver+commit. Any side dirty
        // or vendor mismatch surfaces as `versionMismatch` so the
        // router falls back to the stateless path.
        if !DaemonProtocol.versionsMatch(server: serverVersion, client: DaemonProtocol.currentVersion) {
            throw Error.remoteError(
                code: "versionMismatch",
                message: "daemon \(serverVersion.description), client \(DaemonProtocol.currentVersion.description)"
            )
        }

        let paramsValue: Any = (try? JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed])) ?? [String: Any]()
        let envelope: [String: Any] = [
            "method": method,
            "params": paramsValue,
            "requestId": requestId,
        ]
        let line = try JSONSerialization.data(withJSONObject: envelope, options: [])
        try writeLine(fd: fd, line: line)

        guard let responseLine = readLine(fd: fd) else {
            throw Error.ioError("empty response")
        }
        let parsed = try JSONSerialization.jsonObject(with: responseLine, options: [])
        guard let obj = parsed as? [String: Any] else {
            throw Error.protocolError("response not an object")
        }
        if let errorObj = obj["error"] as? [String: Any] {
            let code = (errorObj["code"] as? String) ?? "unknown"
            let message = (errorObj["message"] as? String) ?? ""
            throw Error.remoteError(code: code, message: message)
        }
        let resultValue = obj["result"] ?? NSNull()
        return try JSONSerialization.data(withJSONObject: resultValue, options: [.fragmentsAllowed])
    }

    // MARK: - POSIX plumbing

    /// Apply `SO_RCVTIMEO` + `SO_SNDTIMEO` to the socket so blocking
    /// `read()` / `write()` calls return with errno `EAGAIN` after the
    /// configured timeout. Callers surface this as `ioError("timeout")`
    /// and the router falls back to the stateless path.
    private static func applySocketTimeout(fd: Int32, seconds: TimeInterval) throws {
        let clamped = max(seconds, 0.001)
        var tv = timeval(
            tv_sec: __darwin_time_t(clamped),
            tv_usec: __darwin_suseconds_t((clamped - Double(Int(clamped))) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size) != 0 {
            throw Error.ioError("SO_RCVTIMEO failed: errno=\(errno)")
        }
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size) != 0 {
            throw Error.ioError("SO_SNDTIMEO failed: errno=\(errno)")
        }
    }

    private static func connectUnixSocket(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Error.connectFailed("socket() failed: errno=\(errno)")
        }
        // Disable SIGPIPE on this fd — when the peer closes early (e.g., after
        // a client-side timeout) we want EPIPE from `write()` rather than a
        // process-wide signal that terminates the test runner.
        var enable: Int32 = 1
        _ = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE,
            &enable, socklen_t(MemoryLayout<Int32>.size)
        )
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathMaxBytes = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let pathBytes = Array(path.utf8)
        if pathBytes.count > pathMaxBytes {
            close(fd)
            throw Error.connectFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() { buf[i] = b }
            buf[pathBytes.count] = 0
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, addrLen)
            }
        }
        if rc != 0 {
            close(fd)
            throw Error.connectFailed("connect() failed: errno=\(errno)")
        }
        return fd
    }

    private static func writeLine(fd: Int32, line: Data) throws {
        var payload = Data(line)
        payload.append(0x0A)
        try payload.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else {
                throw Error.ioError("write buffer empty")
            }
            var written = 0
            while written < rawBuf.count {
                let n = write(fd, base.advanced(by: written), rawBuf.count - written)
                if n <= 0 {
                    throw Error.ioError("write() failed: errno=\(errno)")
                }
                written += n
            }
        }
    }

    private static func readLine(fd: Int32) -> Data? {
        var bytes: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 1)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                read(fd, ptr.baseAddress, 1)
            }
            if n <= 0 {
                if bytes.isEmpty { return nil }
                break
            }
            if buf[0] == 0x0A { break }
            bytes.append(buf[0])
        }
        return Data(bytes)
    }
}
