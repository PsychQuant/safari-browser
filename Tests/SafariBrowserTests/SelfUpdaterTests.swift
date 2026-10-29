import CryptoKit
import XCTest

@testable import SafariBrowser

// MARK: - Fakes

/// A release source that never touches the network. Records what was downloaded.
final class FakeReleaseSource: SelfUpdateReleaseSource, @unchecked Sendable {
    var latestResult: Result<SelfUpdateRelease, Error>
    var assets: [URL: Data] = [:]
    var downloadError: Error?
    private(set) var downloaded: [URL] = []

    init(tag: String = "v2.8.0", binary: Data = Data("new-binary\n".utf8), checksum: String? = nil) {
        let prefix = SelfUpdateConstants.downloadPrefix(tag: tag)
        let release = SelfUpdateRelease(
            tag: tag,
            binaryURL: URL(string: prefix + SelfUpdateConstants.binaryAssetName)!, binarySize: binary.count,
            checksumURL: URL(string: prefix + SelfUpdateConstants.checksumAssetName)!, checksumSize: 65)
        latestResult = .success(release)
        assets[release.binaryURL] = binary
        assets[release.checksumURL] = Data(((checksum ?? Self.hex(binary)) + "\n").utf8)
    }

    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func latest() async throws -> SelfUpdateRelease { try latestResult.get() }

    func download(_ url: URL, limit: Int) async throws -> Data {
        downloaded.append(url)
        if let downloadError { throw downloadError }
        guard let data = assets[url] else { throw SelfUpdateError.download("no fake asset at \(url)") }
        guard data.count <= limit else {
            throw SelfUpdateError.assetTooLarge(name: url.lastPathComponent, size: data.count, limit: limit)
        }
        return data
    }

    var binaryDownloaded: Bool { downloaded.contains { $0.lastPathComponent == SelfUpdateConstants.binaryAssetName } }
}

final class Recorder: @unchecked Sendable {
    var events: [String] = []
}

/// A temporary install directory with a fake installed binary.
struct InstallFixture {
    let dir: URL
    let target: URL

    init(contents: String = "old-binary\n") throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // realpath: /var → /private/var, so comparisons use the resolved form.
        let resolved = URL(fileURLWithPath: try XCTUnwrap(realpath(dir.path, nil).map { p -> String in
            defer { free(p) }; return String(cString: p) }))
        target = resolved.appendingPathComponent("safari-browser")
        try Data(contents.utf8).write(to: target)
        chmod(target.path, 0o755)
    }

    var inode: UInt64 { (try? FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? UInt64) ?? 0 }
    var bytes: Data { (try? Data(contentsOf: target)) ?? Data() }
    var stagingLeftovers: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)) ?? [])
            .filter { $0.hasPrefix(SelfUpdateConstants.stagingPrefix) }
    }
    func cleanup() {
        chmod(target.deletingLastPathComponent().path, 0o755)
        try? FileManager.default.removeItem(at: dir)
    }
}

func makeUpdater(installed: String = "v2.7.0", executable: URL, source: FakeReleaseSource,
                 recorder: Recorder = Recorder(),
                 installedCheck: @escaping @Sendable (URL) throws -> Void = { _ in },
                 candidateCheck: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in },
                 probe: (@Sendable (URL) async throws -> String)? = nil,
                 daemons: [SelfUpdateDaemonResult] = []) -> SelfUpdater {
    SelfUpdater(
        installedVersion: installed,
        executable: executable,
        source: source,
        verifier: SelfUpdateSignatureVerifier(
            checkInstalled: { url in recorder.events.append("installed"); try installedCheck(url) },
            checkCandidate: { c, i in recorder.events.append("candidate"); try candidateCheck(c, i) }),
        probe: { url in
            recorder.events.append("probe")
            if let probe { return try await probe(url) }
            return "v2.8.0"
        },
        daemons: SelfUpdateDaemonStopper(stopAll: { recorder.events.append("daemons"); return daemons }))
}

// MARK: - Checksum

final class SelfUpdateChecksumTests: XCTestCase {
    func testChecksumFileFormat() throws {
        let hex = String(repeating: "a", count: 64)
        XCTAssertEqual(try SelfUpdateChecksum.parse(Data((hex + "\n").utf8)), hex)
        XCTAssertEqual(try SelfUpdateChecksum.parse(Data(hex.utf8)), hex)
        for bad in [hex.uppercased() + "\n", hex + "\n\n", " " + hex, hex + "  safari-browser\n",
                    String(repeating: "a", count: 63), String(repeating: "g", count: 64), ""] {
            XCTAssertThrowsError(try SelfUpdateChecksum.parse(Data(bad.utf8)), bad) {
                XCTAssertEqual($0 as? SelfUpdateError, .checksumFormat)
            }
        }
    }

    func testDigestIsLowercaseSHA256() {
        XCTAssertEqual(SelfUpdateChecksum.sha256Hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testMismatchFailsAndCleansUp() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let before = (fixture.inode, fixture.bytes)
        let source = FakeReleaseSource(checksum: String(repeating: "0", count: 64))
        let recorder = Recorder()
        let updater = makeUpdater(executable: fixture.target, source: source, recorder: recorder)
        await assertThrows(try await updater.update()) { error in
            guard case SelfUpdateError.checksumMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(fixture.inode, before.0); XCTAssertEqual(fixture.bytes, before.1)
        XCTAssertEqual(fixture.stagingLeftovers, [])
        XCTAssertFalse(recorder.events.contains("candidate"), "a corrupt download must not reach the signature check")
    }
}

// MARK: - Signature, version probe, ordering

final class SelfUpdateSignatureTests: XCTestCase {
    func testInstalledNotDeveloperIDRefusesBeforeDownloadingTheBinary() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let source = FakeReleaseSource()
        let updater = makeUpdater(executable: fixture.target, source: source,
                                  installedCheck: { _ in throw SelfUpdateError.installedNotDeveloperID("ad-hoc") })
        await assertThrows(try await updater.update()) {
            XCTAssertEqual($0 as? SelfUpdateError, .installedNotDeveloperID("ad-hoc"))
            XCTAssertTrue("\($0)".contains("README.md"))
        }
        XCTAssertFalse(source.binaryDownloaded)
    }

    func testEachCandidateRefusalStopsBeforeTheProbe() async throws {
        let refusals: [SelfUpdateError] = [
            .candidateNotDeveloperID("ad-hoc"), .candidateMissingRuntime, .candidateRequirement("status -67050"),
        ]
        for refusal in refusals {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            let before = (fixture.inode, fixture.bytes)
            let recorder = Recorder()
            let updater = makeUpdater(executable: fixture.target, source: FakeReleaseSource(), recorder: recorder,
                                      candidateCheck: { _, _ in throw refusal })
            await assertThrows(try await updater.update()) { XCTAssertEqual($0 as? SelfUpdateError, refusal) }
            XCTAssertFalse(recorder.events.contains("probe"), "\(refusal): the staged binary must not run")
            XCTAssertEqual(fixture.inode, before.0); XCTAssertEqual(fixture.bytes, before.1)
            XCTAssertEqual(fixture.stagingLeftovers, [])
        }
    }

    func testCandidateIsCheckedAgainstTheInstalledFile() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let seen = Recorder()
        let updater = makeUpdater(executable: fixture.target, source: FakeReleaseSource(),
                                  candidateCheck: { candidate, installed in
                                      seen.events.append(installed.path)
                                      seen.events.append(candidate.deletingLastPathComponent().path)
                                  })
        _ = try await updater.update()
        XCTAssertEqual(seen.events, [fixture.target.path, fixture.target.deletingLastPathComponent().path])
    }

    func testLiveVerifierRefusesANonDeveloperIDBinaryWithTheSharedAssessment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("self-update-ls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("ls")
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: copy.path)
        XCTAssertThrowsError(try SelfUpdateSignatureVerifier.live.checkInstalled(copy)) { error in
            guard case SelfUpdateError.installedNotDeveloperID = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try SelfUpdateSignatureVerifier.live.checkCandidate(copy, copy)) { error in
            guard case SelfUpdateError.candidateNotDeveloperID = error else { return XCTFail("\(error)") }
        }
    }

    func testOrderIsInstalledThenCandidateThenProbeThenDaemons() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let recorder = Recorder()
        let updater = makeUpdater(executable: fixture.target, source: FakeReleaseSource(), recorder: recorder)
        _ = try await updater.update()
        XCTAssertEqual(recorder.events, ["installed", "candidate", "probe", "daemons"])
    }

    func testVersionMismatchAndProbeFailureLeaveTheInstallAlone() async throws {
        let outcomes: [(@Sendable (URL) async throws -> String, SelfUpdateError)] = [
            ({ _ in "v2.7.0" }, .versionMismatch(expected: "v2.8.0", actual: "v2.7.0")),
            ({ _ in throw SelfUpdateError.versionProbe("timed out after 10 s") }, .versionProbe("timed out after 10 s")),
        ]
        for (probe, expected) in outcomes {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            let before = (fixture.inode, fixture.bytes)
            let updater = makeUpdater(executable: fixture.target, source: FakeReleaseSource(), probe: probe)
            await assertThrows(try await updater.update()) { XCTAssertEqual($0 as? SelfUpdateError, expected) }
            XCTAssertEqual(fixture.inode, before.0); XCTAssertEqual(fixture.bytes, before.1)
            XCTAssertEqual(fixture.stagingLeftovers, [])
        }
    }

    func testLiveProbeReadsVersionAndStripsOneNewline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("self-update-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fake")
        try Data("#!/bin/sh\n[ \"$1\" = --version ] && printf 'v9.9.9\\n'\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        let version = try await SelfUpdateVersionProbeLive.run(script, timeout: 5)
        XCTAssertEqual(version, "v9.9.9")
    }

    func testLiveProbeTimesOut() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("self-update-hang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("hang")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        let start = Date()
        await assertThrows(try await SelfUpdateVersionProbeLive.run(script, timeout: 0.5)) { error in
            guard case SelfUpdateError.versionProbe = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}

// MARK: - Replacement

final class SelfUpdateReplaceTests: XCTestCase {
    func testReplacementGivesANewInodeAndKeepsTheOldBytesAsPrevious() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let oldInode = fixture.inode
        let updater = makeUpdater(executable: fixture.target, source: FakeReleaseSource(binary: Data("new-binary\n".utf8)))
        let outcome = try await updater.update()
        XCTAssertEqual(outcome, .replaced(from: "v2.7.0", to: "v2.8.0", target: fixture.target.path, daemons: []))
        XCTAssertEqual(fixture.bytes, Data("new-binary\n".utf8))
        XCTAssertNotEqual(fixture.inode, oldInode)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.target.path + ".previous")), Data("old-binary\n".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.target.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
        XCTAssertEqual(fixture.stagingLeftovers, [])
    }

    func testSymlinkIsResolvedAndLeftInPlace() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let link = fixture.target.deletingLastPathComponent().appendingPathComponent("link-to-cli")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: fixture.target.path)
        let updater = makeUpdater(executable: link, source: FakeReleaseSource())
        _ = try await updater.update()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), fixture.target.path)
        XCTAssertEqual(fixture.bytes, Data("new-binary\n".utf8))
    }

    /// A real Mach-O, not a shell script: `sh` reopens a script by path, so a
    /// script started just before the rename can read the new file and prove
    /// nothing. Not a copy of `/bin/sleep` either: an arm64e Apple binary copied
    /// off the system volume is killed at launch whether or not anything is replaced.
    func testRunningOldBinaryIsUnaffected() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let source = fixture.target.deletingLastPathComponent().appendingPathComponent("sleeper.c")
        try Data("#include <unistd.h>\nint main(void){ sleep(1); return 0; }\n".utf8).write(to: source)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compile.arguments = ["-o", fixture.target.path, source.path]
        compile.standardError = FileHandle.nullDevice
        do { try compile.run() } catch { throw XCTSkip("no C compiler to build a running fixture: \(error)") }
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else { throw XCTSkip("cc could not build the running fixture") }
        let process = Process()
        process.executableURL = fixture.target
        process.arguments = ["1"]
        try process.run()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(process.isRunning, "the old binary is running before the update")
        let updater = makeUpdater(executable: fixture.target,
                                  source: FakeReleaseSource(binary: Data("not a program\n".utf8)))
        _ = try await updater.update()
        XCTAssertEqual(fixture.bytes, Data("not a program\n".utf8))
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0, "the running old binary finished normally after the rename")
    }

    func testExistingPreviousIsReplaced() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        try Data("older\n".utf8).write(to: URL(fileURLWithPath: fixture.target.path + ".previous"))
        _ = try await makeUpdater(executable: fixture.target, source: FakeReleaseSource()).update()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.target.path + ".previous")), Data("old-binary\n".utf8))
    }
}

// MARK: - Failure leaves the install alone

final class SelfUpdateFailureTests: XCTestCase {
    private func assertUnchanged(_ fixture: InstallFixture, _ before: (UInt64, Data),
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.inode, before.0, file: file, line: line)
        XCTAssertEqual(fixture.bytes, before.1, file: file, line: line)
        XCTAssertEqual(fixture.stagingLeftovers, [], file: file, line: line)
    }

    func testLookupAndDownloadFailures() async throws {
        let setups: [(String, (FakeReleaseSource) -> Void)] = [
            ("lookup", { $0.latestResult = .failure(SelfUpdateError.lookup("timed out")) }),
            ("shape", { $0.latestResult = .failure(SelfUpdateError.malformedRelease("not a JSON object")) }),
            ("download", { $0.downloadError = SelfUpdateError.download("HTTP 404") }),
            ("size", { s in s.assets[s.assets.keys.first { $0.lastPathComponent == "safari-browser" }!] =
                Data(count: SelfUpdateConstants.maxBinaryBytes + 1) }),
        ]
        for (name, setup) in setups {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            let before = (fixture.inode, fixture.bytes)
            let source = FakeReleaseSource(); setup(source)
            await assertThrows(try await makeUpdater(executable: fixture.target, source: source).update(), name) { _ in }
            assertUnchanged(fixture, before)
        }
    }

    func testUnwritableDirectoryFailsWithoutSudo() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let before = (fixture.inode, fixture.bytes)
        let dir = fixture.target.deletingLastPathComponent().path
        chmod(dir, 0o555)
        let source = FakeReleaseSource()
        await assertThrows(try await makeUpdater(executable: fixture.target, source: source).update()) {
            XCTAssertEqual($0 as? SelfUpdateError, .notWritable(dir))
            XCTAssertTrue("\($0)".contains("sudo"))
        }
        XCTAssertFalse(source.binaryDownloaded)
        chmod(dir, 0o755)
        assertUnchanged(fixture, before)
    }

    func testBackupFailureAbortsBeforeTheTargetChanges() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let before = (fixture.inode, fixture.bytes)
        // A directory where the backup goes: unlink(2) refuses it.
        try FileManager.default.createDirectory(atPath: fixture.target.path + ".previous", withIntermediateDirectories: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: fixture.target.path + ".previous/keep"))
        let recorder = Recorder()
        await assertThrows(try await makeUpdater(executable: fixture.target, source: FakeReleaseSource(), recorder: recorder).update()) {
            guard case SelfUpdateError.backup = $0 else { return XCTFail("\($0)") }
        }
        assertUnchanged(fixture, before)
        XCTAssertFalse(recorder.events.contains("daemons"))
    }

    func testMissingExecutableCannotBeLocated() async throws {
        let ghost = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        await assertThrows(try await makeUpdater(executable: ghost, source: FakeReleaseSource()).update()) {
            guard case SelfUpdateError.locate = $0 else { return XCTFail("\($0)") }
        }
    }
}

// MARK: - Helpers

func assertThrows<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "",
                     file: StaticString = #filePath, line: UInt = #line,
                     _ handler: (Error) -> Void) async {
    do {
        _ = try await expression()
        XCTFail("expected an error \(message)", file: file, line: line)
    } catch {
        handler(error)
    }
}
