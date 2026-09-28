import Foundation
import Darwin

/// Path resolution + safety checks for the daemon's filesystem footprint.
/// Centralizes the `TMPDIR` lookup, `--socket-dir` override, and parent-dir
/// world-writable validation so the rules in the `daemon-security-hardening`
/// change live in one place and can be tested as pure functions.
enum DaemonPaths {

    /// device/inode 比對本身不保留 inode；使用時須仍持有來源 fd。
    fileprivate struct EntryMetadata: Sendable, Equatable {
        let device: dev_t
        let inode: ino_t

        init(
            fd: Int32,
            statF: (Int32, UnsafeMutablePointer<Darwin.stat>) -> Int32 = { Darwin.fstat($0, $1) }
        ) throws {
            var info = Darwin.stat()
            guard statF(fd, &info) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            device = info.st_dev
            inode = info.st_ino
        }

        func removeIfMatches(at path: String) -> Bool {
            var info = Darwin.stat()
            return path.withCString { pointer in
                guard Darwin.lstat(pointer, &info) == 0,
                      (info.st_mode & S_IFMT) != S_IFLNK,
                      info.st_dev == device,
                      info.st_ino == inode else { return false }
                return Darwin.unlink(pointer) == 0
            }
        }
    }

    /// 從自有 fd 捕捉檔案身分，讓延遲清理不會刪除已觀察到的替換項目。
    struct EntryIdentity: Sendable, Equatable {
        private let metadata: EntryMetadata
        private let descriptor: OwnedDescriptor

        /// 各份 identity 共享同一個描述元；最後引用釋放才關閉，
        /// 使原項目遭 unlink 後，inode 仍無法被回收並配給替換檔案。
        private final class OwnedDescriptor: Sendable {
            let fd: Int32

            init(duplicating fd: Int32, duplicateF: (Int32) -> Int32) throws {
                let duplicate = duplicateF(fd)
                guard duplicate >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                self.fd = duplicate
            }

            deinit { Darwin.close(fd) }
        }

        init(fd: Int32) throws {
            try self.init(fd: fd, metadata: EntryMetadata(fd: fd))
        }

        fileprivate init(
            fd: Int32,
            metadata: EntryMetadata,
            duplicateF: (Int32) -> Int32 = { Darwin.fcntl($0, F_DUPFD_CLOEXEC, 0) }
        ) throws {
            self.metadata = metadata
            descriptor = try OwnedDescriptor(duplicating: fd, duplicateF: duplicateF)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.metadata == rhs.metadata
        }

        /// 僅在路徑仍指向相同 device/inode 時移除，成功移除才回傳 true。
        /// 不存在、遭替換、符號連結或無法確認的項目一律保留。
        /// lstat 與 unlink 不是原子操作；不保證能抵禦任意同 UID 惡意競態。
        @discardableResult
        func removeIfMatches(at path: String) -> Bool {
            withExtendedLifetime(descriptor) { metadata.removeIfMatches(at: path) }
        }
    }

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
        case parentNotDirectory
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

        // stat follows symlinks: require the observed target to be a directory.
        // The unsafe override only relaxes permissions, never the file type.
        guard s.isDirectory else {
            return .rejected(
                reason: .parentNotDirectory,
                message: "socket path parent is not a directory: \(normalized)"
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
        case encodingFailed(String)

        var description: String {
            switch self {
            case .openFailed(let e, let p):
                return "pid file open(\(p)) failed: errno=\(e)"
            case .writeFailed(let e, let w, let exp):
                return "pid file write incomplete: \(w)/\(exp) bytes, errno=\(e)"
            case .encodingFailed(let r):
                return "pid record encoding failed: \(r)"
            }
        }
    }

    /// Lightweight, testable stat result. Holds the mode bits we care
    /// about so unit tests can fake the filesystem without mocking POSIX.
    struct Stat: Equatable {
        let mode: UInt16
        let isDirectory: Bool
    }

    // MARK: - Section 4: stale-pid liveness detection

    /// Pid file payload. Written as JSON on disk so a future contributor
    /// who reads the file directly gets enough metadata to identify the
    /// running daemon — not just a bare integer. The triple
    /// `(pid, binaryPath, boot)` is what the 3-check liveness probe
    /// verifies before declaring an existing daemon "alive".
    struct PidRecord: Equatable, Codable {
        let pid: Int32
        /// Path to the daemon binary; on disk uses the legacy key name
        /// `exec` so JSON consumers reading the file see a stable schema.
        let exec: String
        /// Process start time, expressed as seconds since the Unix epoch.
        /// Stored with sub-second resolution because `proc_pidinfo`'s
        /// underlying value is microsecond-precise.
        let boot: TimeInterval
    }

    enum PidReadResult: Equatable {
        case ok(PidRecord)
        /// File present but malformed or in the legacy single-integer
        /// format. Caller MUST overwrite with a fresh record.
        case stale(reason: String)
        /// File does not exist.
        case absent
    }

    /// Probe the OS for live-process state. Each closure can be replaced
    /// in tests so the 3-check rule is exercised without spawning real
    /// processes. `.real` is the production binding.
    struct PidProbe: Sendable {
        let killExists: @Sendable (Int32) -> Bool
        let exec: @Sendable (Int32) -> String?
        let bootTime: @Sendable (Int32) -> TimeInterval?

        static let real = PidProbe(
            killExists: { pid in
                if Darwin.kill(pid, 0) == 0 { return true }
                // EPERM means alive but owned by another uid; ESRCH means dead.
                return errno == EPERM
            },
            exec: { pid in
                let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
                defer { buf.deallocate() }
                let n = proc_pidpath(pid, buf, UInt32(4096))
                guard n > 0 else { return nil }
                return String(
                    decoding: UnsafeBufferPointer(
                        start: buf.assumingMemoryBound(to: UInt8.self),
                        count: Int(n)
                    ),
                    as: UTF8.self
                )
            },
            bootTime: { pid in
                var info = proc_bsdinfo()
                let size = MemoryLayout<proc_bsdinfo>.size
                let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
                guard n == Int32(size) else { return nil }
                return TimeInterval(info.pbi_start_tvsec) +
                    TimeInterval(info.pbi_start_tvusec) / 1_000_000.0
            }
        )
    }

    /// Boot-time tolerance window for liveness check. `proc_pidinfo`'s
    /// underlying microsecond fields are fixed-precision integers; round
    /// tripping through our `TimeInterval` (Double) can drift by a sub-
    /// second; ±2 seconds gives generous margin without admitting a
    /// reasonably-timed pid recycle (a fork in the same second is
    /// extremely rare and would still need to match exec path, which is
    /// the strongest of the three checks).
    static let bootTimeTolerance: TimeInterval = 2.0

    /// Capture a `PidRecord` for the current process. Returns nil when
    /// either `proc_pidpath` or `proc_pidinfo` fails for self — that
    /// would indicate a kernel-level oddity and the daemon should
    /// refuse to write a malformed pid file.
    static func currentPidRecord() -> PidRecord? {
        let pid = Darwin.getpid()
        guard let path = PidProbe.real.exec(pid),
              let boot = PidProbe.real.bootTime(pid) else {
            return nil
        }
        return PidRecord(pid: pid, exec: path, boot: boot)
    }

    /// Pure liveness rule per Requirement: Stale-pid file liveness
    /// detection. ALL THREE checks must pass:
    ///
    /// 1. `kill(pid, 0)` reports the pid is alive.
    /// 2. `proc_pidpath(pid)` matches the recorded binary path exactly
    ///    (string equality — no path canonicalization, since the daemon
    ///    captures the path it was launched with and a reasonable
    ///    contributor doesn't move binaries during a daemon's life).
    /// 3. `proc_pidinfo` start-time within `bootTimeTolerance` of the
    ///    recorded `boot` value.
    ///
    /// Any single failure → not alive (i.e. stale pid file). Defensive
    /// skew: nil exec or nil boot from the probe → not alive, since we
    /// cannot verify identity.
    static func isProcessAlive(record: PidRecord, probe: PidProbe) -> Bool {
        guard probe.killExists(record.pid) else { return false }
        guard let livePath = probe.exec(record.pid), livePath == record.exec else { return false }
        guard let liveBoot = probe.bootTime(record.pid) else { return false }
        return abs(liveBoot - record.boot) <= bootTimeTolerance
    }

    /// Read a pid file from disk. Returns `.absent` if the file
    /// doesn't exist; `.stale` if the file contains either the legacy
    /// single-integer format or malformed JSON or a JSON record missing
    /// any required field; `.ok(record)` only when all three fields
    /// decode cleanly.
    static func readPidFile(at path: String) -> PidReadResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return .absent
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .stale(reason: "unreadable")
        }
        // Cheap legacy-format probe: a single integer (or bare integer
        // followed by newline) is what the prior version wrote.
        if let s = String(data: data, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if Int(trimmed) != nil {
                return .stale(reason: "legacy single-integer format")
            }
        }
        // Strict JSON decode — missing fields → stale.
        do {
            let record = try JSONDecoder().decode(PidRecord.self, from: data)
            return .ok(record)
        } catch {
            return .stale(reason: "decode failed: \(error)")
        }
    }

    /// Write a `PidRecord` as JSON via raw `open(2) + O_CREAT|O_WRONLY|O_EXCL
    /// + mode 0o600`. Mirrors the legacy `writePidFile(at:pid:)` semantics:
    /// callers MUST `unlink` first if a stale file may exist. The mode
    /// guarantees the inode is owner-readable only — even though the
    /// JSON content is non-secret, keeping the mode tight matches the
    /// established socket / pid file permissions contract.
    /// 回傳從建立的 fd 捕捉之身分，供所屬 Run 在停止時條件式清理。
    @discardableResult
    static func writePidFile(
        record: PidRecord,
        at path: String,
        writeF: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) },
        statF: (Int32, UnsafeMutablePointer<Darwin.stat>) -> Int32 = { Darwin.fstat($0, $1) },
        duplicateF: (Int32) -> Int32 = { Darwin.fcntl($0, F_DUPFD_CLOEXEC, 0) }
    ) throws -> EntryIdentity {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(record)
        } catch {
            throw PidWriteError.encodingFailed("\(error)")
        }

        let flags = O_CREAT | O_WRONLY | O_EXCL
        let fd = path.withCString { Darwin.open($0, flags, mode_t(0o600)) }
        if fd < 0 {
            throw PidWriteError.openFailed(errno: errno, path: path)
        }
        defer { Darwin.close(fd) }
        // fstat 無法確認身分時保留 entry；原 fd 仍由 defer 關閉。
        let metadata = try EntryMetadata(fd: fd, statF: statF)
        do {
            let identity = try EntryIdentity(fd: fd, metadata: metadata, duplicateF: duplicateF)
            var bytes = Array(payload)
            bytes.append(0x0A) // trailing newline so `cat` looks tidy
            let written = bytes.withUnsafeBufferPointer { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return writeF(fd, base, buf.count)
            }
            if written != bytes.count {
                throw PidWriteError.writeFailed(errno: errno, written: written, expected: bytes.count)
            }
            return identity
        } catch {
            // 即使 dup 失敗，原 fd 仍保留已確認的 inode，可安全比對已觀察到的替換。
            // 先捕捉錯誤再清理，避免 lstat/unlink 改寫原始 errno。
            _ = metadata.removeIfMatches(at: path)
            throw error
        }
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
