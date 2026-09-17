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

        // Counting restores is not enough: two restores both sitting on the
        // success path would satisfy a count, and losing a user's clipboard
        // because an upload failed is exactly the case that matters. Check that
        // one of them is inside the error handler.
        guard let handler = s.range(of: "on error errMsg") else {
            return XCTFail("must have an error handler")
        }
        let afterHandler = s[handler.upperBound...]
        XCTAssertTrue(afterHandler.contains("set the clipboard to oldClip"),
                      "the error handler must restore the clipboard before rethrowing")
        XCTAssertTrue(afterHandler.contains("error errMsg"),
                      "…and must rethrow rather than swallow")
        XCTAssertTrue(s[..<handler.lowerBound].contains("set the clipboard to oldClip"),
                      "the success path must restore too")
    }

    func testFragmentUsesNamedConfirmationWithoutReturnFallback() {
        let s = SafariBridge.fileDialogConfirmationScript()
        XCTAssertTrue(s.contains("splitter groups of sheet 1"))
        XCTAssertTrue(s.contains("click defaultBtn"))
        XCTAssertFalse(s.contains("AXDefault"))
        XCTAssertFalse(s.contains("keystroke"))
        XCTAssertFalse(s.contains("on error"))
    }

    /// Confirmation records its exact button name and never substitutes HID.
    func testFragmentRecordsNamedConfirmationWithoutKeystrokeFallback() {
        let s = SafariBridge.fileDialogConfirmationScript()
        XCTAssertTrue(s.contains("log \"confirming file dialog: pressing named button"))
        XCTAssertFalse(s.contains("falling back"))
        XCTAssertFalse(s.contains("keystroke"))
        XCTAssertFalse(s.contains("display dialog"))
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

    // MARK: - What the callers actually do

    /// `navigateFileDialog` runs its script through an injected runner here, so
    /// this observes the real invocation rather than a factory the function
    /// might have stopped calling.
    func testBridgeNavigationMakesExactlyOneOsascriptCallCarryingTheFragment() async throws {
        var calls: [(String, [String])] = []
        try await SafariBridge.navigateFileDialog(
            path: path, runner: { cmd, args in calls.append((cmd, args)) })

        XCTAssertEqual(calls.count, 1, "one invocation — a second opens a focus-stealing gap (#15)")
        XCTAssertEqual(calls.first?.0, "/usr/bin/osascript")
        XCTAssertEqual(calls.first?.1.first, "-e")
        let script = calls.first?.1.last ?? ""
        XCTAssertTrue(script.contains(SafariBridge.fileDialogNavigationScript(path: path)),
                      "the script actually executed must contain the shared fragment")
    }

    // MARK: - pdf, after #106

    /// #106. `pdf` used to run three osascript invocations — menu click, then
    /// the shared navigation, then the Replace? confirmation — with the gaps
    /// between them open to another app taking focus. That is the race #15
    /// closed for `upload`, left open here because #15's scope was upload.
    /// Sharing the navigation as *text* (#105) is what made merging possible
    /// without either caller giving up its single invocation.
    func testPdfExportIsOneScriptCarryingTheSharedFragment() {
        let s = PdfCommand.exportScript(path: path, windowIndex: 2)

        XCTAssertTrue(s.contains(SafariBridge.fileDialogNavigationScript(path: path, pdfSave: true)),
                      "pdf must embed the shared fragment, not a private copy")
        // All three phases in the one script: if any had stayed behind, it would
        // need its own invocation and the gap would be back.
        XCTAssertTrue(s.contains("click exportItem"), "phase 1: open the sheet")
        XCTAssertTrue(s.contains("repeat until exists sheet 1 of front window"), "phase 1: wait for it")
        XCTAssertTrue(s.contains("keystroke \"g\" using {command down, shift down}"), "phase 2: navigate")
        XCTAssertTrue(s.contains("sheet 1 of sheet 1 of front window"), "phase 3: the Replace? sheet")
    }

    func testPdfChecksFrontmostBeforeTouchingMenus() {
        XCTAssertTrue(PdfCommand.exportScript(path: path, windowIndex: 1).contains("if not frontmost then"),
                      "a menu click on the wrong app is as bad as a keystroke on the wrong app")
    }

    func testPdfRaisesTheResolvedWindow() {
        XCTAssertTrue(PdfCommand.exportScript(path: path, windowIndex: 3)
            .contains("set index of window 3 to 1"),
            "keystrokes and menu clicks reach the front window, so the target must be raised")
    }

    func testPdfRefusesExtraStagingConfirmationWithoutNativeReplacement() {
        let s = PdfCommand.completionWaitScript()
        XCTAssertTrue(s.contains("Unexpected PDF staging confirmation"))
        XCTAssertFalse(s.contains("click"))
        XCTAssertFalse(s.contains("keystroke"))
    }

    // Boundary of what the tests above can see: they reach `navigateFileDialog`
    // and upload's effect plan. They do not reach `uploadViaNativeDialog` —
    // whether it builds the plan at all, and what it does with it, is untested
    // here (stated the same way in `InterferenceWarningTests`). And no
    // output-string test can prove text *came from* the generator rather than
    // being a verbatim copy of it; that needs a source or architecture check.

}
