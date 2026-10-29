import CryptoKit
import Darwin
import Foundation

// MARK: - Injected dependencies (#314)

/// Where releases come from. The live implementation talks to GitHub; tests use a fake.
protocol SelfUpdateReleaseSource: Sendable {
    func latest() async throws -> SelfUpdateRelease
    /// Fetch `url`, failing as soon as more than `limit` bytes have arrived.
    func download(_ url: URL, limit: Int) async throws -> Data
}

/// Identity checks. `checkInstalled` runs before anything is downloaded;
/// `checkRunningIsInstalled` confirms this process is the installed binary (so a
/// run started before another update finished cannot overwrite it);
/// `checkCandidate(candidate, installed)` runs before the candidate is executed.
struct SelfUpdateSignatureVerifier: Sendable {
    var checkInstalled: @Sendable (URL) throws -> Void
    var checkCandidate: @Sendable (_ candidate: URL, _ installed: URL) throws -> Void
    var checkRunningIsInstalled: @Sendable (URL) throws -> Void = { _ in }
}

struct SelfUpdateDaemonResult: Equatable, Sendable {
    let name: String
    let stopped: Bool
}

/// What the daemon step did: the directory it looked in (nil when it could not be
/// resolved, so nothing was looked for) and what it found there.
struct SelfUpdateDaemonReport: Equatable, Sendable {
    let directory: String?
    let results: [SelfUpdateDaemonResult]
}

struct SelfUpdateDaemonStopper: Sendable {
    var stopAll: @Sendable () async -> SelfUpdateDaemonReport
}

typealias SelfUpdateVersionProbe = @Sendable (URL) async throws -> String

// MARK: - Checksum

enum SelfUpdateChecksum {
    /// The `.sha256` asset `scripts/release.sh` writes: the hash alone, one line.
    static func parse(_ data: Data) throws -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        guard text.utf8.count == 64,
              text.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw SelfUpdateError.checksumFormat
        }
        return text
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Orchestration

struct SelfUpdateCheckResult: Equatable {
    let installed: String
    let latest: String?
    let status: SelfUpdateStatus
    let error: String?
}

enum SelfUpdateOutcome: Equatable {
    case replaced(from: String, to: String, target: String, daemons: SelfUpdateDaemonReport)
    case upToDate(String)
    case ahead(installed: String, latest: String)
}

struct SelfUpdater: Sendable {
    let installedVersion: String
    /// The path this process was started from; symlinks are resolved before use.
    let executable: URL
    let source: any SelfUpdateReleaseSource
    let verifier: SelfUpdateSignatureVerifier
    let probe: SelfUpdateVersionProbe
    let daemons: SelfUpdateDaemonStopper

    /// Look up and compare. Downloads no binary and writes nothing.
    func check() async -> SelfUpdateCheckResult {
        do {
            let release = try await source.latest()
            return SelfUpdateCheckResult(
                installed: installedVersion, latest: release.tag,
                status: SelfUpdateVersion.classify(installed: installedVersion, latestTag: release.tag), error: nil)
        } catch {
            return SelfUpdateCheckResult(installed: installedVersion, latest: nil, status: .lookupFailed,
                                         error: Self.oneLine("\(error)"))
        }
    }

    /// Download, verify, and replace — in that order, stopping at the first failure.
    func update() async throws -> SelfUpdateOutcome {
        let release = try await source.latest()
        switch SelfUpdateVersion.classify(installed: installedVersion, latestTag: release.tag) {
        case .upToDate: return .upToDate(release.tag)
        case .ahead: return .ahead(installed: installedVersion, latest: release.tag)
        case .notComparable, .lookupFailed: throw SelfUpdateError.notComparable(installedVersion)
        case .updateAvailable: break
        }

        let target = try Self.resolve(executable)
        try verifier.checkInstalled(target)
        let directory = target.deletingLastPathComponent()
        guard access(directory.path, W_OK) == 0 else { throw SelfUpdateError.notWritable(directory.path) }

        // One update at a time per install directory, held until this function returns.
        let lock = try Self.acquireLock(in: directory)
        defer { close(lock) }
        // Under the lock: the installed binary must still be the one running, or a
        // run that finished meanwhile already replaced it (and this run would turn
        // the rollback point into a copy of the new version).
        try verifier.checkRunningIsInstalled(target)
        // Files an interrupted run (signal, crash, power loss) could not remove.
        Self.sweepLeftovers(in: directory)

        let expected = try SelfUpdateChecksum.parse(
            try await source.download(release.checksumURL, limit: SelfUpdateConstants.maxChecksumBytes))
        let binary = try await source.download(release.binaryURL, limit: SelfUpdateConstants.maxBinaryBytes)
        // Checked in memory: unverified bytes never reach the install directory.
        let actual = SelfUpdateChecksum.sha256Hex(binary)
        guard actual == expected else { throw SelfUpdateError.checksumMismatch(expected: expected, actual: actual) }

        let staged = try Self.stage(binary, in: directory)
        var installed = false
        defer { if !installed { unlink(staged.path) } }

        try verifier.checkCandidate(staged, target)
        // Executable only once its signature has passed.
        guard chmod(staged.path, 0o755) == 0 else {
            throw SelfUpdateError.staging(String(cString: strerror(errno)))
        }
        let reported = try await probe(staged)
        guard reported == release.tag else {
            throw SelfUpdateError.versionMismatch(expected: release.tag, actual: Self.oneLine(reported))
        }
        try Self.install(staged: staged, over: target)
        installed = true

        let report = await daemons.stopAll()
        return .replaced(from: installedVersion, to: release.tag, target: target.path, daemons: report)
    }

    // MARK: Filesystem steps

    static func resolve(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw SelfUpdateError.locate("\(url.path): \(String(cString: strerror(errno)))")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// An exclusive, non-blocking `flock` on a lock file next to the target.
    /// Returns the descriptor; closing it releases the lock.
    static func acquireLock(in directory: URL) throws -> Int32 {
        let path = directory.appendingPathComponent(SelfUpdateConstants.lockName).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SelfUpdateError.staging("\(path): \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno == EWOULDBLOCK ? "another self-update is running in \(directory.path)"
                                              : String(cString: strerror(errno))
            close(fd)
            throw SelfUpdateError.busy(reason)
        }
        return fd
    }

    /// Remove regular files this tool names `<prefix>XXXXXX` (the `mkstemp`
    /// shape) — staged downloads and backup links an interrupted run left behind.
    /// Called with the lock held, so no other run's files can match.
    static func sweepLeftovers(in directory: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in entries {
            guard let prefix = [SelfUpdateConstants.stagingPrefix, SelfUpdateConstants.backupStagingPrefix]
                .first(where: { name.hasPrefix($0) }) else { continue }
            let suffix = name.dropFirst(prefix.count)
            guard suffix.count == 6, suffix.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII })
            else { continue }
            let path = directory.appendingPathComponent(name).path
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { continue }
            unlink(path)
        }
    }

    /// Write `data` to a fresh `mkstemp` file (mode 0600) next to the target —
    /// same filesystem, so the final `rename` is atomic — and flush it.
    static func stage(_ data: Data, in directory: URL) throws -> URL {
        let (fd, path) = try temporaryFile(in: directory, prefix: SelfUpdateConstants.stagingPrefix)
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(path) }
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
        guard written, fsync(fd) == 0 else { throw SelfUpdateError.staging(String(cString: strerror(errno))) }
        ok = true
        return URL(fileURLWithPath: path)
    }

    private static func temporaryFile(in directory: URL, prefix: String) throws -> (Int32, String) {
        var template = Array((directory.path + "/" + prefix + "XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw SelfUpdateError.staging(String(cString: strerror(errno))) }
        return (fd, String(cString: template))
    }

    /// Put the backup in place first, then the new binary:
    /// 1. hard-link the current target to a fresh temporary name;
    /// 2. rename that over `<target>.previous` (the old rollback point is replaced
    ///    only once the new one exists);
    /// 3. rename the staged file over the target.
    /// The target path exists at every moment, and a failure before step 3 leaves it
    /// untouched.
    static func install(staged: URL, over target: URL) throws {
        let directory = target.deletingLastPathComponent()
        let previous = target.path + ".previous"
        let (fd, link) = try temporaryFile(in: directory, prefix: SelfUpdateConstants.backupStagingPrefix)
        close(fd)
        unlink(link)
        guard Darwin.link(target.path, link) == 0 else {
            throw SelfUpdateError.backup("\(previous): \(String(cString: strerror(errno)))")
        }
        guard rename(link, previous) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(link)
            throw SelfUpdateError.backup("\(previous): \(reason)")
        }
        guard rename(staged.path, target.path) == 0 else {
            throw SelfUpdateError.install("\(target.path): \(String(cString: strerror(errno)))")
        }
    }

    /// One printable line: control characters and every Unicode line or paragraph
    /// separator become spaces.
    static func oneLine(_ text: String) -> String {
        let breaking = CharacterSet.controlCharacters.union(.newlines).union(.illegalCharacters)
        let flattened = String(String.UnicodeScalarView(text.unicodeScalars.map { breaking.contains($0) ? " " : $0 }))
        return String(flattened.prefix(500))
    }
}
