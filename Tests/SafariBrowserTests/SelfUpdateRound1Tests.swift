import Darwin
import XCTest

@testable import SafariBrowser

/// #314 verify round 1: each test here is named after the finding it guards.

// MARK: - Helpers: real Mach-O fixtures, ad-hoc signed

enum MachOFixture {
    /// Compile `main` into `url` with `cc`, then ad-hoc sign it, optionally with
    /// the hardened runtime. Throws XCTSkip without a compiler or codesign.
    static func build(_ url: URL, main: String, runtime: Bool) throws {
        let source = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".c")
        try Data("#include <stdio.h>\n#include <unistd.h>\nint main(void){ \(main) }\n".utf8).write(to: source)
        try run("/usr/bin/cc", ["-o", url.path, source.path], skipIfMissing: "no C compiler")
        var sign = ["--force", "--sign", "-"]
        if runtime { sign += ["--options", "runtime"] }
        try run("/usr/bin/codesign", sign + [url.path], skipIfMissing: "codesign unavailable")
    }

    private static func run(_ tool: String, _ arguments: [String], skipIfMissing: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { throw XCTSkip("\(skipIfMissing): \(error)") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("\(tool) failed building a fixture") }
    }
}

func scratchDirectory(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - B6: the two gates of the trust check run for real

final class SelfUpdateTrustGateTests: XCTestCase {
    func testHardenedRuntimeGateUsesTheRealSigningFlags() throws {
        let dir = try scratchDirectory("self-update-runtime"); defer { try? FileManager.default.removeItem(at: dir) }
        let withRuntime = dir.appendingPathComponent("with"), without = dir.appendingPathComponent("without")
        try MachOFixture.build(withRuntime, main: "return 0;", runtime: true)
        try MachOFixture.build(without, main: "return 0;", runtime: false)
        XCTAssertNoThrow(try SelfUpdateSignatureVerifier.requireHardenedRuntime(withRuntime))
        XCTAssertThrowsError(try SelfUpdateSignatureVerifier.requireHardenedRuntime(without)) {
            XCTAssertEqual($0 as? SelfUpdateError, .candidateMissingRuntime)
        }
    }

    /// Swapping `installed` for `candidate` (a binary always satisfies its own
    /// requirement) makes the second assertion fail.
    func testCandidateIsCheckedAgainstTheInstalledRequirementNotItsOwn() throws {
        let dir = try scratchDirectory("self-update-dr"); defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("installed"), other = dir.appendingPathComponent("other")
        try MachOFixture.build(installed, main: "return 0;", runtime: true)
        try MachOFixture.build(other, main: "return 1;", runtime: true)
        let same = dir.appendingPathComponent("same")
        try FileManager.default.copyItem(at: installed, to: same)
        XCTAssertNoThrow(try SelfUpdateSignatureVerifier.requireSatisfiesRequirement(of: installed, candidate: same))
        XCTAssertThrowsError(try SelfUpdateSignatureVerifier.requireSatisfiesRequirement(of: installed, candidate: other)) {
            guard case SelfUpdateError.candidateRequirement = $0 else { return XCTFail("\($0)") }
        }
    }

    func testRunningBinaryCheckRefusesAFileThatIsNotThisProcess() throws {
        let dir = try scratchDirectory("self-update-running"); defer { try? FileManager.default.removeItem(at: dir) }
        let elsewhere = dir.appendingPathComponent("elsewhere")
        try MachOFixture.build(elsewhere, main: "return 0;", runtime: false)
        XCTAssertThrowsError(try SelfUpdateSignatureVerifier.live.checkRunningIsInstalled(elsewhere)) {
            XCTAssertEqual($0 as? SelfUpdateError, .installedChanged(elsewhere.path))
        }
    }

    func testStrictValidationIsPartOfTheCandidateCheck() {
        XCTAssertNotEqual(SelfUpdateSignatureVerifier.candidateCheckFlags.rawValue & kSecCSStrictValidate, 0)
        XCTAssertNotEqual(SelfUpdateSignatureVerifier.candidateCheckFlags.rawValue & kSecCSCheckAllArchitectures, 0)
    }
}

// MARK: - B5: one update at a time, and only from the binary that is installed

final class SelfUpdateConcurrencyTests: XCTestCase {
    func testASecondRunIsRefusedWhileTheLockIsHeld() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let before = (fixture.inode, fixture.bytes)
        let held = try SelfUpdater.acquireLock(in: fixture.target.deletingLastPathComponent())
        defer { close(held) }
        let source = FakeReleaseSource()
        await assertThrows(try await makeUpdater(executable: fixture.target, source: source).update()) {
            guard case SelfUpdateError.busy = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(source.binaryDownloaded)
        XCTAssertEqual(fixture.inode, before.0); XCTAssertEqual(fixture.bytes, before.1)
    }

    func testARunStartedFromABinaryThatWasSinceReplacedRefuses() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        try Data("prev\n".utf8).write(to: URL(fileURLWithPath: fixture.target.path + ".previous"))
        let source = FakeReleaseSource()
        await assertThrows(try await makeUpdater(executable: fixture.target, source: source,
                                                 runningCheck: { throw SelfUpdateError.installedChanged($0.path) }).update()) {
            XCTAssertEqual($0 as? SelfUpdateError, .installedChanged(fixture.target.path))
        }
        XCTAssertFalse(source.binaryDownloaded)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.target.path + ".previous")), Data("prev\n".utf8),
                       "the rollback point is not touched")
    }

    func testLockIsReleasedAfterARun() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        _ = try await makeUpdater(executable: fixture.target, source: FakeReleaseSource()).update()
        let fd = try SelfUpdater.acquireLock(in: fixture.target.deletingLastPathComponent())
        close(fd)
    }
}

// MARK: - B4: interrupted runs

final class SelfUpdateInterruptionTests: XCTestCase {
    func testLeftoverStagingFilesFromAnInterruptedRunAreRemovedAndOthersKept() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let dir = fixture.target.deletingLastPathComponent()
        let leftovers = [".safari-browser.self-update.AbC123", ".safari-browser.self-update.zzzzzz"]
        let keep = [".safari-browser.self-update.toolongname", ".safari-browser.self-update.ab", "notes.txt",
                    ".safari-browser.self-update-lock"]
        for name in leftovers + keep { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8)) }
        // A directory with a staging-shaped name is not a file this tool wrote.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".safari-browser.self-update.DIRxyz"),
                                                withIntermediateDirectories: false)
        _ = try await makeUpdater(executable: fixture.target, source: FakeReleaseSource()).update()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        for name in leftovers { XCTAssertFalse(names.contains(name), name) }
        for name in keep + [".safari-browser.self-update.DIRxyz"] { XCTAssertTrue(names.contains(name), name) }
    }

    func testTargetPathExistsAtEveryMomentOfTheReplacement() throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let dir = fixture.target.deletingLastPathComponent()
        let stop = ManagedAtomicFlag()
        let missing = ManagedAtomicFlag()
        let path = fixture.target.path
        let watcher = Thread {
            var st = stat()
            while !stop.value { if stat(path, &st) != 0 { missing.set() } }
        }
        watcher.start()
        for i in 0..<200 {
            let staged = try SelfUpdater.stage(Data("v\(i)\n".utf8), in: dir)
            try SelfUpdater.install(staged: staged, over: fixture.target)
        }
        stop.set()
        while !watcher.isFinished { usleep(1000) }
        XCTAssertFalse(missing.value, "the target path was missing at some moment during replacement")
        XCTAssertEqual(fixture.bytes, Data("v199\n".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path + ".previous")), Data("v198\n".utf8))
    }

    /// #14 / #25: a failed final step leaves the old rollback point in place.
    func testOldPreviousSurvivesWhenTheBackupCannotBePlaced() throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let previous = fixture.target.path + ".previous"
        try FileManager.default.createDirectory(atPath: previous, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: previous + "/old"))
        let staged = try SelfUpdater.stage(Data("new\n".utf8), in: fixture.target.deletingLastPathComponent())
        defer { unlink(staged.path) }
        XCTAssertThrowsError(try SelfUpdater.install(staged: staged, over: fixture.target)) {
            guard case SelfUpdateError.backup = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: previous + "/old")), Data("keep".utf8))
        XCTAssertEqual(fixture.bytes, Data("old-binary\n".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".safari-browser.self-update-prev") }, "\(names)")
    }

    func testStagedFileIsNotExecutableUntilItsSignatureHasPassed() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let modes = Recorder()
        let updater = makeUpdater(executable: fixture.target, source: FakeReleaseSource(),
                                  candidateCheck: { candidate, _ in
                                      let mode = (try? FileManager.default.attributesOfItem(atPath: candidate.path)[.posixPermissions] as? Int) ?? -1
                                      modes.events.append(String(mode, radix: 8))
                                  },
                                  probe: { url in
                                      let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
                                      modes.events.append(String(mode, radix: 8))
                                      return "v2.8.0"
                                  })
        _ = try await updater.update()
        XCTAssertEqual(modes.events, ["600", "755"])
    }
}

final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

// MARK: - B1 / B3: network bounds, exercised through URLSession with a stub protocol

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (status: Int, headers: [String: String], body: Data)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let stub = Self.responses[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Chunks arrive one at a time with a gap, as from a network, so a cancel
        // in between is observable; delivered synchronously, URLSession merges them.
        let body = stub.body
        DispatchQueue.global().async { [self] in
            var offset = 0
            while offset < body.count {
                usleep(5_000)
                if stopped.value { return }
                let end = min(offset + 1024, body.count)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
            }
            if !stopped.value { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    private let stopped = ManagedAtomicFlag()
    override func stopLoading() { stopped.set() }
}

final class SelfUpdateNetworkBoundTests: XCTestCase {
    private let url = URL(string: "https://github.com/PsychQuant/safari-browser/releases/download/v2.8.0/safari-browser")!
    private var source: GitHubReleaseSource { GitHubReleaseSource(userAgent: "test", protocolClasses: [StubURLProtocol.self]) }

    func testLookupHasAFifteenSecondTotalDeadline() {
        let configuration = GitHubReleaseSource.lookupConfiguration(protocolClasses: nil)
        XCTAssertEqual(configuration.timeoutIntervalForResource, SelfUpdateConstants.lookupTimeout)
        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForRequest, SelfUpdateConstants.lookupTimeout)
    }

    func testBodyLargerThanTheLimitIsCutOffWhileArriving() async throws {
        StubURLProtocol.responses[url.absoluteString] = (200, [:], Data(count: 8 * 1024))
        await assertThrows(try await source.download(url, limit: 2 * 1024)) {
            guard case SelfUpdateError.assetTooLarge(let name, let size, let limit) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(name, "safari-browser"); XCTAssertEqual(limit, 2 * 1024)
            XCTAssertGreaterThan(size, limit); XCTAssertLessThan(size, 8 * 1024, "stopped before the whole body arrived")
        }
    }

    func testDeclaredLengthOverTheLimitIsRefusedBeforeTheBody() async throws {
        StubURLProtocol.responses[url.absoluteString] = (200, ["Content-Length": "999999"], Data(count: 10))
        await assertThrows(try await source.download(url, limit: 2 * 1024)) {
            XCTAssertEqual($0 as? SelfUpdateError, .assetTooLarge(name: "safari-browser", size: 999_999, limit: 2 * 1024))
        }
    }

    func testBodyWithinTheLimitArrivesWhole() async throws {
        let body = Data((0..<5000).map { UInt8($0 % 251) })
        StubURLProtocol.responses[url.absoluteString] = (200, [:], body)
        let data = try await source.download(url, limit: 5000)
        XCTAssertEqual(data, body)
    }

    func testNon200IsADownloadError() async throws {
        StubURLProtocol.responses[url.absoluteString] = (404, [:], Data("nope".utf8))
        await assertThrows(try await source.download(url, limit: 5000)) {
            guard case SelfUpdateError.download = $0 else { return XCTFail("\($0)") }
        }
    }
}

// MARK: - B2: the version probe deadline covers reading its output

final class SelfUpdateProbeBoundTests: XCTestCase {
    func testAGrandchildHoldingStdoutDoesNotHoldTheProbe() async throws {
        let dir = try scratchDirectory("self-update-grandchild"); defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("p")
        try Data("#!/bin/sh\nsleep 30 &\nprintf 'v9.9.9\\n'\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        // The grandchild holds the pipe for 30 s. Getting the version back before
        // the deadline (not a timeout error) is the property; a tighter
        // wall-clock bound flaked under load (3.57 s, verify round 2).
        let start = Date()
        // verify round 3: deadline and bound at 15 s, both far below the
        // grandchild's 30 s, so a probe that waits for EOF still fails here
        // while a slow launch under load does not.
        let version = try await SelfUpdateVersionProbeLive.run(script, timeout: 15)
        XCTAssertEqual(version, "v9.9.9")
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }

    func testOverlongOutputIsRefused() async throws {
        let dir = try scratchDirectory("self-update-long"); defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("p")
        try Data("#!/bin/sh\nyes v | head -c 100000\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        await assertThrows(try await SelfUpdateVersionProbeLive.run(script, timeout: 5)) {
            guard case SelfUpdateError.versionProbe(let m) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("4096"), m)
        }
    }
}

// MARK: - In-scope fixes

final class SelfUpdateStrictnessTests: XCTestCase {
    func testMissingOrNonBooleanFlagsAreMalformedNotADraft() {
        func release(_ extra: [String: Any]) -> Data {
            var body: [String: Any] = ["tag_name": "v2.8.0", "draft": false, "prerelease": false,
                                       "assets": [SelfUpdateReleaseTests.asset("safari-browser"),
                                                  SelfUpdateReleaseTests.asset("safari-browser.sha256")]]
            for (k, v) in extra { body[k] = v }
            return try! JSONSerialization.data(withJSONObject: body)
        }
        var noDraft = try! JSONSerialization.jsonObject(with: release([:])) as! [String: Any]
        noDraft.removeValue(forKey: "draft")
        for data in [try! JSONSerialization.data(withJSONObject: noDraft), release(["draft": 0]), release(["prerelease": "false"])] {
            XCTAssertThrowsError(try SelfUpdateRelease.parse(data)) { error in
                guard case SelfUpdateError.malformedRelease = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testBooleanSizeIsMalformed() {
        let data = try! JSONSerialization.data(withJSONObject: [
            "tag_name": "v2.8.0", "draft": false, "prerelease": false,
            "assets": [["name": "safari-browser", "size": true,
                        "browser_download_url": SelfUpdateReleaseTests.prefix + "v2.8.0/safari-browser"],
                       SelfUpdateReleaseTests.asset("safari-browser.sha256")]] as [String: Any])
        XCTAssertThrowsError(try SelfUpdateRelease.parse(data)) { error in
            guard case SelfUpdateError.malformedRelease = error else { return XCTFail("\(error)") }
        }
    }

    func testOneLineRemovesUnicodeLineSeparators() {
        XCTAssertEqual(SelfUpdater.oneLine("a\u{2028}b\u{2029}c\u{85}d\ne"), "a b c d e")
    }

    func testRefusalPointsToAnExistingReadmeSection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let section = SelfUpdateError.manualStepsSection
        XCTAssertTrue(SelfUpdateError.manualSteps.contains(section))
        XCTAssertTrue(readme.split(separator: "\n").contains { $0.hasPrefix("### \(section)") }, "README has no section '\(section)'")
    }

    func testShellWordQuotesAnythingUnsafe() {
        XCTAssertEqual(SelfUpdateRunner.shellWord("work-1.a_b"), "work-1.a_b")
        XCTAssertEqual(SelfUpdateRunner.shellWord("a b"), "'a b'")
        XCTAssertEqual(SelfUpdateRunner.shellWord("it's"), "'it'\\''s'")
        XCTAssertEqual(SelfUpdateRunner.shellWord("x\ny"), "'x y'")
    }
}
