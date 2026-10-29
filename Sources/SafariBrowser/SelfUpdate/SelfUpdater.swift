import CryptoKit
import Darwin
import Foundation

// MARK: - Injected dependencies (#314)

/// Where releases come from. The live implementation talks to GitHub; tests use a fake.
protocol SelfUpdateReleaseSource: Sendable {
    func latest() async throws -> SelfUpdateRelease
    /// Fetch `url`, failing when the answer is larger than `limit` bytes.
    func download(_ url: URL, limit: Int) async throws -> Data
}

/// Identity checks. `checkInstalled` runs before anything is downloaded;
/// `checkCandidate(candidate, installed)` runs before the candidate is executed.
struct SelfUpdateSignatureVerifier: Sendable {
    var checkInstalled: @Sendable (URL) throws -> Void
    var checkCandidate: @Sendable (_ candidate: URL, _ installed: URL) throws -> Void
}

struct SelfUpdateDaemonResult: Equatable, Sendable {
    let name: String
    let stopped: Bool
}

struct SelfUpdateDaemonStopper: Sendable {
    var stopAll: @Sendable () async -> [SelfUpdateDaemonResult]
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
    case replaced(from: String, to: String, target: String, daemons: [SelfUpdateDaemonResult])
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

        let expected = try SelfUpdateChecksum.parse(
            try await source.download(release.checksumURL, limit: SelfUpdateConstants.maxChecksumBytes))
        let binary = try await source.download(release.binaryURL, limit: SelfUpdateConstants.maxBinaryBytes)

        let staged = try Self.stage(binary, in: directory)
        var installed = false
        defer { if !installed { unlink(staged.path) } }

        let actual = SelfUpdateChecksum.sha256Hex(binary)
        guard actual == expected else { throw SelfUpdateError.checksumMismatch(expected: expected, actual: actual) }
        try verifier.checkCandidate(staged, target)
        let reported = try await probe(staged)
        guard reported == release.tag else {
            throw SelfUpdateError.versionMismatch(expected: release.tag, actual: Self.oneLine(reported))
        }
        try Self.install(staged: staged, over: target)
        installed = true

        let stopped = await daemons.stopAll()
        return .replaced(from: installedVersion, to: release.tag, target: target.path, daemons: stopped)
    }

    // MARK: Filesystem steps

    static func resolve(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw SelfUpdateError.locate("\(url.path): \(String(cString: strerror(errno)))")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Write `data` to a fresh `mkstemp` file next to the target (same filesystem,
    /// so the final `rename` is atomic), flushed and made executable.
    static func stage(_ data: Data, in directory: URL) throws -> URL {
        var template = Array((directory.path + "/" + SelfUpdateConstants.stagingPrefix + "XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw SelfUpdateError.staging(String(cString: strerror(errno))) }
        let path = String(cString: template)
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
        guard written else { throw SelfUpdateError.staging(String(cString: strerror(errno))) }
        guard fsync(fd) == 0, fchmod(fd, 0o755) == 0 else {
            throw SelfUpdateError.staging(String(cString: strerror(errno)))
        }
        ok = true
        return URL(fileURLWithPath: path)
    }

    /// Keep the current binary as `<target>.previous` (a hard link, so the target
    /// path never stops existing), then rename the staged file over the target.
    static func install(staged: URL, over target: URL) throws {
        let previous = target.path + ".previous"
        if unlink(previous) != 0 && errno != ENOENT {
            throw SelfUpdateError.backup("\(previous): \(String(cString: strerror(errno)))")
        }
        guard link(target.path, previous) == 0 else {
            throw SelfUpdateError.backup("\(previous): \(String(cString: strerror(errno)))")
        }
        guard rename(staged.path, target.path) == 0 else {
            throw SelfUpdateError.install("\(target.path): \(String(cString: strerror(errno)))")
        }
    }

    /// One printable line: control characters (including newlines) become spaces.
    static func oneLine(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        })).prefix(500).description
    }
}
