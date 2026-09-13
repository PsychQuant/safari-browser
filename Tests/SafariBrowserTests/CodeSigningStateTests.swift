import XCTest

@testable import SafariBrowser

/// #109: the FDA remediation text differs by signing state, and the two
/// states need genuinely different advice — telling an ad-hoc user to add the
/// binary sends them to a grant that stops working on the next rebuild.
/// Classification is tested with actual signatures and misleading paths;
/// codesign output is never a classifier input.
final class CodeSigningStateTests: XCTestCase {

    func testUnsignedPathCannotForgeSigningIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("signing-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let forgedDirectory = directory.appendingPathComponent("Authority=Developer ID Application", isDirectory: true)
        try FileManager.default.createDirectory(at: forgedDirectory, withIntermediateDirectories: true)
        let plain = directory.appendingPathComponent("unsigned")
        let forged = forgedDirectory.appendingPathComponent("unsigned")
        try Data("unsigned fixture".utf8).write(to: plain)
        try FileManager.default.copyItem(at: plain, to: forged)
        XCTAssertEqual(CodeSigningState.state(ofBinaryAt: plain), .unknown)
        XCTAssertEqual(CodeSigningState.state(ofBinaryAt: forged), .unknown,
                       "file names cannot establish a durable code signature")
    }

    func testAppleSystemSignatureIsDurable() {
        XCTAssertEqual(CodeSigningState.state(ofBinaryAt: URL(fileURLWithPath: "/bin/ls")), .durable)
    }

    func testMissingBinaryHasUnknownState() {
        XCTAssertEqual(CodeSigningState.state(ofBinaryAt: URL(fileURLWithPath: "/tmp/missing-signature-\(UUID().uuidString)")), .unknown)
    }

    func testAdHocClassificationReadsSignatureFlags() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("adhoc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: file)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", file.path]
        signer.standardOutput = FileHandle.nullDevice
        signer.standardError = FileHandle.nullDevice
        try signer.run()
        signer.waitUntilExit()
        XCTAssertEqual(signer.terminationStatus, 0)
        XCTAssertEqual(CodeSigningState.state(ofBinaryAt: file), .adHoc)
    }

    // MARK: - Guidance content

    func testAdHocGuidanceNamesRebuildCaveatAndBothRoutes() {
        let text = CodeSigningState.adHoc.fullDiskAccessGuidance
        XCTAssertTrue(
            text.contains("rebuilding the binary can invalidate"),
            "ad-hoc guidance must state the rebuild caveat")
        XCTAssertTrue(
            text.contains("make install-signed"),
            "must name the signed-build route")
        XCTAssertTrue(
            text.lowercased().contains("terminal"),
            "must name the grant-the-terminal route")
    }

    func testDurableGuidanceExplainsIdentityAndRequirementContinuity() {
        let text = CodeSigningState.durable.fullDiskAccessGuidance
        XCTAssertTrue(text.contains("identity and designated requirement stay the same"))
        XCTAssertTrue(text.contains("granting access again"))
        XCTAssertTrue(text.contains("Full Disk Access"))
        XCTAssertFalse(
            text.contains("rebuilding the binary can invalidate"),
            "the caveat does not apply to a Developer ID build and would mislead")
        XCTAssertFalse(
            text.lowercased().contains("terminal"),
            "a durable per-binary grant is available, so do not suggest the broader one")
    }

    func testGuidanceDiffersBetweenStates() {
        XCTAssertNotEqual(
            CodeSigningState.adHoc.fullDiskAccessGuidance,
            CodeSigningState.durable.fullDiskAccessGuidance)
    }

    // MARK: - Error surface

    func testFullDiskAccessErrorEmbedsStateSpecificGuidance() {
        let adHoc = SafariBrowserError.fullDiskAccessRequired(
            path: "/Users/example/Library/Safari/History.db", signing: .adHoc)
        let devID = SafariBrowserError.fullDiskAccessRequired(
            path: "/Users/example/Library/Safari/History.db", signing: .durable)

        XCTAssertTrue(adHoc.errorDescription?.contains("make install-signed") == true)
        XCTAssertTrue(devID.errorDescription?.contains("make install-signed") == false)
        // Both name the file they failed on.
        XCTAssertTrue(adHoc.errorDescription?.contains("History.db") == true)
        XCTAssertTrue(devID.errorDescription?.contains("History.db") == true)
    }

    func testMissingFileErrorIsDistinctFromPermissionError() {
        let missing = SafariBrowserError.safariDataFileNotFound(
            path: "/Users/example/Library/Safari/CloudTabs.db")
        let denied = SafariBrowserError.fullDiskAccessRequired(
            path: "/Users/example/Library/Safari/CloudTabs.db", signing: .adHoc)

        // A missing file is a normal configuration state; it must not tell the
        // user to go grant a permission they already have.
        XCTAssertFalse(missing.errorDescription?.contains("Full Disk Access") == true)
        XCTAssertTrue(denied.errorDescription?.contains("Full Disk Access") == true)
    }
}
