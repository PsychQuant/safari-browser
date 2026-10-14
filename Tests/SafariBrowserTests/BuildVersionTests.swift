import XCTest
import ArgumentParser
@testable import SafariBrowser

/// `--version` and its single source of truth (#278, change add-cli-version).
///
/// Tests run through `swift test`, never through the Makefile, so the tracked
/// placeholder is what these see. A stamped value is covered by
/// scripts/stamp-version-test.sh.
final class BuildVersionTests: XCTestCase {

    func testTrackedPlaceholder_isUnknown() {
        XCTAssertEqual(BuildVersion.value, "unknown")
    }

    func testRootCommand_versionComesFromBuildVersion() {
        XCTAssertEqual(SafariBrowser.configuration.version, BuildVersion.value)
    }

    /// swift-argument-parser answers `--version` by throwing a clean-exit
    /// error whose message is the version string. An unknown option would be a
    /// different error, which is what the CLI did before this change.
    func testVersionFlag_isAcceptedAndReportsTheVersion() {
        XCTAssertThrowsError(try SafariBrowser.parseAsRoot(["--version"])) { error in
            XCTAssertEqual(SafariBrowser.exitCode(for: error), ExitCode.success)
            XCTAssertEqual(SafariBrowser.message(for: error), BuildVersion.value)
        }
    }

    func testVersionFlag_isNotAnUnknownOption() {
        do {
            _ = try SafariBrowser.parseAsRoot(["--version"])
            XCTFail("--version should end the parse with a clean exit")
        } catch {
            XCTAssertFalse(
                SafariBrowser.fullMessage(for: error).contains("Unknown option"),
                "--version must be a known option"
            )
        }
    }

    func testStampedValueShape_hasNoWhitespaceOrQuote() {
        // The value is printed on one line and compared by tools; it must stay
        // one token. (Whatever the stamping step writes obeys the same rule.)
        XCTAssertFalse(BuildVersion.value.isEmpty)
        XCTAssertNil(BuildVersion.value.rangeOfCharacter(from: .whitespacesAndNewlines))
        XCTAssertFalse(BuildVersion.value.contains("\""))
    }
}
