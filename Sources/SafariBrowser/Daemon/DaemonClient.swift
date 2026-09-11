import Foundation
import Darwin
import CoreFoundation

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
        case requestOutcomeUnknown(String)
        case invalidTimeout

        var description: String {
            switch self {
            case .requestOutcomeUnknown(let r): return "daemon request outcome unknown: \(r); operation may have executed; not retrying"
            case .invalidTimeout: return "daemon invalid timeout: expected finite seconds in 0.001...86400"
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
        /// are classified separately below; only a pre-execution rejection
        /// can authorize retry.
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
            case .requestOutcomeUnknown, .invalidTimeout: return nil
            case .connectFailed(let r):  return "connect: \(r)"
            case .ioError(let r):        return "io: \(r)"
            case .protocolError(let r):  return "protocol: \(r)"
            case .remoteError(let code, let message):
                guard code == "methodNotFound" || code == "versionMismatch" else { return nil }
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

    /// Whole-request budget for ordinary bridge calls. Exec explicitly uses 60 seconds.
    static let defaultTimeoutSeconds: TimeInterval = 15.0

    /// The deadline covers connection, handshake, the request frame, and the
    /// entire response. Once any request bytes are sent, unverified outcomes
    /// must never authorize replay of a potentially mutating operation.
    static func sendRequest(
        name: String,
        method: String,
        params: Data,
        requestId: Int,
        timeout: TimeInterval = defaultTimeoutSeconds,
        socketDir: String? = nil,
        diagnosticsWriter: (@Sendable (String) -> Void)? = nil
    ) async throws -> Data {
        guard timeout.isFinite, (0.001...86400).contains(timeout) else {
            throw Error.invalidTimeout
        }
        let deadline = Deadline(timeout: timeout)
        let path = socketDir.flatMap { $0.isEmpty ? nil : socketPath(dir: $0, name: name) }
            ?? socketPath(name: name)
        // poll/read/write must not occupy Swift's cooperative executor, which
        // may also be running the in-process server awaited by this request.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try exchange(
                        path: path, method: method, params: params,
                        requestId: requestId, deadline: deadline,
                        diagnosticsWriter: diagnosticsWriter
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func exchange(
        path: String, method: String, params: Data, requestId: Int,
        deadline: Deadline, diagnosticsWriter: (@Sendable (String) -> Void)?
    ) throws -> Data {
        let fd = try connectUnixSocket(path: path, deadline: deadline)
        defer { close(fd) }
        var reader = LineReader()
        let handshake = try reader.readLine(fd: fd, deadline: deadline)
        guard let version = DaemonProtocol.decodeHandshakeVersion(handshake) else {
            throw Error.protocolError("invalid handshake")
        }
        guard DaemonProtocol.versionsMatch(server: version, client: DaemonProtocol.currentVersion) else {
            throw Error.remoteError(code: "versionMismatch", message: "daemon \(version.description), client \(DaemonProtocol.currentVersion.description)")
        }
        let paramsValue = try JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed])
        var payload = try JSONSerialization.data(withJSONObject: [
            "method": method, "params": paramsValue, "requestId": requestId
        ])
        payload.append(10)
        try writeFrame(fd: fd, payload: payload, deadline: deadline)

        // Partial-write failures are already classified by writeFrame. A lost
        // or invalid response cannot authorize repeating the operation either.
        do {
            let response = try reader.readLine(fd: fd, deadline: deadline)
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let responseID = object["requestId"] as? NSNumber,
                  CFGetTypeID(responseID) != CFBooleanGetTypeID(),
                  responseID.compare(NSNumber(value: requestId)) == .orderedSame else {
                throw Error.protocolError("missing or mismatched requestId")
            }
            let hasResult = object.keys.contains("result")
            let hasError = object.keys.contains("error")
            guard hasResult != hasError else {
                throw Error.protocolError("response must contain exactly one of result or error")
            }
            let diagnostics: [String]
            if let value = object["diagnostics"] {
                guard let messages = value as? [String] else {
                    throw Error.protocolError("invalid diagnostics")
                }
                diagnostics = messages
            } else {
                diagnostics = []
            }
            var remoteError: Error?
            var result: Data?
            if hasError {
                guard let error = object["error"] as? [String: Any],
                      let code = error["code"] as? String,
                      let message = error["message"] as? String else {
                    throw Error.protocolError("invalid error envelope")
                }
                // Version negotiation belongs to the handshake. A response
                // claiming mismatch after transmission cannot prove nonexecution.
                guard code != "versionMismatch" else {
                    throw Error.protocolError("version mismatch after request transmission")
                }
                remoteError = .remoteError(code: code, message: message)
            } else {
                result = try JSONSerialization.data(withJSONObject: object["result"]!, options: [.fragmentsAllowed])
            }
            for diagnostic in diagnostics {
                let text = diagnostic.hasSuffix("\n") ? diagnostic : diagnostic + "\n"
                if let diagnosticsWriter { diagnosticsWriter(text) }
                else { FileHandle.standardError.write(Data(text.utf8)) }
            }
            if let remoteError { throw remoteError }
            return result!
        } catch let error as Error {
            if case .remoteError = error { throw error }
            throw Error.requestOutcomeUnknown(error.description)
        } catch {
            throw Error.requestOutcomeUnknown("invalid response: \(error)")
        }
    }

    // MARK: - Nonblocking POSIX transport

    private struct Deadline: Sendable {
        let end: UInt64

        init(timeout: TimeInterval) {
            end = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        }

        func remainingMilliseconds() throws -> Int32 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < end else { throw Error.ioError("timeout") }
            // poll rounds upward so sub-millisecond time remains usable.
            return Int32(min((end - now + 999_999) / 1_000_000, UInt64(Int32.max)))
        }

        func wait(fd: Int32, events: Int16) throws {
            while true {
                let remaining = try remainingMilliseconds()
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let ready = Darwin.poll(&descriptor, 1, remaining)
                if ready > 0 {
                    // HUP/ERR are handled by the following read/write/getsockopt.
                    guard descriptor.revents & Int16(POLLNVAL) == 0 else {
                        throw Error.ioError("invalid socket")
                    }
                    _ = try remainingMilliseconds()
                    return
                }
                if ready == 0 { continue }
                if errno != EINTR { throw Error.ioError("poll failed: errno=\(errno)") }
            }
        }
    }

    private static func connectUnixSocket(path: String, deadline: Deadline) throws -> Int32 {
        _ = try deadline.remainingMilliseconds()
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.connectFailed("socket failed: errno=\(errno)") }
        do {
            var enabled: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw Error.connectFailed("socket setup failed: errno=\(errno)")
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path), !bytes.contains(0) else {
                throw Error.connectFailed("invalid socket path")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (i, byte) in bytes.enumerated() { buffer[i] = byte }
                buffer[bytes.count] = 0
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected != 0 {
                guard errno == EINPROGRESS || errno == EINTR else {
                    throw Error.connectFailed("connect failed: errno=\(errno)")
                }
                try deadline.wait(fd: fd, events: Int16(POLLOUT))
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                    throw Error.connectFailed("connect failed: errno=\(socketError == 0 ? errno : socketError)")
                }
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func writeFrame(fd: Int32, payload: Data, deadline: Deadline) throws {
        var written = 0
        do {
            try payload.withUnsafeBytes { bytes in
                while written < bytes.count {
                    _ = try deadline.remainingMilliseconds()
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count > 0 { written += count; continue }
                    if count < 0, errno == EINTR { continue }
                    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        try deadline.wait(fd: fd, events: Int16(POLLOUT))
                        continue
                    }
                    throw Error.ioError("write failed: errno=\(errno)")
                }
            }
        } catch {
            // Older peers accept valid JSON at EOF without its final LF. Even
            // a partial write therefore cannot prove that execution did not start.
            if written > 0 { throw Error.requestOutcomeUnknown("request transmission interrupted: \(error)") }
            throw error
        }
    }

    private struct LineReader {
        var pending = Data()

        mutating func readLine(fd: Int32, deadline: Deadline) throws -> Data {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                _ = try deadline.remainingMilliseconds()
                if let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    return line
                }
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 { pending.append(contentsOf: buffer.prefix(count)); continue }
                if count == 0 { throw Error.ioError("EOF before complete response frame") }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try deadline.wait(fd: fd, events: Int16(POLLIN))
                    continue
                }
                throw Error.ioError("read failed: errno=\(errno)")
            }
        }
    }
}
