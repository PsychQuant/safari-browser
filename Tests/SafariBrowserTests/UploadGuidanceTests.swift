import XCTest
@testable import SafariBrowser

/// #67 — `UploadCommand.staleDialogGuidance` detects the stale native
/// file-dialog signature (the dialog is visible but rejecting keystrokes after
/// a prior aborted attempt — the Cmd+Shift+G "Go to Folder" panel never
/// appears) and returns actionable recovery guidance. Pure-function coverage;
/// the live stale-state behavior needs a real Safari + file dialog to
/// reproduce, so only the rewrap logic is unit-tested here.
final class UploadGuidanceTests: XCTestCase {

    func testGuidanceForGoToFolderTimeout() {
        let err = "AppleScript error: 2741:2747: execution error: "
            + "Go to Folder panel did not appear within 10 seconds (-2700)"
        guard let g = UploadCommand.staleDialogGuidance(forErrorText: err) else {
            return XCTFail("expected guidance for the Go-to-Folder stale-dialog timeout")
        }
        XCTAssertTrue(g.contains("Esc"), "should suggest dismissing the dialog")
        XCTAssertTrue(g.contains("drag-and-drop"), "should suggest the drag-drop fallback")
        XCTAssertTrue(g.contains("#24"), "should note the --js 10 MB cap")
    }

    func testGuidanceForFileDialogTimeout() {
        XCTAssertNotNil(UploadCommand.staleDialogGuidance(
            forErrorText: "File dialog did not appear within 10 seconds"))
    }

    func testNoGuidanceForUnrelatedError() {
        XCTAssertNil(UploadCommand.staleDialogGuidance(
            forErrorText: "Element not found: input[type=file]"))
    }

    func testNoGuidanceForFocusRaceAbort() {
        // The #15 focus-race abort is the FIRST-attempt failure, distinct from
        // the stale-dialog retry loop — must NOT trigger stale-dialog guidance.
        XCTAssertNil(UploadCommand.staleDialogGuidance(
            forErrorText: "Safari lost focus after activate — aborting to avoid sending keystrokes"))
    }
}
