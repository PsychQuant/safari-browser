import XCTest

@testable import SafariBrowser

/// #109: the FDA remediation text differs by signing state, and the two
/// states need genuinely different advice — telling an ad-hoc user to add the
/// binary sends them to a grant that stops working on the next rebuild.
/// Parsing is tested against captured `codesign -dvv` output so the assertions
/// do not depend on how *this* build happens to be signed.
final class CodeSigningStateTests: XCTestCase {

    /// Real `codesign -dvv` output shape for an ad-hoc signed binary —
    /// what `make install` currently produces.
    private let adHocOutput = """
        Executable=/Users/example/bin/safari-browser
        Identifier=com.checheng.safari-browser
        Format=Mach-O universal (x86_64 arm64)
        CodeDirectory v=20400 size=9012 flags=0x2(adhoc) hashes=271+7 location=embedded
        Signature=adhoc
        Info.plist entries=4
        TeamIdentifier=not set
        """

    /// Shape for a Developer ID signed, hardened-runtime binary.
    private let developerIDOutput = """
        Executable=/Users/example/bin/ExampleTool
        Identifier=ExampleTool
        Format=Mach-O universal (x86_64 arm64)
        CodeDirectory v=20500 size=18875 flags=0x10000(runtime) hashes=579+7 location=embedded
        Signature size=8968
        Authority=Developer ID Application: EXAMPLE OWNER (ABCDE12345)
        Authority=Developer ID Certification Authority
        Authority=Apple Root CA
        TeamIdentifier=ABCDE12345
        """

    // MARK: - Parsing

    func testParsesAdHocSignature() {
        XCTAssertEqual(CodeSigningState.parse(adHocOutput), .adHoc)
    }

    func testParsesDeveloperIDSignature() {
        XCTAssertEqual(CodeSigningState.parse(developerIDOutput), .developerID)
    }

    func testUnrecognisedOutputIsUnknown() {
        XCTAssertEqual(CodeSigningState.parse(""), .unknown)
        XCTAssertEqual(CodeSigningState.parse("code object is not signed at all"), .unknown)
    }

    func testAdHocWinsOverAuthorityLine() {
        // Defensive: if output ever carried both markers, ad-hoc is the
        // conservative read — it produces the guidance with the caveat.
        XCTAssertEqual(
            CodeSigningState.parse(adHocOutput + "\nAuthority=Developer ID Application: X"),
            .adHoc)
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

    func testDeveloperIDGuidancePointsAtTheBinaryWithoutTheCaveat() {
        let text = CodeSigningState.developerID.fullDiskAccessGuidance
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
            CodeSigningState.developerID.fullDiskAccessGuidance)
    }

    // MARK: - Error surface

    func testFullDiskAccessErrorEmbedsStateSpecificGuidance() {
        let adHoc = SafariBrowserError.fullDiskAccessRequired(
            path: "/Users/example/Library/Safari/History.db", signing: .adHoc)
        let devID = SafariBrowserError.fullDiskAccessRequired(
            path: "/Users/example/Library/Safari/History.db", signing: .developerID)

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
