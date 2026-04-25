import Foundation
import Darwin

/// Path resolution + safety checks for the daemon's filesystem footprint.
/// Centralizes the `TMPDIR` lookup, `--socket-dir` override, and parent-dir
/// world-writable validation so the rules in the `daemon-security-hardening`
/// change live in one place and can be tested as pure functions.
enum DaemonPaths {

    /// Resolution outcome for a socket directory. Either an absolute path
    /// the daemon should use, or a structured rejection that the CLI maps
    /// to `invalidSocketDir` on stderr.
    enum ResolutionResult: Equatable {
        case ok(String)
        case rejected(reason: RejectionReason, message: String)
    }

    enum RejectionReason: String, Equatable {
        case tmpdirUnset
        case parentWorldWritable
        case parentMissing
    }

    /// Resolve the directory the daemon's socket / pid / log files should
    /// live under. Precedence:
    ///
    /// 1. `socketDir` argument (from `--socket-dir`) — used verbatim
    /// 2. `env["TMPDIR"]` — used if non-empty
    /// 3. Otherwise → `.rejected(.tmpdirUnset, …)` so the daemon refuses to
    ///    start in an unconfigured environment per Requirement: Socket
    ///    and pid file permissions
    ///
    /// This is the function-level equivalent of `Sources/SafariBrowser/Daemon/
    /// DaemonClient.swift`'s historical `pathUnderTmp` but with explicit
    /// rejection of the `/tmp` fallback that the previous code silently
    /// applied. Falling back to `/tmp` was unsafe because `/tmp` is world
    /// writable on macOS unless the system administrator has changed it.
    ///
    /// Pure function — environment is injected so unit tests can drive it
    /// without mutating ProcessInfo.
    static func resolveSocketDir(
        socketDir: String?,
        env: [String: String],
        allowUnsafe: Bool,
        statF: (String) -> Stat? = defaultStatF
    ) -> ResolutionResult {
        let candidate: String
        if let explicit = socketDir, !explicit.isEmpty {
            candidate = explicit
        } else {
            let raw = env["TMPDIR"] ?? ""
            if raw.isEmpty {
                return .rejected(
                    reason: .tmpdirUnset,
                    message: "TMPDIR unset; pass --socket-dir <path> or set TMPDIR before launching the daemon."
                )
            }
            candidate = raw
        }

        let normalized = candidate.hasSuffix("/") ? String(candidate.dropLast()) : candidate

        guard let s = statF(normalized) else {
            return .rejected(
                reason: .parentMissing,
                message: "socket directory does not exist or is not statable: \(normalized)"
            )
        }

        // S_IWOTH (0o002) — world-writable bit. Reject by default to prevent
        // malicious local users from staging socket-takeover attacks via a
        // shared writable directory.
        let worldWritable = (s.mode & 0o002) != 0
        if worldWritable && !allowUnsafe {
            return .rejected(
                reason: .parentWorldWritable,
                message: "\(normalized) is world-writable; pass --allow-unsafe-socket-dir to override (not recommended)."
            )
        }

        return .ok(normalized)
    }

    /// Compose the full socket path under a resolved directory.
    static func composeSocketPath(dir: String, prefix: String, name: String, suffix: String) -> String {
        return "\(dir)/\(prefix)\(name)\(suffix)"
    }

    /// Write a pid file via raw `open(2)` with `O_CREAT|O_WRONLY|O_EXCL`
    /// and explicit mode `0o600` so the file is owner-readable only and
    /// a race that lands between create-and-chmod cannot leak the pid.
    /// Throws if the file already exists or any syscall fails — callers
    /// MUST `unlink` stale pid files before invoking this helper. Per
    /// Requirement: Socket and pid file permissions.
    static func writePidFile(at path: String, pid: Int32) throws {
        let flags = O_CREAT | O_WRONLY | O_EXCL
        let fd = path.withCString { Darwin.open($0, flags, mode_t(0o600)) }
        if fd < 0 {
            throw PidWriteError.openFailed(errno: errno, path: path)
        }
        defer { Darwin.close(fd) }

        let payload = "\(pid)\n"
        let bytes = Array(payload.utf8)
        let written = bytes.withUnsafeBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return Darwin.write(fd, base, buf.count)
        }
        if written != bytes.count {
            throw PidWriteError.writeFailed(errno: errno, written: written, expected: bytes.count)
        }
    }

    enum PidWriteError: Error, CustomStringConvertible {
        case openFailed(errno: Int32, path: String)
        case writeFailed(errno: Int32, written: Int, expected: Int)

        var description: String {
            switch self {
            case .openFailed(let e, let p):
                return "pid file open(\(p)) failed: errno=\(e)"
            case .writeFailed(let e, let w, let exp):
                return "pid file write incomplete: \(w)/\(exp) bytes, errno=\(e)"
            }
        }
    }

    /// Lightweight, testable stat result. Holds the mode bits we care
    /// about so unit tests can fake the filesystem without mocking POSIX.
    struct Stat: Equatable {
        let mode: UInt16
        let isDirectory: Bool
    }
}

/// Real-filesystem `stat(2)` adapter mapping to `DaemonPaths.Stat`. Used as
/// the default for `resolveSocketDir(statF:)` in production callers.
/// Named with a `default` prefix so it does not shadow `Darwin.stat`.
private func defaultStatF(_ path: String) -> DaemonPaths.Stat? {
    // Use `Darwin.stat` for the struct type; call the syscall via the
    // unqualified `stat(_:_:)` function so Swift's overload resolution
    // can pick the C function rather than the same-named struct's
    // zero-arg initializer.
    var sb = Darwin.stat()
    let rc = path.withCString { stat($0, &sb) }
    if rc != 0 { return nil }
    let mode = UInt16(sb.st_mode & 0o777)
    let isDir = (sb.st_mode & S_IFMT) == S_IFDIR
    return DaemonPaths.Stat(mode: mode, isDirectory: isDir)
}
