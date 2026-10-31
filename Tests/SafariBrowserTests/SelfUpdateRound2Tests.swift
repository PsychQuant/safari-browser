import Darwin
import XCTest

@testable import SafariBrowser

/// #314 verify round 2: each test is named after the finding it guards.

final class SelfUpdateLiveWiringTests: XCTestCase {
    /// R1: the production composition, with only the Developer ID assessment
    /// replaced (ad-hoc fixtures cannot pass it). Dropping either gate from the
    /// wiring, or checking the candidate against its own requirement, fails here.
    private let wired = SelfUpdateSignatureVerifier.make(assessDeveloperID: { _ in })

    func testWiredCandidateCheckAcceptsTheSameIdentity() throws {
        let dir = try scratchDirectory("self-update-wire-ok"); defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("installed")
        try MachOFixture.build(installed, main: "return 0;", runtime: true)
        let candidate = dir.appendingPathComponent("candidate")
        try FileManager.default.copyItem(at: installed, to: candidate)
        XCTAssertNoThrow(try wired.checkCandidate(candidate, installed))
    }

    func testWiredCandidateCheckRefusesAMissingRuntime() throws {
        let dir = try scratchDirectory("self-update-wire-rt"); defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("installed"), candidate = dir.appendingPathComponent("candidate")
        try MachOFixture.build(installed, main: "return 0;", runtime: true)
        try MachOFixture.build(candidate, main: "return 0;", runtime: false)
        XCTAssertThrowsError(try wired.checkCandidate(candidate, installed)) {
            XCTAssertEqual($0 as? SelfUpdateError, .candidateMissingRuntime)
        }
    }

    func testWiredCandidateCheckRefusesAnotherIdentity() throws {
        let dir = try scratchDirectory("self-update-wire-dr"); defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("installed"), candidate = dir.appendingPathComponent("candidate")
        try MachOFixture.build(installed, main: "return 0;", runtime: true)
        try MachOFixture.build(candidate, main: "return 1;", runtime: true)
        XCTAssertThrowsError(try wired.checkCandidate(candidate, installed)) {
            guard case SelfUpdateError.candidateRequirement = $0 else { return XCTFail("\($0)") }
        }
    }

    func testWiredCandidateCheckRunsTheDeveloperIDAssessmentFirst() throws {
        let dir = try scratchDirectory("self-update-wire-devid"); defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("installed")
        try MachOFixture.build(installed, main: "return 0;", runtime: true)
        let refusing = SelfUpdateSignatureVerifier.make(assessDeveloperID: { _ in throw SelfUpdateError.candidateNotDeveloperID("x") })
        XCTAssertThrowsError(try refusing.checkCandidate(installed, installed)) {
            XCTAssertEqual($0 as? SelfUpdateError, .candidateNotDeveloperID("x"))
        }
    }

    /// R10: strict validation, behaviourally. Bytes appended after the signature
    /// pass the plain check (measured: 0) and fail the strict one (measured: -67010).
    func testStrictValidationRefusesDataAppendedAfterTheSignature() throws {
        let dir = try scratchDirectory("self-update-strict"); defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("installed")
        try MachOFixture.build(installed, main: "return 0;", runtime: true)
        let padded = dir.appendingPathComponent("padded")
        var bytes = try Data(contentsOf: installed)
        bytes.append(Data("trailing-bytes-after-signature".utf8))
        try bytes.write(to: padded)
        XCTAssertThrowsError(try SelfUpdateSignatureVerifier.requireSatisfiesRequirement(of: installed, candidate: padded)) {
            guard case SelfUpdateError.candidateRequirement = $0 else { return XCTFail("\($0)") }
        }
    }
}

final class SelfUpdateRunningBinaryTests: XCTestCase {
    /// R3: the positive case. An always-throwing check would refuse every real update.
    func testRunningBinaryCheckAcceptsThisProcessesOwnExecutable() throws {
        XCTAssertNoThrow(try SelfUpdateSignatureVerifier.live.checkRunningIsInstalled(SelfUpdateCommand.runningExecutable()))
    }
}

final class SelfUpdateRound2FilesystemTests: XCTestCase {
    /// R4: `rename` between two links of one file does nothing, which used to
    /// leave the temporary backup link behind after a successful update.
    func testNoBackupLinkIsLeftWhenPreviousAlreadyIsTheTarget() async throws {
        let fixture = try InstallFixture(); defer { fixture.cleanup() }
        XCTAssertEqual(link(fixture.target.path, fixture.target.path + ".previous"), 0)
        _ = try await makeUpdater(executable: fixture.target, source: FakeReleaseSource()).update()
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path)
        XCTAssertFalse(names.contains { $0.hasPrefix(SelfUpdateConstants.backupStagingPrefix) }, "\(names)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.target.path + ".previous")), Data("old-binary\n".utf8))
    }

    /// R5: a lock that cannot be taken for a reason other than another run is
    /// its own error, not "staging" and not "wait for it to finish".
    func testLockFileThatCannotBeOpenedIsALockError() throws {
        let dir = try scratchDirectory("self-update-lock"); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent(SelfUpdateConstants.lockName).path,
                                                   withDestinationPath: "/tmp/elsewhere")
        XCTAssertThrowsError(try SelfUpdater.acquireLock(in: dir)) { error in
            guard case SelfUpdateError.lock(let m) = error else { return XCTFail("\(error)") }
            XCTAssertFalse("\(error)".contains("wait for it"), m)
            XCTAssertFalse("\(error)".contains("stage"), m)
        }
    }

    func testContentionIsStillBusy() throws {
        let dir = try scratchDirectory("self-update-busy"); defer { try? FileManager.default.removeItem(at: dir) }
        let held = try SelfUpdater.acquireLock(in: dir); defer { close(held) }
        XCTAssertThrowsError(try SelfUpdater.acquireLock(in: dir)) { error in
            guard case SelfUpdateError.busy = error else { return XCTFail("\(error)") }
        }
    }
}
