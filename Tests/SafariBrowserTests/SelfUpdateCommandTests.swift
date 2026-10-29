import ArgumentParser
import XCTest

@testable import SafariBrowser

final class Captured: @unchecked Sendable {
    var out: [String] = []
    var err: [String] = []
}

/// #314: what `self-update` and `self-update --check` print and exit with.
final class SelfUpdateCommandTests: XCTestCase {

    private func run(check: Bool, json: Bool = false, _ updater: SelfUpdater) async -> (Int32, Captured) {
        let c = Captured()
        let code: Int32
        if check {
            code = await SelfUpdateRunner.check(updater, json: json, out: { c.out.append($0) }, err: { c.err.append($0) })
        } else {
            code = await SelfUpdateRunner.update(updater, out: { c.out.append($0) }, err: { c.err.append($0) })
        }
        return (code, c)
    }

    // MARK: --check

    func testCheckJSONForEveryStatus() async throws {
        let rows: [(String, String, Int32)] = [
            ("v2.8.0", #"{"installed":"v2.8.0","latest":"v2.8.0","status":"up-to-date"}"#, 0),
            ("v2.7.0", #"{"installed":"v2.7.0","latest":"v2.8.0","status":"update-available"}"#, 0),
            ("v2.8.0-1-gabcdef0", #"{"installed":"v2.8.0-1-gabcdef0","latest":"v2.8.0","status":"ahead"}"#, 0),
            ("unknown", #"{"installed":"unknown","latest":"v2.8.0","status":"not-comparable"}"#, 0),
        ]
        for (installed, expected, exit) in rows {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            let (code, c) = await run(check: true, json: true,
                                      makeUpdater(installed: installed, executable: fixture.target, source: FakeReleaseSource()))
            XCTAssertEqual(code, exit, installed)
            XCTAssertEqual(c.out, [expected], installed)
        }
    }

    func testCheckJSONLookupFailedIsOneLineAndExitsOne() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let source = FakeReleaseSource()
        source.latestResult = .failure(SelfUpdateError.lookup("The request timed out.\nretry"))
        let (code, c) = await run(check: true, json: true, makeUpdater(executable: fixture.target, source: source))
        XCTAssertEqual(code, 1)
        XCTAssertEqual(c.out, [#"{"installed":"v2.7.0","latest":null,"status":"lookup-failed","error":"release lookup failed: The request timed out. retry"}"#])
    }

    func testCheckDownloadsNothingAndWritesNothing() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let before = (fixture.inode, fixture.bytes)
        let source = FakeReleaseSource()
        let (code, c) = await run(check: true, makeUpdater(executable: fixture.target, source: source))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(c.out.count, 1)
        XCTAssertTrue(c.out[0].contains("v2.8.0") && c.out[0].contains("v2.7.0"), c.out[0])
        XCTAssertEqual(source.downloaded, [])
        XCTAssertEqual(fixture.inode, before.0); XCTAssertEqual(fixture.bytes, before.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path + ".previous"))
    }

    func testJSONWithoutCheckIsAUsageError() {
        XCTAssertThrowsError(try SelfUpdateCommand.parse(["--json"]))
        XCTAssertNoThrow(try SelfUpdateCommand.parse(["--check", "--json"]))
        XCTAssertNoThrow(try SelfUpdateCommand.parse([]))
    }

    // MARK: No prompt before replacing

    func testUpdateReplacesWithoutReadingInput() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let (code, c) = await run(check: false, makeUpdater(executable: fixture.target, source: FakeReleaseSource()))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(c.out.first, "updated safari-browser v2.7.0 → v2.8.0 at \(fixture.target.path) (previous kept as \(fixture.target.path).previous)")
        XCTAssertEqual(c.err, [])
    }

    func testUpToDateAndAheadDownloadNothingAndExitZero() async throws {
        for (installed, phrase) in [("v2.8.0", "up to date"), ("v2.8.0-2-g1234567", "newer than the latest release")] {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            let source = FakeReleaseSource()
            let (code, c) = await run(check: false, makeUpdater(installed: installed, executable: fixture.target, source: source))
            XCTAssertEqual(code, 0, installed)
            XCTAssertTrue(c.out.joined().contains(phrase), "\(installed): \(c.out)")
            XCTAssertFalse(source.binaryDownloaded, installed)
        }
    }

    func testNotComparableExitsOneAndPointsToTheManualSteps() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let (code, c) = await run(check: false, makeUpdater(installed: "1a2b3c4", executable: fixture.target, source: FakeReleaseSource()))
        XCTAssertEqual(code, 1)
        XCTAssertTrue(c.err.joined().contains("README.md"), "\(c.err)")
    }

    func testFailureIsPrintedWithTheStepAndExitsOne() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let (code, c) = await run(check: false, makeUpdater(executable: fixture.target,
                                                           source: FakeReleaseSource(checksum: String(repeating: "0", count: 64))))
        XCTAssertEqual(code, 1)
        XCTAssertEqual(c.err.count, 1)
        XCTAssertTrue(c.err[0].hasPrefix("self-update: checksum mismatch"), c.err[0])
    }
}

/// #314: daemons left running on the old binary are stopped after a replacement.
final class SelfUpdateDaemonTests: XCTestCase {

    private func runUpdate(daemons: [SelfUpdateDaemonResult]) async throws -> (Int32, Captured) {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        let c = Captured()
        let code = await SelfUpdateRunner.update(
            makeUpdater(executable: fixture.target, source: FakeReleaseSource(), daemons: daemons),
            out: { c.out.append($0) }, err: { c.err.append($0) })
        return (code, c)
    }

    func testDefaultDaemonIsStoppedAndTheRestartCommandPrinted() async throws {
        let (code, c) = try await runUpdate(daemons: [SelfUpdateDaemonResult(name: "default", stopped: true)])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(Array(c.out.dropFirst()), ["daemon default: stopped", "restart it with: safari-browser daemon start"])
    }

    func testNamedDaemonRestartNamesIt() async throws {
        let (_, c) = try await runUpdate(daemons: [SelfUpdateDaemonResult(name: "default", stopped: true),
                                                   SelfUpdateDaemonResult(name: "work", stopped: true)])
        XCTAssertEqual(Array(c.out.dropFirst()), [
            "daemon default: stopped", "daemon work: stopped",
            "restart it with: safari-browser daemon start",
            "restart it with: safari-browser daemon start --name work",
        ])
    }

    func testDaemonThatDoesNotStopWarnsButStillExitsZero() async throws {
        let (code, c) = try await runUpdate(daemons: [SelfUpdateDaemonResult(name: "work", stopped: false)])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(c.err, ["warning: daemon work did not stop within 5 s; it still runs the old binary — stop it with: safari-browser daemon stop --name work"])
    }

    func testNoDaemonsPrintsNothingExtra() async throws {
        let (_, c) = try await runUpdate(daemons: [])
        XCTAssertEqual(c.out.count, 1)
    }

    func testLiveScanIgnoresOtherFilesAndDeadDaemons() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("self-update-sock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["safari-browser-default.sock", "safari-browser-.sock", "other-default.sock", "safari-browser-work.log"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        // A socket with no pid file is not a live daemon.
        XCTAssertEqual(SelfUpdateDaemonsLive.liveNames(in: dir.path), [])
    }
}
