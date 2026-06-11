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
final class ScreenRecordingPermissionTests: XCTestCase {

    // MARK: - Message contract (fresh denial — preflight failed)

    func testFreshDenialNamesPermissionAndSettingsPath() {
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: false)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("Screen Recording"),
                      "must name the actual permission, not a generic failure")
        XCTAssertTrue(message.contains("System Settings → Privacy & Security → Screen Recording"),
                      "must give the exact System Settings path, mirroring the accessibilityNotGranted style")
    }

    func testFreshDenialTargetsControllingAppNotBinary() {
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: false)
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

    func testFreshDenialOffersDOMAlternatives() {
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: false)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("snapshot"),
                      "must point at DOM-based commands that work without the permission")
    }

    func testFreshDenialDoesNotMentionPreflight() {
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: false)
            .errorDescription ?? ""
        XCTAssertFalse(message.contains("preflight passed"),
                       "stale-grant paragraph must not leak into the fresh-denial message")
    }

    // MARK: - Message contract (stale grant — preflight passed, capture failed)

    func testStaleGrantVariantExplainsStaleTCC() {
        let message = SafariBrowserError.screenRecordingRequired(staleGrant: true)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("preflight passed"),
                      "stale variant must say the preflight succeeded yet capture failed")
        XCTAssertTrue(message.lowercased().contains("stale"),
                      "stale variant must name the stale-TCC-grant cause")
        XCTAssertTrue(message.contains("Screen Recording"),
                      "stale variant still names the permission + settings path")
    }

    // MARK: - e2e harness compatibility

    func testMessageMatchesE2ECaptureDeniedPattern() {
        // Tests/e2e-test.sh `is_capture_denied` greps case-insensitively for
        // "screen recording" (among other signatures). The rewrap means the
        // raw screencapture stderr no longer escapes, so the NEW message must
        // keep matching or the e2e skip-tolerance breaks.
        for stale in [false, true] {
            let message = SafariBrowserError.screenRecordingRequired(staleGrant: stale)
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

    func testClassifierIgnoresUnrelatedErrors() {
        // Unrelated failures must propagate unchanged — rewrapping a disk-full
        // or bad-path error as a permission error would misdirect the user
        // exactly the way the raw error did before #70.
        XCTAssertFalse(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "No such file or directory"))
        XCTAssertFalse(ScreenshotCommand.isScreenRecordingDenial(
            errorText: "Go to Folder panel did not appear"))
        XCTAssertFalse(ScreenshotCommand.isScreenRecordingDenial(
            errorText: ""))
    }
}
