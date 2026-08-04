import XCTest
@testable import SafariBrowser

/// #98: the permission-request command.
///
/// The requests themselves raise real system dialogs, so what is testable here
/// is everything around them — the exit contract, the wording, and the one
/// string constant whose corruption would disable prompting without any
/// symptom at all.
final class SetupCommandTests: XCTestCase {

    /// `AXIsProcessTrustedWithOptions` ignores unrecognised keys rather than
    /// rejecting them, so a typo would silently stop the prompt from appearing
    /// while every other line of output stayed identical. Pin the literal.
    /// Reads the SDK's own `kAXTrustedCheckOptionPrompt` at runtime.
    ///
    /// Swift 6 refuses to reference it at compile time — it is a global `var`
    /// in the headers, which strict concurrency treats as shared mutable state.
    /// That is also why the production code carries a string literal. Going
    /// through `dlsym` gets the real value anyway, so this stays a genuine
    /// cross-check rather than a test asserting our own literal back at us.
    private func sdkPromptKey() -> String? {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kAXTrustedCheckOptionPrompt") else { return nil }
        guard let value = symbol.assumingMemoryBound(to: CFString?.self).pointee else { return nil }
        return value as String
    }

    func testAXPromptOptionKeyMatchesTheSDKConstant() {
        guard let sdk = sdkPromptKey() else {
            return XCTFail("could not read kAXTrustedCheckOptionPrompt from the SDK — "
                + "the literal in SetupCommand is then unverified, which is the situation this test exists to prevent")
        }
        XCTAssertEqual(
            SetupCommand.axPromptOptionKey, sdk,
            "the prompt option key must equal the SDK constant — a mismatch disables prompting silently")
    }

    func testExitIsSuccessOnlyWhenBothPermissionsAreGranted() {
        // Callers script this (`setup --check && run-the-automation`), so a
        // partial grant must not read as ready.
        XCTAssertTrue(SetupCommand.allGranted(accessibility: true, screenRecording: true))
        XCTAssertFalse(SetupCommand.allGranted(accessibility: true, screenRecording: false))
        XCTAssertFalse(SetupCommand.allGranted(accessibility: false, screenRecording: true))
        XCTAssertFalse(SetupCommand.allGranted(accessibility: false, screenRecording: false))
    }

    func testStatusLineNeverLetsNotGrantedReadAsGranted() {
        let yes = SetupCommand.statusLine(name: "Accessibility", granted: true, usedFor: "x")
        let no = SetupCommand.statusLine(name: "Accessibility", granted: false, usedFor: "x")
        XCTAssertTrue(yes.contains("✓"))
        XCTAssertTrue(no.contains("✗"))
        XCTAssertTrue(no.contains("NOT granted"),
                      "the negative case must be unmissable when skimming: \(no)")
        XCTAssertNotEqual(yes, no)
    }

    func testAfterNotesCoverTheThreeThingsThatLookLikeBugs() {
        let notes = SetupCommand.afterNotes
        // Granting mid-process does not take effect until the next launch, so
        // the status printed right after a successful grant still says NOT
        // granted. Without this line that reads as the grant having failed.
        XCTAssertTrue(notes.contains("NEXT run"), notes)
        // The grant may land on the terminal rather than this binary, so the
        // path printed above may not be the name to look for in Settings.
        XCTAssertTrue(notes.contains("responsible"), notes)
        // macOS offers the Screen Recording prompt once per app, ever.
        XCTAssertTrue(notes.contains("'+'"), notes)
    }

    func testResolvedBinaryPathIsAbsolute() {
        // System Settings lists a real file; a relative path or a symlink name
        // sends the reader looking for something that is not in the list.
        let path = SetupCommand.resolvedBinaryPath()
        XCTAssertTrue(path.hasPrefix("/"), "expected an absolute path, got \(path)")
    }
}
