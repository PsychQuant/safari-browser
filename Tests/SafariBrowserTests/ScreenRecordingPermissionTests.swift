import XCTest
@testable import SafariBrowser

/// #70 — plain `screenshot` used to surface a raw `AppleScript error: could
/// not create image from window` when the controlling app lacked macOS
/// Screen Recording permission, with no hint that it was a permission
/// problem at all. These tests pin the unit-testable fix layers: the
/// `screenRecordingRequired` error message contract, the pure stderr
/// classifier, and the pure underlying-text extractor. The proactive
/// `CGPreflightScreenCaptureAccess()` preflight itself is runtime/TCC
/// dependent and is exercised by the e2e tier (`is_capture_denied` in
/// Tests/e2e-test.sh).
///
/// Contract history:
/// - Verify round 1 (5-lens + DA empirical proof): the same screencapture
///   stderr fires for vanished/invalid window IDs in a fully-granted
///   environment (`screencapture -l 999999999`), so the post-preflight
///   variant must present BOTH hypotheses and carry the original stderr.
/// - Verify round 2: the post-preflight variant must also HEADLINE the
///   actual situation (capture failed after preflight passed) instead of
///   "permission required", must not self-contradict (no "fails closed
///   before any capture attempt" paragraph in a message whose premise is
///   that the preflight passed), and the classifier must match its
///   documented full signatures, not a broader prefix.
final class ScreenRecordingPermissionTests: XCTestCase {

    // MARK: - Message contract (fresh denial — preflight failed)

    func testFreshDenialNamesPermissionAndSettingsPath() {
        let message = SafariBrowserError.screenRecordingRequired(postPreflight: false, underlying: nil)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("Screen Recording"),
                      "must name the actual permission, not a generic failure")
        XCTAssertTrue(message.contains("System Settings → Privacy & Security → Screen Recording"),
                      "must give the exact System Settings path, mirroring the accessibilityNotGranted style")
    }

    func testFreshDenialTargetsControllingAppNotBinary() {
        let message = SafariBrowserError.screenRecordingRequired(postPreflight: false, underlying: nil)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("Terminal"),
                      "must name the terminal as the grant target example")
        XCTAssertTrue(message.lowercased().contains("controlling"),
                      "must explain the grant attaches to the controlling app")
        XCTAssertTrue(message.lowercased().contains("reopen") || message.lowercased().contains("restart"),
                      "must tell the user the grant only applies after the app restarts")
    }

    func testFreshDenialMentionsManualAddPath() {
        // Round 1 DA: the fail-closed preflight prevents the failed capture
        // attempt that would normally register the app in the Screen
        // Recording list — the user may not find their terminal there.
        let message = SafariBrowserError.screenRecordingRequired(postPreflight: false, underlying: nil)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("'+'"),
                      "must mention the manual '+' add path for an unlisted app")
        XCTAssertTrue(message.lowercased().contains("not yet listed") || message.lowercased().contains("not listed"),
                      "must explain when the manual add path applies")
    }

    func testFreshDenialOffersDOMAlternatives() {
        let message = SafariBrowserError.screenRecordingRequired(postPreflight: false, underlying: nil)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("snapshot"),
                      "must point at DOM-based commands that work without the permission")
    }

    func testFreshDenialDoesNotMentionPostPreflightCauses() {
        let message = SafariBrowserError.screenRecordingRequired(postPreflight: false, underlying: nil)
            .errorDescription ?? ""
        XCTAssertFalse(message.contains("preflight passed"),
                       "post-preflight content must not leak into the fresh-denial message")
        XCTAssertFalse(message.lowercased().contains("vanished"),
                       "window-race hypothesis is post-preflight-only")
    }

    // MARK: - Message contract (post-preflight failure — two hypotheses)

    func testPostPreflightVariantHeadlinesFailureNotPermission() {
        // Round 2 (codex MEDIUM + requirements): headlining "permission
        // required" + the full grant block steered users into TCC surgery
        // before the hypotheses note was even visible. The post-preflight
        // variant must open with what actually happened.
        let message = SafariBrowserError.screenRecordingRequired(postPreflight: true, underlying: nil)
            .errorDescription ?? ""
        let firstLine = message.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        XCTAssertTrue(firstLine.lowercased().contains("capture failed"),
                      "headline must state the failure, got: \(firstLine)")
        XCTAssertTrue(firstLine.contains("preflight passed"),
                      "headline must state the preflight passed, got: \(firstLine)")
        XCTAssertFalse(firstLine.contains("permission required"),
                       "must NOT open with the permission-required framing")
    }

    func testPostPreflightVariantPresentsBothHypotheses() {
        // Round 1 core cluster: both hypotheses, cheap check first.
        // Round 2 (codex test-gap finding): assert the SPECIFIC word
        // "vanished" — the generic word "window" appears throughout the
        // base message, so it cannot pin the hypothesis paragraph.
        let message = SafariBrowserError.screenRecordingRequired(postPreflight: true, underlying: nil)
            .errorDescription ?? ""
        XCTAssertTrue(message.lowercased().contains("vanished"),
                      "must name the window-lifecycle race hypothesis explicitly")
        XCTAssertTrue(message.contains("safari-browser documents"),
                      "must give the cheap disambiguation step (list windows) before TCC surgery")
        XCTAssertTrue(message.lowercased().contains("stale"),
                      "must still name the stale-TCC-grant hypothesis")
        XCTAssertTrue(message.contains("Screen Recording"),
                      "still names the permission so guidance (and the e2e matcher) stay anchored")
    }

    func testPostPreflightVariantDoesNotContradictItself() {
        // Round 2 DA: the shared body's manual-'+' paragraph claimed "the
        // preflight fails closed before any capture attempt" — inside a
        // message whose premise is that the preflight PASSED and a capture
        // attempt happened. The post-preflight variant must not include the
        // fresh-denial registration paragraph.
        let message = SafariBrowserError.screenRecordingRequired(postPreflight: true, underlying: nil)
            .errorDescription ?? ""
        XCTAssertFalse(message.contains("fails closed"),
                       "fresh-denial fails-closed paragraph contradicts the post-preflight premise")
        XCTAssertFalse(message.contains("'+'"),
                       "manual-add registration guidance belongs to the fresh-denial variant only")
    }

    func testPostPreflightVariantCarriesUnderlyingStderrFlushLeft() {
        // Round 1 logic: the rewrap used to DISCARD the original error.
        // Round 2 logic: the interpolated line rendered with 16 stray
        // leading spaces (source-indentation leak into the interpolation).
        let message = SafariBrowserError.screenRecordingRequired(
            postPreflight: true, underlying: "could not create image from window")
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("\n(underlying error: could not create image from window)"),
                      "must include the original stderr on its own flush-left line")
        XCTAssertFalse(message.contains("                (underlying error:"),
                       "no source-indentation leak into the interpolated line")
    }

    func testPostPreflightVariantOmitsUnderlyingLineWhenNil() {
        let message = SafariBrowserError.screenRecordingRequired(postPreflight: true, underlying: nil)
            .errorDescription ?? ""
        XCTAssertFalse(message.contains("underlying"),
                       "no dangling 'underlying:' label when there is no captured stderr")
    }

    func testPostPreflightVariantDoesNotBlameTheBinary() {
        let message = SafariBrowserError.screenRecordingRequired(postPreflight: true, underlying: nil)
            .errorDescription ?? ""
        XCTAssertFalse(message.contains("this binary"),
                       "stale-grant hypothesis must not contradict the controlling-app model")
    }

    // MARK: - e2e harness compatibility

    func testMessageMatchesE2ECaptureDeniedPattern() {
        // Tests/e2e-test.sh `is_capture_denied` greps case-insensitively for
        // "screen recording" (among other signatures). The rewrap means the
        // raw screencapture stderr no longer escapes, so BOTH messages must
        // keep matching or the e2e skip-tolerance breaks.
        for postPreflight in [false, true] {
            let message = SafariBrowserError.screenRecordingRequired(
                postPreflight: postPreflight, underlying: nil)
                .errorDescription ?? ""
            XCTAssertTrue(message.lowercased().contains("screen recording"),
                          "is_capture_denied must keep matching (postPreflight: \(postPreflight))")
        }
    }

    // MARK: - Reactive rewrap classifier (pure, mirrors #67 staleDialogGuidance)

    func testClassifierMatchesScreencaptureDenialSignatures() {
        // The exact stderr observed in #70 (wrapped by runShell's generic
        // appleScriptFailed before the fix), bare, and the display variant.
        XCTAssertTrue(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "AppleScript error: could not create image from window"))
        XCTAssertTrue(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "could not create image from window"))
        XCTAssertTrue(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "could not create image from display"))
    }

    func testClassifierIsCaseInsensitive() {
        XCTAssertTrue(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "COULD NOT CREATE IMAGE FROM WINDOW"))
        XCTAssertTrue(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "Could Not Create Image from Display"))
    }

    func testClassifierRejectsBroaderPrefixMatches() {
        // Round 2 (codex MEDIUM): the classifier matched the bare prefix
        // "could not create image", contradicting its own doc ("from
        // window" / "from display" signatures) — any future message like
        // "could not create image file" would have been rewrapped as a
        // permission error. Pin the boundary: full signatures only.
        XCTAssertFalse(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "could not create image file"))
        XCTAssertFalse(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "could not create image at path /tmp/x.png"))
    }

    func testClassifierIgnoresUnrelatedErrors() {
        // Arbitrary non-matching inputs pinning classifier purity. NOTE
        // (round 1 DA): screencapture with an unwritable output path exits 0
        // (silent success), so "bad path" never even reaches the classifier;
        // these are not claims about what screencapture emits.
        XCTAssertFalse(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "No such file or directory"))
        XCTAssertFalse(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "Go to Folder panel did not appear"))
        XCTAssertFalse(ScreenshotCommand.isScreenRecordingDenial(
            errorText: ""))
    }

    // MARK: - Underlying-text extraction (pure, round 2 test-gap fix)

    func testUnderlyingTextUnwrapsAppleScriptFailed() {
        // runCapture carries the RAW stderr — unwrapping runShell's generic
        // appleScriptFailed wrapper so the message doesn't echo its
        // misleading "AppleScript error" prefix (#73's scope).
        let wrapped = SafariBrowserError.appleScriptFailed("could not create image from window")
        XCTAssertEqual(ScreenshotCommand.underlyingText(from: wrapped),
                       "could not create image from window")
    }

    func testUnderlyingTextFallsBackToErrorDescriptionForOtherErrors() {
        struct Dummy: Error {}
        let text = ScreenshotCommand.underlyingText(from: Dummy())
        XCTAssertFalse(text.isEmpty, "non-SafariBrowserError still yields a usable description")
        XCTAssertTrue(text.contains("Dummy"), "falls back to the interpolated error")
    }
}
