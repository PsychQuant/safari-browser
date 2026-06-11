import XCTest
@testable import SafariBrowser

/// #70 — plain `screenshot` used to surface a raw `AppleScript error: could
/// not create image from window` when the controlling app lacked macOS
/// Screen Recording permission, with no hint that it was a permission
/// problem at all. These tests pin the two fix layers that are unit-testable:
/// the `screenRecordingRequired` error message contract, and the pure
/// stderr classifier the reactive rewrap uses. The proactive
/// `CGPreflightScreenCaptureAccess()` preflight itself is runtime/TCC
/// dependent and is exercised by the e2e tier (`is_capture_denied` in
/// Tests/e2e-test.sh).
///
/// Verify round 1 (5-lens corroborated + DA empirical proof) tightened the
/// contract: the post-preflight variant must NOT assert "stale TCC grant" as
/// the sole cause — the same screencapture stderr fires for vanished/invalid
/// window IDs in a fully-granted environment (`screencapture -l 999999999`
/// → exit 1, "could not create image from window"). The message therefore
/// presents BOTH hypotheses and carries the original stderr.
final class ScreenRecordingPermissionTests: XCTestCase {

    // MARK: - Message contract (fresh denial — preflight failed)

    func testFreshDenialNamesPermissionAndSettingsPath() {
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: false, underlying: nil)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("Screen Recording"),
                      "must name the actual permission, not a generic failure")
        XCTAssertTrue(message.contains("System Settings → Privacy & Security → Screen Recording"),
                      "must give the exact System Settings path, mirroring the accessibilityNotGranted style")
    }

    func testFreshDenialTargetsControllingAppNotBinary() {
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: false, underlying: nil)
            .errorDescription ?? ""
        // The TCC grant attaches to the app that spawned us (Terminal / iTerm /
        // IDE / automation host) — telling the user to authorize
        // "safari-browser" would send them hunting for a non-existent entry.
        XCTAssertTrue(message.contains("Terminal"),
                      "must name the terminal as the grant target example")
        XCTAssertTrue(message.lowercased().contains("controlling"),
                      "must explain the grant attaches to the controlling app")
        XCTAssertTrue(message.lowercased().contains("reopen") || message.lowercased().contains("restart"),
                      "must tell the user the grant only applies after the app restarts")
    }

    func testFreshDenialMentionsManualAddPath() {
        // Verify #70 round 1 (devil's-advocate): the fail-closed preflight
        // prevents the failed capture attempt that would normally register
        // the app in the Screen Recording list — so the user may open
        // System Settings and NOT find their terminal there. The message
        // must mention the manual '+' add path.
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: false, underlying: nil)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("'+'"),
                      "must mention the manual '+' add path for an unlisted app")
        XCTAssertTrue(message.lowercased().contains("not yet listed") || message.lowercased().contains("not listed"),
                      "must explain when the manual add path applies")
    }

    func testFreshDenialOffersDOMAlternatives() {
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: false, underlying: nil)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("snapshot"),
                      "must point at DOM-based commands that work without the permission")
    }

    func testFreshDenialDoesNotMentionPostPreflightCauses() {
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: false, underlying: nil)
            .errorDescription ?? ""
        XCTAssertFalse(message.contains("preflight passed"),
                       "post-preflight paragraph must not leak into the fresh-denial message")
    }

    // MARK: - Message contract (post-preflight failure — two hypotheses)

    func testPostPreflightVariantPresentsBothHypotheses() {
        // Verify #70 round 1 core cluster (codex + logic + regression + DA):
        // asserting "stale TCC grant" as the sole cause misdirects users into
        // TCC surgery when the real cause is a window-lifecycle race. The
        // message must present BOTH the window-race and stale-grant
        // hypotheses, and give the cheap check first.
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: true, underlying: nil)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("preflight passed"),
                      "must say the preflight succeeded yet capture failed")
        XCTAssertTrue(message.lowercased().contains("vanished") || message.lowercased().contains("window"),
                      "must name the window-lifecycle race hypothesis")
        XCTAssertTrue(message.contains("safari-browser documents"),
                      "must give the cheap disambiguation step (list windows) before TCC surgery")
        XCTAssertTrue(message.lowercased().contains("stale"),
                      "must still name the stale-TCC-grant hypothesis")
        XCTAssertTrue(message.contains("Screen Recording"),
                      "still names the permission + settings path")
    }

    func testPostPreflightVariantCarriesUnderlyingStderr() {
        // Round 1 logic lens: the rewrap used to DISCARD the original error,
        // destroying the only signal that would let a user or agent
        // disambiguate. The message must carry it.
        let message = SafariBrowserError.screenRecordingRequired(
            staleGrant: true, underlying: "could not create image from window")
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("could not create image from window"),
                      "must include the original screencapture stderr")
    }

    func testPostPreflightVariantOmitsUnderlyingLineWhenNil() {
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: true, underlying: nil)
            .errorDescription ?? ""
        XCTAssertFalse(message.contains("underlying"),
                       "no dangling 'underlying:' label when there is no captured stderr")
    }

    func testPostPreflightVariantDoesNotBlameTheBinary() {
        // Round 1 codex LOW: "the controlling app or this binary changed"
        // contradicted the fresh message's (correct) claim that the grant
        // attaches to the controlling app, not the binary.
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: true, underlying: nil)
            .errorDescription ?? ""
        XCTAssertFalse(message.contains("this binary"),
                       "stale-grant hypothesis must not contradict the controlling-app model")
    }

    // MARK: - e2e harness compatibility

    func testMessageMatchesE2ECaptureDeniedPattern() {
        // Tests/e2e-test.sh `is_capture_denied` greps case-insensitively for
        // "screen recording" (among other signatures). The rewrap means the
        // raw screencapture stderr no longer escapes, so the NEW message must
        // keep matching or the e2e skip-tolerance breaks.
        for stale in [false, true] {
            let message = SafariBrowserError.screenRecordingRequired(staleGrant: stale, underlying: nil)
                .errorDescription ?? ""
            XCTAssertTrue(message.lowercased().contains("screen recording"),
                          "is_capture_denied must keep matching (staleGrant: \(stale))")
        }
    }

    // MARK: - Reactive rewrap classifier (pure, mirrors #67 staleDialogGuidance)

    func testClassifierMatchesScreencaptureDenialSignature() {
        // The exact stderr observed in #70 (wrapped by runShell's generic
        // appleScriptFailed before the fix).
        XCTAssertTrue(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "AppleScript error: could not create image from window"))
        // Bare screencapture stderr (unwrapped) and the display-capture
        // variant of the same denial.
        XCTAssertTrue(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "could not create image from window"))
        XCTAssertTrue(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "could not create image from display"))
    }

    func testClassifierIsCaseInsensitive() {
        // Round 1 logic LOW: the e2e matcher this classifier mirrors
        // (is_capture_denied) is deliberately case-insensitive; the
        // classifier should not silently diverge on casing drift across
        // macOS releases.
        XCTAssertTrue(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "COULD NOT CREATE IMAGE FROM WINDOW"))
        XCTAssertTrue(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "Could Not Create Image from window"))
    }

    func testClassifierIgnoresUnrelatedErrors() {
        // Unrelated failures must propagate unchanged. NOTE (round 1 DA):
        // screencapture with an unwritable output path exits 0 (silent
        // success — no stderr at all), so "bad path" never even reaches the
        // classifier; these strings are arbitrary non-matching inputs that
        // pin classifier purity, not claims about what screencapture emits.
        XCTAssertFalse(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "No such file or directory"))
        XCTAssertFalse(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "Go to Folder panel did not appear"))
        XCTAssertFalse(ScreenshotCommand.isScreenRecordingDenial(
            errorText: ""))
    }
}
