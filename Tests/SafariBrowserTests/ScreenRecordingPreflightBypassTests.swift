import XCTest
@testable import SafariBrowser

/// #75: `SAFARI_BROWSER_SKIP_SR_PREFLIGHT` parsing.
///
/// The flag disables a fail-closed safety check, so what counts as "set" is
/// worth pinning: an accidentally-emptied variable (`export VAR=`) must not
/// read as on, and neither must arbitrary text a user might assume works.
final class ScreenRecordingPreflightBypassTests: XCTestCase {

    func testAcceptsTheSpellingsPeopleActuallyType() {
        for raw in ["1", "true", "TRUE", "yes", "on", " 1 ", "True"] {
            XCTAssertTrue(
                ScreenshotCommand.isTruthyEnvFlag(raw),
                "\(raw.debugDescription) should enable the bypass")
        }
    }

    func testUnsetOrEmptyLeavesThePreflightOn() {
        // `export VAR=` leaves an empty string, not an absent variable — the
        // most likely way to accidentally "set" this.
        for raw in [nil, "", "   "] as [String?] {
            XCTAssertFalse(
                ScreenshotCommand.isTruthyEnvFlag(raw),
                "\(String(describing: raw)) must not disable a safety check")
        }
    }

    func testUnrecognisedValuesLeaveThePreflightOn() {
        // Fail-safe direction: an unrecognised value keeps the check running
        // rather than guessing the user meant to disable it.
        for raw in ["0", "false", "no", "off", "please", "-1", "2"] {
            XCTAssertFalse(
                ScreenshotCommand.isTruthyEnvFlag(raw),
                "\(raw.debugDescription) must not disable the preflight")
        }
    }
}
