import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #353: the five window-level paths together. After the resolution, every AppleScript they send, and every
/// script they hand to `osascript`, names the target window by its id; and `--window N` on `close`, `pdf`,
/// `screenshot` and the native `upload` paths is read once, at command start (#354).
final class WindowLevelCommandsTests: XCTestCase {

    private typealias Fake = WindowLevelFakeSafari

    private let uploadPath = "/tmp/window-level-fixture.txt"

    /// Everything a command sent to Safari after its resolution, plus the script it built for `osascript`.
    private struct Trace {
        let later: [String]
        let fake: Fake
    }

    private func closeTrace(_ flags: [String], resolvedBy isResolution: (String) -> Bool) async -> Trace {
        let fake = Fake()
        let error = await fake.run(CloseCommand.self, flags)
        XCTAssertNil(error, "close \(flags): \(String(describing: error))\n\(fake.transcript)")
        return Trace(later: fake.scripts(afterFirst: isResolution), fake: fake)
    }

    private func pdfTrace(_ flags: [String]) async throws -> Trace {
        let fake = Fake()
        let command = try PdfCommand.parse(["--allow-hid"] + flags + ["/tmp/out.pdf"])
        let plan = try await fake.drive { try await command.plannedExport(stagingPath: "/tmp/staging/out.pdf", remaining: { 30 }) }
        return Trace(later: fake.scripts(afterFirst: Fake.isAnchor) + [plan.script], fake: fake)
    }

    private func uploadTrace(_ flags: [String]) async throws -> Trace {
        let fake = Fake()
        let command = try UploadCommand.parse(["--native", "input[type=file]", uploadPath] + flags)
        let plan = try await fake.drive { try await command.nativeUploadPlan(expandedPath: self.uploadPath, notice: { _ in }) }
        var dialog: [String] = []
        try await fake.drive {
            try await command.runNativeUpload(
                plan, ensureLive: {}, runDialogScript: { script, _ in dialog.append(script) }, warn: { _ in })
        }
        return Trace(later: fake.scripts(afterFirst: Fake.isAnchor) + dialog, fake: fake)
    }

    private func screenshotTrace(_ flags: [String]) async throws -> Trace {
        let fake = Fake()
        let command = try ScreenshotCommand.parse(flags + ["/tmp/out.png"])
        // `captureWindow` is what `run()` starts with. Its `resolve` stands in for the Accessibility match, and
        // makes the AppleScript read that match starts from, for the window it was handed.
        let result = try await fake.drive {
            try await command.captureWindow(
                session: GUISession(readDictionary: { ["CGSSessionScreenIsLocked": false] }),
                resolve: { window in
                    guard let window else { throw ValidationError("no explicit target") }
                    _ = try await SafariBridge.readCaptureGeometry(window: window, missTarget: .frontWindow, profile: nil)
                    return (cgID: "77", axWindow: nil)
                })
        }
        guard let capture = result.capture else { throw ValidationError("no explicit target") }
        // …then one page step of --full, in the document the resolution fixed.
        let page = try await fake.drive { try await ScreenshotCommand.pageTarget(capture: capture, options: result.target) }
        _ = try await fake.drive {
            try await ScreenshotCommand.pageStep(page) { try await SafariBridge.doJavaScript("window.scrollTo(0,0)", target: page) }
        }
        return Trace(later: fake.scripts(afterFirst: Fake.isAnchor), fake: fake)
    }

    /// Safari's `front window` may be named only inside a check that stops the script unless
    /// `id of front window` is the resolved id. Inside a System Events block `front window` is the process's
    /// front window (the sheet the keystrokes go to), which those checks guard.
    private func assertFrontWindowOnlyInOwnerChecks(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
        var inHandler = false
        var inSystemEvents = false
        var comparedInHandler = false
        for raw in script.components(separatedBy: "\n") {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("on verify") { inHandler = true; comparedInHandler = false; continue }
            if text.hasPrefix("end verify") { inHandler = false; continue }
            if text.hasPrefix("tell application \"System Events\"") && !inHandler { inSystemEvents = true }
            guard text.contains("front window") else { continue }
            if inHandler {
                if text.contains("if id of front window is not expectedID then error") { comparedInHandler = true }
                XCTAssertTrue(comparedInHandler, "the front window is used before its id is compared: \(text)", file: file, line: line)
            } else {
                XCTAssertTrue(inSystemEvents, "Safari's front window is named outside an owner check: \(text)", file: file, line: line)
            }
        }
    }

    private func assertNamesOnly(_ reference: String, in trace: Trace, _ what: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(trace.later.isEmpty, "\(what): nothing was sent after the resolution", file: file, line: line)
        for script in trace.later {
            XCTAssertFalse(Fake.namesAPosition(script), "\(what): a later script names a position:\n\(script)", file: file, line: line)
            assertFrontWindowOnlyInOwnerChecks(script, file: file, line: line)
        }
        XCTAssertTrue(trace.later.contains { $0.contains(reference) }, "\(what): \(reference) is never named:\n\(trace.fake.transcript)",
                      file: file, line: line)
    }

    // spec-example: document-targeting / references after the resolution
    func testReferencesAfterTheResolution() async throws {
        let closeByNumber = await closeTrace(["--window", "2"], resolvedBy: Fake.isAnchor)
        assertNamesOnly("window id 5822", in: closeByNumber, "close --window 2")
        let closeByURL = await closeTrace(["--url", "work.example/a2"], resolvedBy: Fake.isEnumeration)
        assertNamesOnly("tab 2 of window id 5822", in: closeByURL, "close --url")
        let closeByID = await closeTrace(["--window-id", "5822", "--tab-in-window", "2"], resolvedBy: Fake.isEnumeration)
        assertNamesOnly("tab 2 of window id 5822", in: closeByID, "close --window-id --tab-in-window")
        let pdf = try await pdfTrace(["--window", "2"])
        assertNamesOnly("window id 5822", in: pdf, "pdf --window 2")
        let upload = try await uploadTrace(["--window", "2"])
        assertNamesOnly("window id 5822", in: upload, "upload --native --window 2")
        let screenshot = try await screenshotTrace(["--window", "2"])
        assertNamesOnly("window id 5822", in: screenshot, "screenshot --window 2")

        // open: the tab is found by the enumeration, and revealed in window id 6933.
        let fake = Fake()
        let found = try await fake.drive {
            try await OpenCommand.revealExisting(
                url: "https://work.example/b1", warn: { _ in },
                spaces: SafariBridge.SpaceProbe(current: { 1 }, ofWindow: { _ in 1 }))
        }
        XCTAssertTrue(found)
        assertNamesOnly("window id 6933", in: Trace(later: fake.scripts(afterFirst: Fake.isEnumeration), fake: fake), "open")
    }

    // spec-example: document-targeting / window-level commands and the window number
    func testWindowLevelCommandsAndTheWindowNumber() async throws {
        // Another window is raised to the front after the id was read: the close still lands in window id 5822.
        let raised = Fake()
        raised.after(script: 1) { windows in windows.insert(windows.removeLast(), at: 0) }
        let raisedError = await raised.run(CloseCommand.self, ["--window", "2"])
        XCTAssertNil(raisedError, raised.transcript)
        XCTAssertTrue(raised.scripts.first.map(Fake.isAnchor) == true, "the id is read first:\n\(raised.transcript)")
        XCTAssertEqual(raised.windows.map(\.id), [6933, 4711, 5822], "window id 5822 is window 3 by then")
        XCTAssertTrue(raised.scripts.last?.contains("close current tab of window id 5822") == true, raised.transcript)
        XCTAssertFalse(raised.scripts(afterFirst: Fake.isAnchor).contains(where: Fake.namesAPosition), raised.transcript)
        XCTAssertEqual(raised.closed, [.closed(windowID: 5822, tab: 1, url: "https://work.example/a1")])

        // The window closes after the id was read: the miss names `--window 2`, and nothing closes.
        let closing = Fake()
        closing.after(script: 1) { $0.removeAll { $0.id == 5822 } }
        let miss = await closing.run(CloseCommand.self, ["--window", "2"])
        guard case SafariBrowserError.documentNotFound(let pattern, _)? = miss else {
            return XCTFail("expected documentNotFound, got \(String(describing: miss))\n\(closing.transcript)")
        }
        XCTAssertEqual(pattern, "window 2 (window id 5822 at command start)")
        XCTAssertEqual(closing.closed, [])

        // --window 2 --tab-in-window 2: the tab of the window that was window 2.
        let tab = Fake()
        let tabError = await tab.run(CloseCommand.self, ["--window", "2", "--tab-in-window", "2"])
        XCTAssertNil(tabError, tab.transcript)
        XCTAssertTrue(tab.scripts.last?.contains("set _t to tab 2 of window id 5822") == true, tab.transcript)
        XCTAssertEqual(tab.closed, [.closed(windowID: 5822, tab: 2, url: "https://work.example/a2")])

        // pdf, upload and screenshot: nothing after the id read names `window 2`.
        let pdf = try await pdfTrace(["--window", "2"])
        let upload = try await uploadTrace(["--window", "2"])
        let screenshot = try await screenshotTrace(["--window", "2"])
        for trace in [pdf, upload, screenshot] {
            XCTAssertTrue(trace.fake.scripts.first.map(Fake.isAnchor) == true, "the id is read first:\n\(trace.fake.transcript)")
            XCTAssertFalse(trace.later.contains(where: Fake.namesAPosition), trace.later.joined(separator: "\n---\n"))
            XCTAssertTrue(trace.later.contains { $0.contains("window id 5822") })
        }
        // pdf: the export script itself names the window by its id.
        let exportScript = try XCTUnwrap(pdf.later.last)
        XCTAssertTrue(exportScript.contains("set index of window id 5822 to 1"), exportScript)
        XCTAssertTrue(exportScript.contains("set pdfWindowID to 5822"), exportScript)
        // upload: the read that checks the target, the click, and the dialog script, each by the id.
        XCTAssertTrue(upload.later.contains { $0.contains("get URL of document of window id 5822") }, upload.fake.transcript)
        XCTAssertTrue(upload.later.contains { $0.contains("do JavaScript") && $0.contains("document of window id 5822") },
                      upload.fake.transcript)
        let dialogScript = try XCTUnwrap(upload.later.last)
        XCTAssertTrue(dialogScript.contains("set index of window id 5822 to 1"), dialogScript)
        XCTAssertTrue(dialogScript.contains("my verifyUploadOwner(5822, uploadPageURL)"), dialogScript)
        // screenshot: the bounds and the title are read from the id, and so is the page.
        XCTAssertTrue(screenshot.later.contains {
            $0.contains("set b to bounds of window id 5822") && $0.contains("set n to name of window id 5822")
        }, screenshot.fake.transcript)
        XCTAssertTrue(screenshot.later.contains { $0.contains("do JavaScript") && $0.contains("document of window id 5822") },
                      screenshot.fake.transcript)

        // The id of window 2 cannot be read: one note, and the close names `window 2`.
        let unread = Fake()
        unread.anchorDoesNotAnswer = true
        let unreadError = await unread.run(CloseCommand.self, ["--window", "2"])
        XCTAssertNil(unreadError, unread.transcript)
        XCTAssertEqual(unread.diagnostics.count, 1, "\(unread.diagnostics)")
        XCTAssertTrue(unread.scripts.last?.contains("close current tab of window 2") == true, unread.transcript)

        // --window 1 --profile Work: the enumeration at command start is the only one in the whole command.
        let scoped = Fake()
        let scopedError = await scoped.run(CloseCommand.self, ["--window", "1", "--profile", "Work"])
        XCTAssertNil(scopedError, scoped.transcript)
        XCTAssertEqual(scoped.scripts.filter(Fake.isEnumeration).count, 1, scoped.transcript)
        XCTAssertTrue(scoped.scripts.last?.contains("close current tab of window id 5822") == true, scoped.transcript)
        XCTAssertEqual(scoped.closed, [.closed(windowID: 5822, tab: 1, url: "https://work.example/a1")])
    }

    // spec-example: window-enumeration / a tab opened during the enumeration, by command
    func testATabOpenedDuringTheEnumerationByCommand() async throws {
        // Window id 5822 is listed with two tabs and current-tab index 3: no tab is marked current, so a command
        // that needs tab 1 in front must switch to it, and one that does not must not assume anything.
        func fixture() -> Fake {
            var windows = Fake.threeWindows
            windows[1].current = 3
            return Fake(windows: windows)
        }
        let flags = ["--window-id", "5822", "--tab-in-window", "1"]

        let pdfFake = fixture()
        let pdfCommand = try PdfCommand.parse(["--allow-hid"] + flags + ["/tmp/out.pdf"])
        let plan = try await pdfFake.drive { try await pdfCommand.plannedExport(stagingPath: "/tmp/staging/out.pdf", remaining: { 30 }) }
        XCTAssertTrue(plan.switchesTab)
        let switchInScript = try XCTUnwrap(plan.script.range(of: "set current tab of window id 5822 to _t"))
        let raise = try XCTUnwrap(plan.script.range(of: "set index of window id 5822 to 1"))
        XCTAssertTrue(plan.script.contains("set _t to tab 1 of window id 5822"), plan.script)
        XCTAssertTrue(switchInScript.lowerBound < raise.lowerBound)

        let uploadFake = fixture()
        let uploadCommand = try UploadCommand.parse(["--native", "input[type=file]", uploadPath] + flags)
        _ = try await uploadFake.drive { try await uploadCommand.nativeUploadPlan(expandedPath: self.uploadPath, notice: { _ in }) }
        XCTAssertEqual(uploadFake.actions, [.madeCurrent(windowID: 5822, tab: 1)])
        XCTAssertEqual(uploadFake.scripts.filter { $0.contains("set current tab of window id 5822 to _t") }.count, 1, uploadFake.transcript)

        let closeFake = fixture()
        let closeError = await closeFake.run(CloseCommand.self, flags)
        XCTAssertNil(closeError, closeFake.transcript)
        XCTAssertEqual(closeFake.actions, [.closed(windowID: 5822, tab: 1, url: "https://work.example/a1")])
        XCTAssertFalse(closeFake.scripts.contains { $0.contains("set current tab") }, closeFake.transcript)

        let shotFake = fixture()
        let shotCommand = try ScreenshotCommand.parse(flags + ["/tmp/out.png"])
        do {
            _ = try await shotFake.drive { try await shotCommand.resolveCapture() }
            XCTFail("a tab that is not known to be current cannot be captured")
        } catch SafariBrowserError.backgroundTabNotCapturable {
            XCTAssertFalse(shotFake.scripts.contains { $0.contains("bounds of") }, shotFake.transcript)
        }
    }

    /// A pinned window under `--profile` that closes right after the pin: the miss lists that profile's
    /// remaining tabs with their window ids (#362), not a bare note, and names the window number typed.
    func testAPinnedWindowUnderAProfileThatClosesListsTheProfilesTabs() async throws {
        func closing() -> Fake {
            let fake = Fake()
            fake.after(script: 1) { $0.removeAll { $0.id == 5822 } }
            return fake
        }
        let flags = ["--window", "1", "--profile", "Work"]
        var misses: [(String, Error?)] = []

        let closeFake = closing()
        misses.append(("close", await closeFake.run(CloseCommand.self, flags)))
        XCTAssertEqual(closeFake.closed, [])

        let pdfCommand = try PdfCommand.parse(["--allow-hid"] + flags + ["/tmp/out.pdf"])
        do {
            _ = try await closing().drive { try await pdfCommand.plannedExport(stagingPath: "/tmp/staging/out.pdf", remaining: { 30 }) }
            misses.append(("pdf", nil))
        } catch { misses.append(("pdf", error)) }

        let uploadCommand = try UploadCommand.parse(["--native", "input[type=file]", uploadPath] + flags)
        do {
            _ = try await closing().drive { try await uploadCommand.nativeUploadPlan(expandedPath: self.uploadPath, notice: { _ in }) }
            misses.append(("upload", nil))
        } catch { misses.append(("upload", error)) }

        let shotCommand = try ScreenshotCommand.parse(flags + ["/tmp/out.png"])
        do {
            _ = try await closing().drive { try await shotCommand.resolveCapture() }
            misses.append(("screenshot", nil))
        } catch { misses.append(("screenshot", error)) }

        for (command, error) in misses {
            guard case SafariBrowserError.documentNotFound(let pattern, let entries)? = error else {
                XCTFail("\(command): expected documentNotFound, got \(String(describing: error))")
                continue
            }
            XCTAssertEqual(pattern, "window 1 (window id 5822 at command start)", command)
            XCTAssertEqual(entries.count, 1, "\(command): \(entries)")
            XCTAssertTrue(entries.first?.hasSuffix("(window id 6933): https://work.example/b1") == true, "\(command): \(entries)")
            XCTAssertFalse(entries.contains { $0.contains("home.example") }, "\(command): \(entries)")
        }
    }

    /// The same pin on the other three commands under `--profile`: one enumeration each.
    func testAPinnedWindowUnderAProfileIsEnumeratedOnce() async throws {
        let traces = [try await pdfTrace(["--window", "1", "--profile", "Work"]),
                      try await uploadTrace(["--window", "1", "--profile", "Work"]),
                      try await screenshotTrace(["--window", "1", "--profile", "Work"])]
        for trace in traces {
            XCTAssertEqual(trace.fake.scripts.filter(Fake.isEnumeration).count, 1, trace.fake.transcript)
        }
    }
}
