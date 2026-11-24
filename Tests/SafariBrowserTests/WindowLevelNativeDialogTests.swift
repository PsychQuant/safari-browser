import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #353: `pdf` and the native `upload` paths name the window they resolved by its id, from the first step to
/// the script that sends keystrokes.
///
/// These tests stop at the script: the export script and the dialog script go straight to `osascript` in the
/// product, and nothing here runs them. What a keystroke does on a real Safari is checked in the acceptance
/// run, not here.
final class WindowLevelNativeDialogTests: XCTestCase {

    private typealias Fake = WindowLevelFakeSafari

    private let uploadPath = "/tmp/window-level-fixture.txt"

    // MARK: pdf

    private func exportPlan(_ flags: [String], fake: Fake) async throws -> PdfCommand.ExportPlan {
        let command = try PdfCommand.parse(["--allow-hid"] + flags + ["/tmp/out.pdf"])
        return try await fake.drive {
            try await command.plannedExport(stagingPath: "/tmp/staging/out.pdf", remaining: { 30 })
        }
    }

    /// Asserts that `needles` occur in `text` in this order.
    private func assertOrder(_ needles: [String], in text: String, file: StaticString = #filePath, line: UInt = #line) {
        var cursor = text.startIndex
        for needle in needles {
            guard let range = text.range(of: needle, range: cursor..<text.endIndex) else {
                return XCTFail("missing, or out of order: \(needle)\n\(text)", file: file, line: line)
            }
            cursor = range.upperBound
        }
    }

    /// The export script's first Safari block (everything it asks Safari before System Events is involved).
    private func openingBlock(of script: String) throws -> String {
        let afterHandlers = try XCTUnwrap(script.range(of: "set pdfEndTime to"))
        let start = try XCTUnwrap(script.range(of: "tell application \"Safari\"", range: afterHandlers.upperBound..<script.endIndex))
        let end = try XCTUnwrap(script.range(of: "end tell", range: start.upperBound..<script.endIndex))
        return String(script[start.lowerBound..<end.upperBound])
    }

    /// Runs that block against `fake` (it contains no keystroke and no System Events statement) and returns
    /// what it did.
    private func runOpeningBlock(of plan: PdfCommand.ExportPlan, on fake: Fake) async throws -> [Fake.Action] {
        let block = try openingBlock(of: plan.script)
        XCTAssertFalse(block.contains("System Events") || block.contains("keystroke"), block)
        _ = try await fake.drive { try await SafariBridge.runAppleScript(block) }
        return fake.actions
    }

    /// The first Safari block of the export script sent before #353 for the front window.
    private static let pdfFrontWindowBlock = """
        tell application "Safari"
            set pdfWindowID to id of window 1
            set pdfPageURL to URL of current tab of window 1
            set index of window 1 to 1
            activate
        end tell
        """

    // spec-example: pdf-export / export script by window id
    func testExportScriptByWindowID() async throws {
        // --window 2: pinned, and the export script names the window by its id from its first statement.
        let pinned = Fake()
        let byNumber = try await exportPlan(["--window", "2"], fake: pinned)
        assertOrder([
            "if not (exists window id 5822) then error \"SB_WINDOW_GONE\" number 9002",
            "set pdfPageURL to URL of current tab of window id 5822",
            "set index of window id 5822 to 1",
            "activate",
        ], in: byNumber.script)
        XCTAssertFalse(byNumber.script.contains("set _t to") || byNumber.script.contains("set current tab"),
                       "a window target says nothing about a tab:\n\(byNumber.script)")
        XCTAssertFalse(Fake.namesAPosition(byNumber.script), byNumber.script)
        XCTAssertFalse(byNumber.switchesTab)
        XCTAssertFalse(pinned.scripts(afterFirst: Fake.isAnchor).contains(where: Fake.namesAPosition), pinned.transcript)
        let pinnedActions = try await runOpeningBlock(of: byNumber, on: pinned)
        XCTAssertEqual(pinnedActions, [.raised(windowID: 5822), .activated])

        // A background tab found by its URL: the switch is inside the script, checked first, before the raise.
        let byURLFake = Fake()
        let byURL = try await exportPlan(["--url", "work.example/a2"], fake: byURLFake)
        assertOrder([
            "if not (exists window id 5822) then error \"SB_WINDOW_GONE\" number 9002",
            "set _t to tab 2 of window id 5822",
            "does not contain \"work.example/a2\"",
            "SB_TARGET_CHANGED",
            "set current tab of window id 5822 to _t",
            "set pdfPageURL to URL of current tab of window id 5822",
            "set index of window id 5822 to 1",
            "activate",
        ], in: byURL.script)
        XCTAssertTrue(byURL.switchesTab)
        XCTAssertFalse(byURLFake.scripts.contains { $0.contains("set current tab") },
                       "no separate AppleScript switches the tab:\n\(byURLFake.transcript)")
        XCTAssertEqual(byURLFake.actions, [])
        let byURLActions = try await runOpeningBlock(of: byURL, on: byURLFake)
        XCTAssertEqual(byURLActions, [.madeCurrent(windowID: 5822, tab: 2), .raised(windowID: 5822), .activated])

        // The current tab found by its URL: checked all the same, and nothing is made current.
        let currentFake = Fake()
        let byCurrent = try await exportPlan(["--url", "work.example/a1"], fake: currentFake)
        assertOrder([
            "if not (exists window id 5822) then error \"SB_WINDOW_GONE\" number 9002",
            "set _t to tab 1 of window id 5822",
            "does not contain \"work.example/a1\"",
            "SB_TARGET_CHANGED",
            "set pdfPageURL to URL of current tab of window id 5822",
            "set index of window id 5822 to 1",
        ], in: byCurrent.script)
        XCTAssertFalse(byCurrent.switchesTab)
        let byCurrentActions = try await runOpeningBlock(of: byCurrent, on: currentFake)
        XCTAssertEqual(byCurrentActions, [.raised(windowID: 5822), .activated], "tab 1 is current: no tab is made current")

        // …and when that tab shows another URL by the time the script runs, the block stops before the raise.
        let moved = try await exportPlan(["--url", "work.example/a1"], fake: Fake())
        var windows = Fake.threeWindows
        windows[1].tabs[0] = "https://other.example/"
        let changed = Fake(windows: windows)
        do {
            _ = try await runOpeningBlock(of: moved, on: changed)
            XCTFail("the URL check must stop the export")
        } catch SafariBrowserError.appleScriptFailed(let message) {
            XCTAssertTrue(message.contains("SB_TARGET_CHANGED"), message)
            XCTAssertEqual(changed.actions, [], "nothing is switched, raised or activated")
        }

        // A tab named by its position: the same, without the URL check.
        let byPositionFake = Fake()
        let byPosition = try await exportPlan(["--window-id", "5822", "--tab-in-window", "2"], fake: byPositionFake)
        assertOrder([
            "if not (exists window id 5822) then error \"SB_WINDOW_GONE\" number 9002",
            "if (count of tabs of window id 5822) < 2 then error \"SB_TAB_GONE\" number 9003",
            "set _t to tab 2 of window id 5822",
            "set current tab of window id 5822 to _t",
            "set pdfPageURL to URL of current tab of window id 5822",
            "set index of window id 5822 to 1",
            "activate",
        ], in: try openingBlock(of: byPosition.script))
        XCTAssertFalse(byPosition.script.contains("SB_TARGET_CHANGED"), byPosition.script)
        let byPositionActions = try await runOpeningBlock(of: byPosition, on: byPositionFake)
        XCTAssertEqual(byPositionActions, [.madeCurrent(windowID: 5822, tab: 2), .raised(windowID: 5822), .activated])

        // The tab the resolution named is gone by the time the script runs (the window is still open): the
        // block stops with the tab-gone marker before anything is switched or raised, and the error a caller
        // reads is a miss on that tab, not Safari's "invalid index".
        var oneTab = Fake.threeWindows
        oneTab[1].tabs.removeLast()
        let shrunk = Fake(windows: oneTab)
        do {
            _ = try await runOpeningBlock(of: byPosition, on: shrunk)
            XCTFail("tab 2 is gone")
        } catch SafariBrowserError.appleScriptFailed(let message) {
            XCTAssertEqual(SafariBridge.appleScriptErrorCode(in: message), 9003, message)
            XCTAssertEqual(shrunk.actions, [], "nothing is switched, raised or activated")
        }
        do {
            try await shrunk.drive {
                try await SafariBridge.translatingWindowLevelMarkers(target: byPosition.missTarget, profile: byPosition.profile) {
                    throw SafariBrowserError.appleScriptFailed("42:118: execution error: SB_TAB_GONE (9003)")
                }
            }
            XCTFail("expected documentNotFound")
        } catch SafariBrowserError.documentNotFound(let pattern, _) {
            XCTAssertEqual(pattern, "window id 5822 tab 2")
        }

        // No targeting flag: the block sent before.
        let plain = try await exportPlan([], fake: Fake())
        XCTAssertTrue(plain.script.contains(Self.pdfFrontWindowBlock), plain.script)
        XCTAssertFalse(plain.script.contains("SB_WINDOW_GONE"), plain.script)
        XCTAssertFalse(plain.script.contains("SB_TAB_GONE"), plain.script)

        // The script reports that the pinned window is gone: the error a caller reads names `--window 2`.
        do {
            try await pinned.drive {
                try await SafariBridge.translatingWindowLevelMarkers(target: byNumber.missTarget, profile: byNumber.profile) {
                    throw SafariBrowserError.appleScriptFailed("42:118: execution error: SB_WINDOW_GONE (9002)")
                }
            }
            XCTFail("expected documentNotFound")
        } catch SafariBrowserError.documentNotFound(let pattern, _) {
            XCTAssertEqual(pattern, "window 2 (window id 5822 at command start)")
        }
    }

    func testTheOwnerChecksOfTheExportScriptStillCompareIDs() throws {
        let script = PdfCommand.exportScript(path: "/tmp/staging/out.pdf", window: .id(5822))
        XCTAssertTrue(script.contains("if id of front window is not expectedID then error"), script)
        XCTAssertTrue(script.contains("set pdfWindowID to 5822"), script)
        // Safari's `front window` is named only inside the owner check.
        let handlerEnd = try XCTUnwrap(script.range(of: "end verifyPDFOwner"))
        let afterHandler = script[handlerEnd.upperBound...]
        let systemEvents = try XCTUnwrap(afterHandler.range(of: "tell application \"System Events\""))
        XCTAssertFalse(afterHandler[..<systemEvents.lowerBound].contains("front window"),
                       "the opening Safari block must not name the front window")
    }

    /// The "the save dialog may still be open" advice follows only an error after which it can be: a target
    /// that was never found, or that changed before the script did anything, opened no dialog.
    func testTheSaveDialogAdviceFollowsOnlyAnErrorThatCanLeaveOneOpen() {
        XCTAssertFalse(PdfCommand.needsRecoveryAdvice(
            after: SafariBrowserError.documentNotFound(pattern: "window 9", availableDocuments: [])))
        XCTAssertFalse(PdfCommand.needsRecoveryAdvice(
            after: SafariBrowserError.targetChangedBeforeActing(expected: "window id 5822 tab 2")))
        XCTAssertTrue(PdfCommand.needsRecoveryAdvice(
            after: SafariBrowserError.targetChangedBeforeActing(expected: "window id 5822 tab 2", stage: .afterFileDialog)))
        XCTAssertTrue(PdfCommand.needsRecoveryAdvice(
            after: SafariBrowserError.appleScriptFailed("execution error: Save dialog did not appear (-2700)")))
        XCTAssertTrue(PdfCommand.needsRecoveryAdvice(after: CancellationError()))
    }

    /// A shape check, not a proof (`run()` needs a GUI session and the keyboard): the advice line is written
    /// only inside the `needsRecoveryAdvice` branch.
    func testTheSaveDialogAdviceIsWrittenOnlyInsideItsCheck() throws {
        let source = try String(contentsOfFile: "Sources/SafariBrowser/Commands/PdfCommand.swift", encoding: .utf8)
        let lines = source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let advice = lines.indices.filter { lines[$0].contains("PDF native export failed; inspect Safari") }
        XCTAssertEqual(advice.count, 1, "the advice is written in one place")
        let index = try XCTUnwrap(advice.first)
        XCTAssertEqual(lines[index - 1], "if Self.needsRecoveryAdvice(after: error) {")
        XCTAssertEqual(lines[index + 1], "}")
    }

    // MARK: upload

    private struct Upload {
        let plan: UploadCommand.NativeUploadPlan
        let notices: [String]
        let warnings: [String]
        let dialogScript: String
    }

    /// Plans a native upload against `fake`, then runs it with `UploadCommand.runNativeUpload`, the function
    /// the command itself calls: only the System Events probe, the dialog script's runner and stderr are
    /// replaced, so which document is clicked and how a failed check is reported are the product's.
    private func upload(_ flags: [String], fake: Fake) async throws -> Upload {
        let command = try UploadCommand.parse(["--native", "input[type=file]", uploadPath] + flags)
        var notices: [String] = []
        let plan = try await fake.drive {
            try await command.nativeUploadPlan(expandedPath: self.uploadPath, notice: { notices.append($0) })
        }
        var warnings: [String] = []
        var scripts: [String] = []
        try await fake.drive {
            try await command.runNativeUpload(
                plan,
                ensureLive: {},
                runDialogScript: { script, _ in scripts.append(script) },
                warn: { warnings.append($0) })
        }
        XCTAssertEqual(scripts.count, 1, "one combined dialog script (#15)")
        return Upload(plan: plan, notices: notices, warnings: warnings, dialogScript: scripts.first ?? "")
    }

    /// The Safari block a dialog script by window id opens with (everything it asks Safari before it
    /// activates Safari and System Events is involved).
    private func openingBlock(ofDialog script: String) throws -> String {
        let handlerEnd = try XCTUnwrap(script.range(of: "end verifyUploadOwner"))
        let start = try XCTUnwrap(script.range(of: "tell application \"Safari\"", range: handlerEnd.upperBound..<script.endIndex))
        let end = try XCTUnwrap(script.range(of: "end tell", range: start.upperBound..<script.endIndex))
        let block = String(script[start.lowerBound..<end.upperBound])
        XCTAssertFalse(block.contains("System Events") || block.contains("keystroke") || block.contains("activate"), block)
        return block
    }

    /// Runs that block against `fake` and returns the error it ended with, if any.
    private func runOpeningBlock(ofDialog script: String, on fake: Fake) async throws -> Error? {
        let block = try openingBlock(ofDialog: script)
        do {
            _ = try await fake.drive { try await SafariBridge.runAppleScript(block) }
            return nil
        } catch {
            return error
        }
    }

    private func errorNumber(_ error: Error?) -> Int? {
        guard case SafariBrowserError.appleScriptFailed(let message)? = error else { return nil }
        return SafariBridge.appleScriptErrorCode(in: message)
    }

    /// The dialog script sent before #353 for `window`, written out again here so a change to it shows.
    private func dialogScriptBefore353(window index: Int) -> String {
        """
            tell application "Safari" to set index of window \(index) to 1
            tell application "Safari" to activate
            tell application "System Events"
                tell process "Safari"
                    -- Verify Safari is frontmost before sending any keystrokes
                    if not frontmost then
                        error "Safari lost focus after activate — aborting to avoid sending keystrokes to wrong application"
                    end if

                    -- Wait for file dialog sheet to appear
                    set maxWait to 10
                    set waited to 0
                    repeat until exists sheet 1 of front window
                        delay 0.3
                        set waited to waited + 0.3
                        if waited >= maxWait then
                            error "File dialog did not appear within " & maxWait & " seconds"
                        end if
                    end repeat

            \(SafariBridge.fileDialogNavigationScript(path: uploadPath))
                end tell
            end tell
            """
    }

    // spec-example: file-upload / native upload by window id
    func testNativeUploadByWindowID() async throws {
        // --window 2: the read, the click and the dialog script all name window id 5822.
        let pinned = Fake()
        let byNumber = try await upload(["--window", "2"], fake: pinned)
        XCTAssertEqual(byNumber.plan.window, .id(5822))
        XCTAssertEqual(SafariBridge.resolveDocumentReference(byNumber.plan.jsTarget), "document of window id 5822")
        let afterPin = pinned.scripts(afterFirst: Fake.isAnchor)
        XCTAssertFalse(afterPin.contains(where: Fake.namesAPosition), pinned.transcript)
        XCTAssertTrue(afterPin.contains { $0.contains("get URL of document of window id 5822") }, pinned.transcript)
        XCTAssertTrue(afterPin.contains { $0.contains("do JavaScript") && $0.contains("document of window id 5822") }, pinned.transcript)
        XCTAssertTrue(byNumber.dialogScript.contains("set index of window id 5822 to 1"), byNumber.dialogScript)
        XCTAssertTrue(byNumber.dialogScript.contains("if not (exists window id 5822) then error \"SB_WINDOW_GONE\" number 9002"))
        XCTAssertFalse(Fake.namesAPosition(byNumber.dialogScript), byNumber.dialogScript)
        XCTAssertEqual(pinned.actions, [], "a window target switches no tab")
        XCTAssertFalse(pinned.scripts.contains { $0.contains("set _t to") }, "and no script checks one:\n\(pinned.transcript)")

        // A background tab found by its URL: one script checks it and makes it current; then the read and the
        // click go to that tab of window id 5822, each only while it is still the current tab.
        let background = Fake()
        let byURL = try await upload(["--url", "work.example/a2"], fake: background)
        XCTAssertEqual(background.actions, [.madeCurrent(windowID: 5822, tab: 2)])
        XCTAssertEqual(byURL.plan.jsTarget, .anchoredCurrentTab(windowID: 5822, tabInWindow: 2, profile: nil))
        XCTAssertEqual(SafariBridge.resolveDocumentReference(byURL.plan.jsTarget), "tab 2 of window id 5822")
        let later = background.scripts(afterFirst: Fake.isEnumeration)
        XCTAssertFalse(later.contains(where: Fake.namesAPosition), background.transcript)
        XCTAssertEqual(later.filter { $0.contains("set _t to tab 2 of window id 5822") && $0.contains("SB_TARGET_CHANGED") }.count, 1,
                       "one script checks the tab:\n\(background.transcript)")
        let read = try XCTUnwrap(later.first { $0.contains("get URL of tab 2 of _w") }, background.transcript)
        let click = try XCTUnwrap(later.first { $0.contains("do JavaScript") }, background.transcript)
        for script in [read, click] {
            XCTAssertTrue(script.contains("set _w to window id 5822"), script)
            XCTAssertTrue(script.contains("(index of current tab of _w) is not 2"), "only while tab 2 is current:\n\(script)")
        }
        XCTAssertTrue(byURL.dialogScript.contains("set index of window id 5822 to 1"))

        // The current tab found by its URL: checked by one script, and no tab is made current.
        let current = Fake()
        let byCurrent = try await upload(["--url", "work.example/a1"], fake: current)
        XCTAssertEqual(current.actions, [])
        XCTAssertEqual(current.scripts.filter { $0.contains("set _t to tab 1 of window id 5822") && $0.contains("SB_TARGET_CHANGED") }.count, 1,
                       current.transcript)
        XCTAssertEqual(byCurrent.plan.jsTarget, .anchoredCurrentTab(windowID: 5822, tabInWindow: 1, profile: nil))

        // The dialog script checks the named tab once more before it raises anything: still there, still
        // passing the URL check, still the window's current tab. Then it reads the page's URL and raises.
        assertOrder([
            "if not (exists window id 5822) then error \"SB_WINDOW_GONE\" number 9002",
            "if (count of tabs of window id 5822) < 2 then error \"SB_TAB_GONE\" number 9003",
            "set _t to tab 2 of window id 5822",
            "does not contain \"work.example/a2\"",
            "if (index of current tab of window id 5822) is not 2 then error \"SB_TARGET_CHANGED\" number 9001",
            "set uploadPageURL to URL of current tab of window id 5822",
            "set index of window id 5822 to 1",
        ], in: try openingBlock(ofDialog: byURL.dialogScript))
        XCTAssertFalse(try openingBlock(ofDialog: byURL.dialogScript).contains("set current tab"),
                       "the dialog script never switches a tab")
        let raised = try await runOpeningBlock(ofDialog: byURL.dialogScript, on: background)
        XCTAssertNil(raised, "\(String(describing: raised))")
        XCTAssertEqual(background.actions, [.madeCurrent(windowID: 5822, tab: 2), .raised(windowID: 5822)])
        // …and it raises nothing when that tab changed since the click.
        func dialogOutcome(_ change: (inout [Fake.Window]) -> Void) async throws -> (Int?, [Fake.Action]) {
            var windows = Fake.threeWindows
            windows[1].current = 2
            change(&windows)
            let fake = Fake(windows: windows)
            let error = try await runOpeningBlock(ofDialog: byURL.dialogScript, on: fake)
            return (errorNumber(error), fake.actions)
        }
        let navigated = try await dialogOutcome { $0[1].tabs[1] = "https://other.example/" }
        let notCurrent = try await dialogOutcome { $0[1].current = 1 }
        let tabGone = try await dialogOutcome { $0[1].tabs.removeLast(); $0[1].current = 1 }
        let windowGone = try await dialogOutcome { $0.removeAll { $0.id == 5822 } }
        XCTAssertEqual([navigated.0, notCurrent.0, tabGone.0, windowGone.0], [9001, 9001, 9003, 9002])
        for outcome in [navigated, notCurrent, tabGone, windowGone] {
            XCTAssertEqual(outcome.1, [], "nothing is raised")
        }
        // A window target has no tab to check: the existence check, the URL read, the raise.
        let windowBlock = try openingBlock(ofDialog: byNumber.dialogScript)
        assertOrder(["if not (exists window id 5822)", "set uploadPageURL to URL of current tab of window id 5822",
                     "set index of window id 5822 to 1"], in: windowBlock)
        XCTAssertFalse(windowBlock.contains("set _t to") || windowBlock.contains("SB_TARGET_CHANGED"), windowBlock)

        // Another tab becomes current after the check: the upload stops before the file input is clicked.
        let switchedBack = Fake()
        switchedBack.after(script: 2) { $0[1].current = 1 }
        let command = try UploadCommand.parse(["--native", "input[type=file]", uploadPath, "--url", "work.example/a2"])
        do {
            _ = try await switchedBack.drive { try await command.nativeUploadPlan(expandedPath: self.uploadPath, notice: { _ in }) }
            XCTFail("tab 2 is no longer current")
        } catch SafariBrowserError.targetChangedBeforeActing(_, let stage) {
            XCTAssertEqual(stage, .afterTabSwitch, "the command had made tab 2 current by then")
            XCTAssertFalse(switchedBack.scripts.contains { $0.contains("do JavaScript") }, switchedBack.transcript)
        }

        // The tab navigates after the tab script checked it: the read's answer no longer satisfies --url, and
        // the upload stops there.
        let navigating = Fake()
        navigating.after(script: 2) { $0[1].tabs[1] = "https://other.example/" }
        do {
            _ = try await navigating.drive { try await command.nativeUploadPlan(expandedPath: self.uploadPath, notice: { _ in }) }
            XCTFail("tab 2 no longer shows a URL --url matches")
        } catch SafariBrowserError.targetChangedBeforeActing(let expected, let stage) {
            XCTAssertEqual(stage, .afterTabSwitch)
            XCTAssertTrue(expected.contains("window id 5822 tab 2"), expected)
            XCTAssertEqual(navigating.actions, [.madeCurrent(windowID: 5822, tab: 2)])
            XCTAssertFalse(navigating.scripts.contains { $0.contains("do JavaScript") }, navigating.transcript)
        }

        // Another tab becomes current between the read and the click: the click's own check stops the upload,
        // after the keyboard warning and before any dialog script.
        let beforeClick = Fake()
        beforeClick.after(script: 3) { $0[1].current = 1 }
        let plan = try await beforeClick.drive { try await command.nativeUploadPlan(expandedPath: self.uploadPath, notice: { _ in }) }
        var warned: [String] = []
        var dialogs: [String] = []
        do {
            try await beforeClick.drive {
                try await command.runNativeUpload(
                    plan, ensureLive: {}, runDialogScript: { script, _ in dialogs.append(script) }, warn: { warned.append($0) })
            }
            XCTFail("tab 2 is no longer current when the file input is to be clicked")
        } catch SafariBrowserError.targetChangedBeforeActing(_, let stage) {
            XCTAssertEqual(stage, .afterTabSwitch)
            XCTAssertEqual(dialogs, [], "no dialog script runs")
            XCTAssertEqual(warned, [UploadCommand.keyboardControlWarning])
        }

        // No targeting flag: `window 1`, and the dialog script is the text sent before.
        let plain = try await upload([], fake: Fake())
        XCTAssertEqual(plain.plan.window, .position(1))
        XCTAssertEqual(plain.plan.jsTarget, .windowIndex(1))
        XCTAssertEqual(plain.dialogScript, dialogScriptBefore353(window: 1))

        // --window 2 whose id cannot be read: `window 2` throughout, and the dialog script sent before.
        let unreadFake = Fake()
        unreadFake.anchorDoesNotAnswer = true
        let unread = try await upload(["--window", "2"], fake: unreadFake)
        XCTAssertEqual(unread.plan.window, .position(2))
        XCTAssertEqual(unread.dialogScript, dialogScriptBefore353(window: 2))
    }

    /// What the dialog script reports once it runs is translated by `runNativeUpload`: a check that failed in
    /// its first Safari block came after the click, and a System Events answer is left as it is.
    func testWhatTheDialogScriptReportsIsTranslatedForTheStageItRanAt() async throws {
        let command = try UploadCommand.parse(["--native", "input[type=file]", uploadPath, "--url", "work.example/a2"])
        func outcome(_ message: String) async throws -> Error? {
            let fake = Fake()
            let plan = try await fake.drive { try await command.nativeUploadPlan(expandedPath: self.uploadPath, notice: { _ in }) }
            do {
                try await fake.drive {
                    try await command.runNativeUpload(
                        plan, ensureLive: {},
                        runDialogScript: { _, _ in throw SafariBrowserError.appleScriptFailed(message) },
                        warn: { _ in })
                }
                return nil
            } catch {
                return error
            }
        }
        guard case SafariBrowserError.targetChangedBeforeActing(_, let stage)? =
                try await outcome("88:140: execution error: SB_TARGET_CHANGED (9001)") else {
            return XCTFail("a failed check in the dialog script is targetChangedBeforeActing")
        }
        XCTAssertEqual(stage, .afterFileDialog)
        for gone in ["execution error: SB_WINDOW_GONE (9002)", "execution error: SB_TAB_GONE (9003)"] {
            guard case SafariBrowserError.documentNotFound? = try await outcome(gone) else {
                return XCTFail("\(gone) is documentNotFound")
            }
        }
        // System Events answers -1728 for a sheet or a button that is not there: not a missing window.
        let systemEvents = "execution error: System Events got an error: Can’t get sheet 1 of window 1 of process \"Safari\". (-1728)"
        guard case SafariBrowserError.appleScriptFailed(let passed)? = try await outcome(systemEvents) else {
            return XCTFail("a System Events error passes through")
        }
        XCTAssertEqual(passed, systemEvents)
        // The owner check's own errors (the window closed or lost the front after the dialog appeared) too.
        let owner = "execution error: Upload target window is no longer open; no further keystroke was sent. If a file dialog is still open, dismiss it (Esc) before retrying. (-2700)"
        guard case SafariBrowserError.appleScriptFailed(let ownerPassed)? = try await outcome(owner) else {
            return XCTFail("the owner check's error passes through")
        }
        XCTAssertEqual(ownerPassed, owner)
    }

    // spec-example: file-upload / front window check before every keystroke
    func testFrontWindowCheckBeforeEveryKeystroke() throws {
        let script = UploadCommand.nativeDialogScript(path: uploadPath, window: .id(5822))
        let lines = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let call = "my verifyUploadOwner(5822, uploadPageURL)"

        // The check itself: the window still exists, it is Safari's front window, the front window still
        // shows the page the dialog belongs to (case-sensitively), and Safari is the frontmost application.
        let handlerStart = try XCTUnwrap(lines.firstIndex(of: "on verifyUploadOwner(expectedID, expectedURL)"))
        let handlerEnd = try XCTUnwrap(lines.firstIndex(of: "end verifyUploadOwner"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("on verifyUploadOwner(") }.count, 1)
        let handler = Array(lines[handlerStart...handlerEnd])
        func line(_ prefix: String) throws -> Int {
            try XCTUnwrap(handler.firstIndex { $0.hasPrefix(prefix) }, "the owner check lacks: \(prefix)\n\(handler.joined(separator: "\n"))")
        }
        let exists = try line("if not (exists window id expectedID) then error")
        let front = try line("if id of front window is not expectedID then error")
        let page = try line("if URL of current tab of front window is not expectedURL then error")
        let frontmost = try line("if not frontmost then error")
        XCTAssertTrue(exists < front && front < page && page < frontmost, handler.joined(separator: "\n"))
        XCTAssertEqual(handler[page - 1], "considering case", "the URL is compared with regard to case")
        XCTAssertEqual(handler[page + 1], "end considering")
        XCTAssertTrue(handler[..<frontmost].contains("tell application \"System Events\" to tell process \"Safari\""),
                      "frontmost is asked of the Safari process:\n\(handler.joined(separator: "\n"))")
        for message in [exists, front, page, frontmost] {
            XCTAssertTrue(handler[message].contains("no further keystroke was sent"), handler[message])
            XCTAssertTrue(handler[message].contains("dismiss it (Esc)"), handler[message])
        }
        // The URL it compares with is read in the first Safari block, before the window is raised.
        let read = try XCTUnwrap(lines.firstIndex(of: "set uploadPageURL to URL of current tab of window id 5822"))
        let raise = try XCTUnwrap(lines.firstIndex(of: "set index of window id 5822 to 1"))
        XCTAssertTrue(handlerEnd < read && read < raise)

        XCTAssertEqual(lines.filter { $0 == call }.count, 7, "three keystrokes, two waits, the confirmation, and once after the dialog appeared")

        // Every keystroke, and the confirming click, has a check after the previous one.
        let acts = lines.indices.filter { lines[$0].hasPrefix("keystroke ") || lines[$0] == "click defaultBtn" }
        XCTAssertEqual(acts.count, 4, "three keystrokes and the confirming click:\n\(script)")
        var previous = -1
        for act in acts {
            XCTAssertTrue(lines[(previous + 1)..<act].contains(call), "no front-window check before line \(act): \(lines[act])")
            previous = act
        }
        // The first check comes after the wait for the file dialog and before the first keystroke.
        let dialogWait = try XCTUnwrap(lines.firstIndex(of: "repeat until exists sheet 1 of front window"))
        let dialogWaitEnd = try XCTUnwrap(lines[dialogWait...].firstIndex(of: "end repeat"))
        let firstCall = try XCTUnwrap(lines.firstIndex(of: call))
        XCTAssertTrue(dialogWaitEnd < firstCall && firstCall < acts[0])
        // One check inside each of the two waits (for the Go to Folder panel to open, and to close).
        let waits = ["repeat until exists sheet 1 of sheet 1 of front window",
                     "repeat until not (exists sheet 1 of sheet 1 of front window)"]
        for wait in waits {
            let start = try XCTUnwrap(lines.firstIndex(of: wait), "missing wait: \(wait)")
            let end = try XCTUnwrap(lines[start...].firstIndex(of: "end repeat"))
            XCTAssertEqual(lines[start...end].filter { $0 == call }.count, 1, "one check inside: \(wait)")
        }
        // The wait for the file dialog itself has none: the dialog is not there yet.
        XCTAssertFalse(lines[dialogWait...dialogWaitEnd].contains(call))

        // No targeting flag, and a window named by position: no such call, and the text sent before.
        let positional = UploadCommand.nativeDialogScript(path: uploadPath, window: .position(1))
        XCTAssertFalse(positional.contains("verifyUploadOwner"))
        XCTAssertEqual(positional, dialogScriptBefore353(window: 1))
        XCTAssertFalse(UploadCommand.nativeDialogScript(path: uploadPath, window: nil).contains("verifyUploadOwner"))
    }

    func testTheNavigationFragmentIsUnchangedWithoutAnOwnerCheck() {
        // pdf passes its own two lines whatever `ownerGuard` says; upload without a window id passes none.
        XCTAssertEqual(SafariBridge.fileDialogNavigationScript(path: uploadPath, ownerGuard: ""),
                       SafariBridge.fileDialogNavigationScript(path: uploadPath))
        XCTAssertEqual(SafariBridge.fileDialogNavigationScript(path: uploadPath, pdfSave: true, ownerGuard: "my verifyUploadOwner(1)"),
                       SafariBridge.fileDialogNavigationScript(path: uploadPath, pdfSave: true))
        XCTAssertFalse(SafariBridge.fileDialogNavigationScript(path: uploadPath).contains("verify"))
    }

    // spec-example: document-targeting / tab switch scripts
    func testTabSwitchScripts() async throws {
        /// The scripts that bind a tab and can make it current.
        func switches(_ fake: Fake) -> [String] { fake.scripts.filter { $0.contains("set current tab") } }
        func madeCurrent(_ fake: Fake) -> [Fake.Action] {
            fake.actions.filter { if case .madeCurrent = $0 { return true }; return false }
        }

        // A background tab found by its URL: one script, the check first, then the tab is made current.
        let background = Fake()
        _ = try await upload(["--url", "work.example/a2"], fake: background)
        XCTAssertEqual(switches(background).count, 1, background.transcript)
        assertOrder(["set _t to tab 2 of window id 5822", "SB_TARGET_CHANGED", "set current tab of window id 5822 to _t"],
                    in: switches(background).first ?? "")
        XCTAssertEqual(madeCurrent(background), [.madeCurrent(windowID: 5822, tab: 2)])

        // The current tab found by its URL: the same one script checks it, and no tab is made current.
        let current = Fake()
        _ = try await upload(["--url", "work.example/a1"], fake: current)
        XCTAssertEqual(switches(current).count, 1, current.transcript)
        assertOrder(["set _t to tab 1 of window id 5822", "SB_TARGET_CHANGED"], in: switches(current).first ?? "")
        XCTAssertEqual(madeCurrent(current), [])

        // A tab named by its position: one script, no URL check, the tab is made current.
        let byPosition = Fake()
        _ = try await upload(["--window-id", "5822", "--tab-in-window", "2"], fake: byPosition)
        XCTAssertEqual(switches(byPosition).count, 1, byPosition.transcript)
        XCTAssertFalse(switches(byPosition).first?.contains("SB_TARGET_CHANGED") == true, "a position is not checked by URL")
        XCTAssertEqual(madeCurrent(byPosition), [.madeCurrent(windowID: 5822, tab: 2)])

        // A window with no tab named: no such script.
        let windowOnly = Fake()
        _ = try await upload(["--window", "2"], fake: windowOnly)
        XCTAssertEqual(switches(windowOnly), [])

        // The tab is switched away again after the check: the upload stops before the click.
        let switchedBack = Fake()
        switchedBack.after(script: 2) { $0[1].current = 1 }
        do {
            _ = try await upload(["--url", "work.example/a2"], fake: switchedBack)
            XCTFail("tab 2 is no longer current")
        } catch SafariBrowserError.targetChangedBeforeActing {
            XCTAssertFalse(switchedBack.scripts.contains { $0.contains("do JavaScript") }, switchedBack.transcript)
        }

        // pdf: no AppleScript of its own; the check and the switch are inside the export script, before the raise.
        let pdfFake = Fake()
        let plan = try await exportPlan(["--url", "work.example/a2"], fake: pdfFake)
        XCTAssertEqual(switches(pdfFake), [])
        assertOrder(["SB_TARGET_CHANGED", "set current tab of window id 5822 to _t", "set index of window id 5822 to 1"], in: plan.script)
        let pdfActions = try await runOpeningBlock(of: plan, on: pdfFake)
        XCTAssertEqual(pdfActions, [.madeCurrent(windowID: 5822, tab: 2), .raised(windowID: 5822), .activated])
        let pdfCurrentFake = Fake()
        let currentPlan = try await exportPlan(["--url", "work.example/a1"], fake: pdfCurrentFake)
        assertOrder(["set _t to tab 1 of window id 5822", "SB_TARGET_CHANGED", "set index of window id 5822 to 1"], in: currentPlan.script)
        let pdfCurrentActions = try await runOpeningBlock(of: currentPlan, on: pdfCurrentFake)
        XCTAssertEqual(pdfCurrentActions, [.raised(windowID: 5822), .activated])

        // close: never.
        let closeFake = Fake()
        let error = await closeFake.run(CloseCommand.self, ["--url", "work.example/a2"])
        XCTAssertNil(error)
        XCTAssertEqual(switches(closeFake), [])
        XCTAssertFalse(closeFake.actions.contains(.madeCurrent(windowID: 5822, tab: 2)))
    }

    /// A tab that moved between the resolution and the switch: the upload stops before the tab is switched,
    /// before the file dialog opens, and before any warning about the keyboard.
    func testATabThatMovedStopsANativeUploadBeforeAnythingIsTouched() async throws {
        let fake = Fake()
        fake.after(script: 1) { $0[1].tabs[1] = "https://other.example/" }
        let command = try UploadCommand.parse(["--native", "input[type=file]", uploadPath, "--url", "work.example/a2"])
        do {
            _ = try await fake.drive { try await command.nativeUploadPlan(expandedPath: self.uploadPath, notice: { _ in }) }
            XCTFail("expected targetChangedBeforeActing")
        } catch SafariBrowserError.targetChangedBeforeActing {
            XCTAssertEqual(fake.actions, [])
            XCTAssertFalse(fake.scripts.contains { $0.contains("do JavaScript") }, fake.transcript)
        }
    }

    // spec-example: non-interference / tab switch notice and script
    func testTabSwitchNoticeAndScript() async throws {
        let background = Fake()
        let switching = try await upload(["--url", "work.example/a2"], fake: background)
        XCTAssertEqual(switching.notices, ["ℹ️  Target tab will be brought to the front of its window before upload.\n"])
        XCTAssertEqual(switching.warnings, [UploadCommand.keyboardControlWarning], "the keyboard warning follows, once")
        guard case .warnOnStderr? = switching.plan.effects.first else { return XCTFail("the plan starts with the keyboard warning") }
        XCTAssertEqual(background.actions, [.madeCurrent(windowID: 5822, tab: 2)])

        let current = Fake()
        let still = try await upload(["--url", "work.example/a1"], fake: current)
        XCTAssertEqual(still.notices, [])
        XCTAssertEqual(current.actions, [])

        // pdf: the notice precedes the keyboard warning, and is absent when nothing is switched.
        let plan = try await exportPlan(["--url", "work.example/a2"], fake: Fake())
        XCTAssertTrue(plan.switchesTab)
        let notices = PdfCommand.exportNotices(switchesTab: true)
        XCTAssertEqual(notices.count, 2)
        XCTAssertTrue(notices[0].contains("Target tab will be brought to the front of its window"), notices[0])
        XCTAssertTrue(notices[1].contains("Controlling keyboard"), notices[1])
        XCTAssertEqual(PdfCommand.exportNotices(switchesTab: false).count, 1)
        let untouched = try await exportPlan(["--url", "work.example/a1"], fake: Fake())
        XCTAssertFalse(untouched.switchesTab)
    }
}
