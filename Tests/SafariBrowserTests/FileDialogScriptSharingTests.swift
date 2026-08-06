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

    /// Upload is reached through its effect plan, which #104's tests prove the
    /// interpreter reads verbatim and runs one script per `.runCombinedScript`.
    /// Asserting here that the plan carries exactly one script, and that the
    /// script embeds the fragment, chains onto that: a private copy or a second
    /// invocation would break one link or the other.
    func testUploadPlanCarriesOneScriptContainingTheFragment() {
        let plan = UploadCommand.nativeUploadEffects(
            selector: "input[type=file]", path: path, window: nil)

        let scripts: [String] = plan.compactMap {
            if case .runCombinedScript(let s) = $0 { return s }
            return nil
        }
        XCTAssertEqual(scripts.count, 1, "splitting the script reintroduces the #15 focus race")
        XCTAssertTrue(scripts[0].contains(SafariBridge.fileDialogNavigationScript(path: path)),
                      "upload must embed the shared fragment, not keep a private copy")
        XCTAssertTrue(scripts[0].contains("tell application \"Safari\" to activate"),
                      "the one script must do its own activate…")
        XCTAssertTrue(scripts[0].contains("repeat until exists sheet 1 of front window"),
                      "…and its own wait for the dialog, since it cannot rely on a second call")
    }

    // Boundary of what the tests above can see: they reach `navigateFileDialog`
    // and upload's effect plan. They do not reach `uploadViaNativeDialog` —
    // whether it builds the plan at all, and what it does with it, is untested
    // here (stated the same way in `InterferenceWarningTests`). And no
    // output-string test can prove text *came from* the generator rather than
    // being a verbatim copy of it; that needs a source or architecture check.

    func testUploadRaisesTheTargetWindowWhenOneIsGiven() {
        let none = UploadCommand.nativeDialogScript(path: path, window: nil)
        XCTAssertFalse(none.contains("set index of window"),
                       "no targeting flag → no window raise")
        let some = UploadCommand.nativeDialogScript(path: path, window: 3)
        XCTAssertTrue(some.contains("set index of window 3 to 1"),
                      "keystrokes only reach the front window, so an explicit target must be raised first")
    }
}
