import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #354 verify round 1: the guards the first round left untested, and the fixes it asked for.
final class WindowPinRound1Tests: XCTestCase {

    private func pin(_ args: [String], on fake: PinFakeSafari) async throws -> TargetOptions {
        let options = try TargetOptions.parse(args)
        return try await fake.drive { try await options.pinWindowAtStart() }
    }

    private func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    // MARK: cancellation and failures in the pin (F10, F18)

    func testACancelledPinThrowsInsteadOfFallingBack() async throws {
        let fake = PinFakeSafari()
        let options = try TargetOptions.parse(["--window", "2"])
        let task = Task { try await fake.drive { try await options.pinWindowAtStart() } }
        task.cancel()
        do {
            let pinned = try await task.value
            XCTFail("a cancelled pin must throw, got window \(String(describing: pinned.window)) id \(String(describing: pinned.windowID))")
        } catch is CancellationError {}
    }

    /// Under `--profile` only a not-found answer falls back; a cancellation raised by the enumeration is thrown.
    func testWithAProfileACancelledEnumerationIsThrown() async throws {
        let fake = PinFakeSafari()
        fake.enumerationError = CancellationError()
        do {
            _ = try await pin(["--window", "1", "--profile", "Work"], on: fake)
            XCTFail("the cancellation must reach the caller")
        } catch is CancellationError {}
    }

    /// A stuck Safari under `--profile`: the pin's enumeration timing out is the command's error, after one
    /// enumeration — not a fallback that makes the first step wait for a second timeout.
    func testWithAProfileAnEnumerationTimeoutIsThrownAfterOneAttempt() async throws {
        let fake = PinFakeSafari()
        fake.enumerationError = SafariBrowserError.processTimedOut(command: "osascript", seconds: 30)
        let error = await fake.run(GetURL.self, ["--window", "1", "--profile", "Work"])
        guard case SafariBrowserError.processTimedOut? = error else {
            return XCTFail("expected the timeout, got \(String(describing: error))")
        }
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isEnumeration).count, 1, fake.transcript)
    }

    /// `--window N --tab-in-window M --profile P` with no tab M in the profile's N-th window: the pin asks for that
    /// tab (not just the window), finds none, and leaves the position for the first step to report.
    func testWithAProfileATabOutsideTheWindowKeepsThePosition() async throws {
        let fake = PinFakeSafari()
        let pinned = try await pin(["--window", "1", "--tab-in-window", "9", "--profile", "Work"], on: fake)
        XCTAssertEqual(pinned.window, 1)
        XCTAssertNil(pinned.windowID)
        XCTAssertEqual(pinned.tabInWindow, 9)
    }

    // MARK: the fallback note (F20)

    func testAPositionalFallbackSaysSo() async throws {
        let fake = PinFakeSafari()
        _ = try await pin(["--window", "9"], on: fake)
        XCTAssertEqual(fake.diagnostics, [TargetOptions.pinFallbackNote(window: 9)])
        XCTAssertTrue(TargetOptions.pinFallbackNote(window: 9).contains("--window 9 is looked up by its position"))

        let pinnedFake = PinFakeSafari()
        _ = try await pin(["--window", "2"], on: pinnedFake)
        XCTAssertEqual(pinnedFake.diagnostics, [], "nothing to say when the id was read")
    }

    /// In the daemon, an exec-level `--window N` that arrived unpinned (the client's pin could not read the id) is
    /// pinned on the first step that needs it; the next step reuses that id without another read.
    func testAnInProcessRunPinsAnUnpinnedExecLevelWindowOnFirstNeed() async throws {
        let fake = PinFakeSafari()
        fake.raiseAfterScripts = 1
        let dispatcher = InProcessStepDispatcher()
        for _ in 0..<2 {
            _ = try await fake.drive {
                try await dispatcher.dispatch(cmd: "get url", args: [], sharedTargetArgs: ["--window", "2"])
            }
        }
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isIndexAnchor).count, 1, fake.transcript)
        let reads = fake.scripts.filter { $0.contains("URL of") }
        XCTAssertEqual(reads.count, 2, fake.transcript)
        XCTAssertTrue(reads.allSatisfy { $0.contains("window id 5822") }, fake.transcript)
    }

    // MARK: wording (F4, F9, F13)

    func testAPinnedTabOutsideItsWindowNamesTheWindowNumberAndTheTab() throws {
        let windows = [SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1, tabs: [
            SafariBridge.TabInWindow(tabIndex: 1, url: "https://home.example/1", title: "a", isCurrent: true),
        ], windowID: 4711)]
        XCTAssertThrowsError(try SafariBridge.pickNativeTarget(.windowID(4711, tabInWindow: 9, pinnedFrom: 1), in: windows)) {
            guard case SafariBrowserError.documentNotFound(let pattern, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(pattern, "window 1 tab 9 (window id 4711 at command start)")
        }
    }

    /// A pinned window that closed without `--profile`: one note, worded for a window (no tab was named), and the
    /// hint says what happened instead of pointing at coordinates nothing listed.
    func testAPinnedWindowMissWithoutAProfileSaysTheWindowClosed() async throws {
        let fake = PinFakeSafari()
        fake.closeAfterScripts = (1, 5822)
        let error = await fake.run(GetURL.self, ["--window", "2"])
        guard let error = error as? SafariBrowserError, case .documentNotFound(_, let available) = error else {
            return XCTFail("expected a targeting miss, got \(String(describing: error))")
        }
        XCTAssertEqual(available.count, 1)
        XCTAssertFalse(available[0].contains("no such tab"), available[0])
        let message = flat(error.localizedDescription)
        XCTAssertTrue(message.contains("the window that --window N named when the command started is no longer open"), message)
        XCTAssertFalse(message.contains("target one with --window N --tab-in-window M"), message)
    }

    /// A pinned tab that disappeared while its window stayed open: that window's tabs are listed, by id.
    func testAPinnedTabThatIsGoneListsItsWindowsTabs() async throws {
        let fake = PinFakeSafari()
        fake.dropLastTabAfterScripts = (1, 4711)
        let error = await fake.run(GetURL.self, ["--window", "1", "--tab-in-window", "3"])
        guard let error = error as? SafariBrowserError, case .documentNotFound(let pattern, let available) = error else {
            return XCTFail("expected a targeting miss, got \(String(describing: error))\n\(fake.transcript)")
        }
        XCTAssertEqual(pattern, "window 1 tab 3 (window id 4711 at command start)")
        XCTAssertEqual(available, ["window 1 tab 1 (window id 4711): https://home.example/1",
                                   "window 1 tab 2 (window id 4711): https://home.example/2"])
        XCTAssertTrue(flat(error.localizedDescription).contains("--window-id W"), error.localizedDescription)
    }

    /// An `exec --window N` step that runs as its own `js` or `wait` process names the N, as an in-process step does.
    func testJSAndWaitStepsKeepTheWindowNumberTheyWerePinnedFrom() async {
        for (args, expected) in [
            (["1", "--window-id", "5999", "--pinned-from-window", "2"], "window 2 (window id 5999 at command start)"),
            (["1", "--window-id", "5999", "--tab-in-window", "1", "--pinned-from-window", "2"],
             "window 2 tab 1 (window id 5999 at command start)"),
        ] {
            let fake = PinFakeSafari()
            let error = await fake.run(JSCommand.self, args)
            guard case SafariBrowserError.documentNotFound(let pattern, _)? = error else {
                XCTFail("\(args): \(String(describing: error))"); continue
            }
            XCTAssertEqual(pattern, expected, "\(args)")
        }
        let fake = PinFakeSafari()
        let error = await fake.run(WaitCommand.self, ["--js", "1", "--timeout", "0", "--window-id", "5999", "--pinned-from-window", "2"])
        guard case SafariBrowserError.documentNotFound(let pattern, _)? = error else {
            return XCTFail("wait: \(String(describing: error))")
        }
        XCTAssertEqual(pattern, "window 2 (window id 5999 at command start)")
    }

    // MARK: pinned paths the shape check cannot see (F10)

    func testOpenReplaceTabPinsTheWindow() async {
        let fake = PinFakeSafari()
        fake.raiseAfterScripts = 1
        let error = await fake.run(OpenCommand.self, ["https://example.com/b", "--replace-tab", "--window", "2"])
        XCTAssertNil(error, fake.transcript)
        XCTAssertTrue(fake.scripts.first.map(PinFakeSafari.isIndexAnchor) == true, fake.transcript)
        XCTAssertTrue(fake.scripts.contains { $0.contains("window.location.href") && $0.contains("window id 5822") }, fake.transcript)
    }

    func testUploadWithoutAccessibilityPinsTheWindow() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fake = PinFakeSafari()
        fake.raiseAfterScripts = 1
        var command = try UploadCommand.parse(["input[type=file]", file.path, "--window", "2"])
        do {
            try await fake.drive { try await command.run(accessibilityProbe: { false }) }
        } catch {
            XCTFail("\(error)\n\(fake.transcript)")
        }
        XCTAssertTrue(fake.scripts.first.map(PinFakeSafari.isIndexAnchor) == true, fake.transcript)
        let after = fake.scripts.dropFirst()
        XCTAssertFalse(after.isEmpty)
        XCTAssertTrue(after.allSatisfy { $0.contains("window id 5822") }, fake.transcript)
    }

    // MARK: cost (F5, F21)

    /// Commands that resolve the profile once spend no enumeration beyond the pin's.
    func testAResolveOnceCommandUnderAProfileEnumeratesOnce() async {
        let fake = PinFakeSafari()
        let error = await fake.run(OpenCommand.self, ["https://example.com/b", "--window", "1", "--profile", "Work"])
        XCTAssertNil(error, fake.transcript)
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isEnumeration).count, 1, fake.transcript)
        XCTAssertTrue(fake.scripts.contains { $0.contains("window.location.href") && $0.contains("window id 5822") }, fake.transcript)
    }

    /// `save-image --window N` checks the pinned window with one small query, not an enumeration of every tab.
    func testSaveImageChecksThePinnedWindowWithoutEnumerating() async {
        let fake = PinFakeSafari()
        _ = await fake.run(SaveImageCommand.self, [FileManager.default.temporaryDirectory.appendingPathComponent("pin-x.png").path,
                                                   "--element", "img", "--window", "2"])
        XCTAssertFalse(fake.scripts.contains(where: PinFakeSafari.isEnumeration), fake.transcript)
        XCTAssertTrue(fake.scripts.contains { $0.contains("get index of window id 5822") }, fake.transcript)
    }

    // MARK: input is checked before Safari is contacted (F12)

    func testBadArgumentsNeverReachSafari() async throws {
        for (label, run) in [
            ("scroll", { (fake: PinFakeSafari) in await fake.run(ScrollCommand.self, ["sideways", "--window", "2"]) }),
            ("set media", { (fake: PinFakeSafari) in await fake.run(SetMedia.self, ["blue", "--window", "2"]) }),
            ("press", { (fake: PinFakeSafari) in await fake.run(PressCommand.self, ["+", "--window", "2"]) }),
            ("find", { (fake: PinFakeSafari) in await fake.run(FindCommand.self, ["nonsense", "x", "click", "--window", "2"]) }),
        ] as [(String, (PinFakeSafari) async -> Error?)] {
            let fake = PinFakeSafari()
            let error = await run(fake)
            XCTAssertNotNil(error, label)
            XCTAssertEqual(fake.scripts, [], "\(label): \(fake.transcript)")
        }
    }

    func testExecChecksTheScriptBeforeThePin() async throws {
        for (label, source, maxSteps) in [
            ("not JSON", "not json", "10"),
            ("over the step limit", ##"[{"cmd":"get url"},{"cmd":"get url"}]"##, "1"),
        ] {
            let fake = PinFakeSafari()
            do {
                try await fake.drive {
                    try await ExecCommand.parse(["--window", "2", "--max-steps", maxSteps]).execute(
                        source: source, pacingEnabled: false, daemonOptedIn: true,
                        viaDaemon: { _, _ in XCTFail("not sent"); return "[]" })
                }
                XCTFail("\(label): must fail")
            } catch is ScriptParseError {}
            XCTAssertEqual(fake.scripts, [], "\(label): \(fake.transcript)")
        }
        // Every step names its own target: the exec-level window is never read.
        let fake = PinFakeSafari()
        try await fake.drive {
            try await ExecCommand.parse(["--window", "2"]).execute(
                source: ##"[{"cmd":"get url","args":["--url","home"]},{"cmd":"documents"}]"##,
                pacingEnabled: false, daemonOptedIn: true, viaDaemon: { _, _ in "[]" })
        }
        XCTAssertEqual(fake.scripts, [], fake.transcript)
    }

    /// The daemon's whole-run marker reads and rewrites the title before the first step: when the exec-level
    /// `--window N` arrives unpinned, the handler pins it first, and the wrap, the step and the unwrap all name
    /// the id.
    func testTheDaemonRunMarkerPinsAnUnpinnedWindowFirst() async throws {
        let fake = PinFakeSafari()
        fake.raiseAfterScripts = 1
        let envelope: [String: Any] = ["steps": [["cmd": "get url"]], "targetArgs": ["--window", "2"], "markTab": "ephemeral"]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        _ = try await fake.drive { try await DaemonDispatch.Handlers.execRunScript(paramsData: data) }
        XCTAssertTrue(fake.scripts.first.map(PinFakeSafari.isIndexAnchor) == true, fake.transcript)
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isIndexAnchor).count, 1, fake.transcript)
        let after = fake.scripts.dropFirst()
        XCTAssertTrue(after.contains { $0.contains("document.title") }, fake.transcript)
        XCTAssertTrue(after.allSatisfy { $0.contains("window id 5822") }, fake.transcript)
    }

    /// If the handler's attempt cannot read the id either, the run stays on the position for the wrap, the step
    /// and the unwrap: no step tries again, so a read that would succeed later cannot move the steps to an id the
    /// marker was not wrapped on. One note says the position is in use.
    func testAMarkedDaemonRunThatCannotReadTheIDStaysOnThePosition() async throws {
        let fake = PinFakeSafari()
        fake.anchorError = SafariBrowserError.appleScriptFailed("execution error: Safari got an error: AppleEvent timed out. (-1712)")
        fake.anchorErrorCount = 1
        let envelope: [String: Any] = ["steps": [["cmd": "get url"]], "targetArgs": ["--window", "2"], "markTab": "ephemeral"]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        _ = try await fake.drive { try await DaemonDispatch.Handlers.execRunScript(paramsData: data) }
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isIndexAnchor).count, 1, fake.transcript)
        XCTAssertTrue(fake.scripts.contains { $0.contains("document.title") }, fake.transcript)
        let namesAnID = try NSRegularExpression(pattern: #"window id [0-9]"#)
        XCTAssertFalse(fake.scripts.contains { namesAnID.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil },
                       "no script names an id the marker was not wrapped on:\n\(fake.transcript)")
        XCTAssertEqual(fake.diagnostics, [TargetOptions.pinFallbackNote(window: 2)])
    }

    /// The usual case: the client pinned, so the arguments arrive as an id. The handler reads nothing before the
    /// wrap (under `--profile` the client's enumeration was the check), and every script names that id.
    func testAMarkedDaemonRunWithAnIDThatArrivesPinnedReadsNothingMore() async throws {
        let fake = PinFakeSafari()
        let envelope: [String: Any] = [
            "steps": [["cmd": "get url"]], "markTab": "ephemeral",
            "targetArgs": ["--window-id", "5822", "--pinned-from-window", "1", "--profile", "Work"],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        _ = try await fake.drive { try await DaemonDispatch.Handlers.execRunScript(paramsData: data) }
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isEnumeration).count, 0, fake.transcript)
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isIndexAnchor).count, 0, fake.transcript)
        XCTAssertTrue(fake.scripts.contains { $0.contains("document.title") }, fake.transcript)
        XCTAssertTrue(fake.scripts.allSatisfy { $0.contains("window id 5822") }, fake.transcript)
    }

    // MARK: an id that arrives pinned is still checked against the profile

    /// A pinned id is not checked against `--profile` at every call, so one given with `--pinned-from-window` (by
    /// `exec`, or by hand) is checked once at command start: window 4711 is Home's, not Work's.
    func testAnIDThatArrivesPinnedIsCheckedAgainstTheProfileOnce() async {
        for (label, type, args) in [
            ("get url", GetURL.self as any AsyncParsableCommand.Type,
             ["--window-id", "4711", "--pinned-from-window", "1", "--profile", "Work"]),
            ("js with a tab", JSCommand.self as any AsyncParsableCommand.Type,
             ["1", "--window-id", "4711", "--tab-in-window", "1", "--pinned-from-window", "1", "--profile", "Work"]),
        ] {
            let fake = PinFakeSafari()
            let error = await run(type, args, on: fake)
            guard case SafariBrowserError.documentNotFound? = error else {
                XCTFail("\(label): a window of another profile must be refused, got \(String(describing: error))\n\(fake.transcript)")
                continue
            }
            XCTAssertFalse(fake.scripts.contains { !PinFakeSafari.isEnumeration($0) && ($0.contains("URL of") || $0.contains("do JavaScript")) },
                           "\(label): nothing is read from window 4711:\n\(fake.transcript)")
        }
    }

    private func run(_ type: any AsyncParsableCommand.Type, _ args: [String], on fake: PinFakeSafari) async -> Error? {
        do {
            var command = try type.parseAsRoot(args) as! any AsyncParsableCommand
            try await fake.drive { try await command.run() }
            return nil
        } catch {
            return error
        }
    }
}
