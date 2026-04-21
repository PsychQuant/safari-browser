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
        let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        let normalized = tmpDir.hasSuffix("/") ? tmpDir : tmpDir + "/"
        return "\(normalized)\(socketPrefix)\(name)\(socketSuffix)"
    }

    /// Send a single JSON-lines request and await the matching response.
    ///
    /// Opens a fresh connection per request (no pooling in Phase 1).
    /// Throws `Error.connectFailed` if the daemon is unreachable,
    /// `Error.remoteError` if the daemon returns an `error` envelope,
    /// `Error.protocolError` if the response is malformed.
    static func sendRequest(
        name: String,
        method: String,
        params: Data,
        requestId: Int
    ) async throws -> Data {
        let path = socketPath(name: name)
        let fd = try connectUnixSocket(path: path)
        defer { close(fd) }

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

    private static func connectUnixSocket(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Error.connectFailed("socket() failed: errno=\(errno)")
        }
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
