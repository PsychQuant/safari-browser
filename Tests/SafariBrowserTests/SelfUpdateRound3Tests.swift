import Darwin
import XCTest

@testable import SafariBrowser

/// #314 verify round 3: each test is named after the finding it guards.
final class SelfUpdateRound3Tests: XCTestCase {
    /// T5: a lock that `flock` refuses for a reason other than another run (a
    /// FIFO at the lock path cannot be locked) is a `lock` error, not "wait for
    /// it to finish". Reverting to "every flock failure is busy" fails here.
    func testFlockFailureOtherThanContentionIsALockError() throws {
        let dir = try scratchDirectory("self-update-fifo"); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(mkfifo(dir.appendingPathComponent(SelfUpdateConstants.lockName).path, 0o600), 0)
        XCTAssertThrowsError(try SelfUpdater.acquireLock(in: dir)) { error in
            guard case SelfUpdateError.lock = error else { return XCTFail("\(error)") }
        }
    }

    /// T1 (tasks 5.6): `--check` never resolves the executable path, so a path
    /// that does not exist still gets a status, not `lookup-failed`.
    func testCheckDoesNotNeedTheExecutablePath() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/self-update-check/safari-browser")
        let result = await makeUpdater(executable: missing, source: FakeReleaseSource()).check()
        XCTAssertEqual(result.status, .updateAvailable)
        XCTAssertNil(result.error)
    }

    /// T1 (tasks 5.4): the release answer is held to 1 MiB; a declared length
    /// over it is refused before the body is read.
    func testReleaseAnswerOverOneMebibyteIsRefused() async throws {
        let source = GitHubReleaseSource(userAgent: "test", protocolClasses: [StubURLProtocol.self])
        let declared = SelfUpdateConstants.maxReleaseAnswerBytes + 1
        StubURLProtocol.responses[SelfUpdateConstants.latestReleaseURL.absoluteString] =
            (200, ["Content-Length": String(declared)], Data("{}".utf8))
        defer { StubURLProtocol.responses[SelfUpdateConstants.latestReleaseURL.absoluteString] = nil }
        await assertThrows(try await source.latest()) {
            XCTAssertEqual($0 as? SelfUpdateError,
                           .assetTooLarge(name: "the release answer", size: declared, limit: SelfUpdateConstants.maxReleaseAnswerBytes))
        }
    }

    /// T7: the running-binary check also refuses a manual `mv` and unreadable
    /// signing information, so the message must not blame "another update".
    func testInstalledChangedDoesNotBlameAnotherUpdate() {
        let message = "\(SelfUpdateError.installedChanged("/x/safari-browser"))"
        XCTAssertFalse(message.contains("another update"), message)
        XCTAssertTrue(message.contains("run self-update again"), message)
    }
}
