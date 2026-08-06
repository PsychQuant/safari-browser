import XCTest
@testable import SafariBrowser

/// #105 — the Go-to-Folder navigation sequence existed twice: once in
/// `SafariBridge.navigateFileDialog` (which `pdf` calls) and once inlined in
/// `UploadCommand.uploadViaNativeDialog`.
///
/// The duplication was deliberate, not an oversight. #15 found that splitting
/// the flow across two `osascript` invocations left a window where another app
/// could steal focus between them, and fixed it by merging activate + wait +
/// paste + click into one script — which meant inlining the shared function's
/// body. So "just call the shared function" would reintroduce the race.
///
/// The way out is to share the *text* rather than the *execution*:
/// `fileDialogNavigationScript(path:)` returns an AppleScript fragment that each
/// caller embeds in its own single invocation. One source of truth, atomicity
/// preserved.
///
/// These tests guard the property that actually regresses — that both callers
/// keep using the generator instead of drifting back into private copies.
final class FileDialogScriptSharingTests: XCTestCase {

    private let path = "/tmp/example.mp3"

    // MARK: - The fragment itself

    func testFragmentPerformsTheGoToFolderSequence() {
        let s = SafariBridge.fileDialogNavigationScript(path: path)
        XCTAssertTrue(s.contains("keystroke \"g\" using {command down, shift down}"),
                      "must open the Go to Folder panel")
        XCTAssertTrue(s.contains("keystroke \"v\" using command down"),
                      "must paste the path rather than type it — typing breaks on non-ASCII")
        XCTAssertTrue(s.contains("keystroke return"), "must confirm the path")
    }

    func testFragmentSavesAndRestoresTheUsersClipboard() {
        let s = SafariBridge.fileDialogNavigationScript(path: path)
        XCTAssertTrue(s.contains("set oldClip to the clipboard"),
                      "must capture the clipboard before overwriting it")
        // Restored on both the happy path and the error path — losing a user's
        // clipboard because an upload failed is not an acceptable side effect.
        let restores = s.components(separatedBy: "set the clipboard to oldClip").count - 1
        XCTAssertGreaterThanOrEqual(restores, 2,
                                    "clipboard must be restored on the error path too, not just on success")
        XCTAssertTrue(s.contains("on error errMsg"), "must have an error handler that restores")
    }

    func testFragmentClicksTheDefaultButtonBeforeFallingBackToReturn() {
        let s = SafariBridge.fileDialogNavigationScript(path: path)
        XCTAssertTrue(s.contains("AXDefault"),
                      "must click the default button by attribute — button labels are localized")
        guard let click = s.range(of: "AXDefault"),
              let fallback = s.range(of: "on error", range: click.upperBound..<s.endIndex) else {
            return XCTFail("expected a keystroke-return fallback after the AXDefault click")
        }
        XCTAssertTrue(s[fallback.upperBound...].contains("keystroke return"),
                      "the fallback after a failed AXDefault click must still confirm")
    }

    func testFragmentRechecksFrontmostImmediatelyBeforeKeystrokes() {
        let s = SafariBridge.fileDialogNavigationScript(path: path)
        XCTAssertTrue(s.contains("if not frontmost then"),
                      "must re-check frontmost inside the fragment — the caller's own check happens "
                      + "before its wait loop, and focus can be lost while waiting (#15)")
    }

    func testFragmentEscapesThePath() {
        let nasty = #"/tmp/it's "quoted" \ odd.mp3"#
        let s = SafariBridge.fileDialogNavigationScript(path: nasty)
        XCTAssertTrue(s.contains(nasty.escapedForAppleScript),
                      "path must be escaped for AppleScript — a raw quote would end the string literal")
        XCTAssertFalse(s.contains("\"\(nasty)\""), "must not embed the raw unescaped path")
    }

    // MARK: - Both callers share it (the actual regression guard)

    func testUploadEmbedsTheSharedFragment() {
        let script = UploadCommand.nativeDialogScript(path: path, window: nil)
        XCTAssertTrue(script.contains(SafariBridge.fileDialogNavigationScript(path: path)),
                      "upload must embed the shared fragment verbatim, not keep a private copy")
    }

    func testBridgeNavigationEmbedsTheSharedFragment() {
        let script = SafariBridge.fileDialogNavigationOuterScript(path: path)
        XCTAssertTrue(script.contains(SafariBridge.fileDialogNavigationScript(path: path)),
                      "navigateFileDialog's script must embed the same fragment")
    }

    /// The point of #15: upload's flow is ONE osascript. If a future change
    /// splits it again the focus-stealing race comes back, and no unit test
    /// would notice unless it asserts on the structure.
    func testUploadScriptIsSelfContainedAndAtomic() {
        let script = UploadCommand.nativeDialogScript(path: path, window: nil)
        XCTAssertTrue(script.contains("tell application \"Safari\" to activate"),
                      "the single script must do its own activate")
        XCTAssertTrue(script.contains("repeat until exists sheet 1 of front window"),
                      "the single script must do its own wait for the dialog")
        XCTAssertTrue(script.contains("keystroke \"g\" using {command down, shift down}"),
                      "…and the navigation, all in one invocation")
    }

    func testUploadRaisesTheTargetWindowWhenOneIsGiven() {
        let none = UploadCommand.nativeDialogScript(path: path, window: nil)
        XCTAssertFalse(none.contains("set index of window"),
                       "no targeting flag → no window raise")
        let some = UploadCommand.nativeDialogScript(path: path, window: 3)
        XCTAssertTrue(some.contains("set index of window 3 to 1"),
                      "keystrokes only reach the front window, so an explicit target must be raised first")
    }
}
