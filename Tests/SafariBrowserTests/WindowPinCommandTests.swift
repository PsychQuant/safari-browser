import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #354: the commands that take the targeting flags read `--window N`'s id once at command start, and every
/// later AppleScript names `window id W` — even when another window is raised to position N mid-command.
final class WindowPinCommandTests: XCTestCase {

    /// `of window 2`, `window 2 tab 1`… — a window named by its position. `window id 5822` is not.
    private static let positional = try! NSRegularExpression(pattern: #"window (?!id )[0-9]"#)

    private func namesAPosition(_ script: String) -> Bool {
        Self.positional.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)) != nil
    }

    /// Runs `args` with `--window 2` while the last window is raised to the front after the first script, and
    /// requires the command to finish: `expect` checks the error it returned (none, by default).
    @discardableResult
    private func runRaised<C: AsyncParsableCommand>(
        _ type: C.Type, _ args: [String], answer: String = "OK",
        expect: (Error?) -> Bool = { $0 == nil },
        file: StaticString = #filePath, line: UInt = #line
    ) async -> PinFakeSafari {
        let fake = PinFakeSafari()
        fake.raiseAfterScripts = 1
        fake.answer = answer
        let error = await fake.run(type, args)
        XCTAssertTrue(expect(error), "\(C.self) \(args): \(String(describing: error))\n\(fake.transcript)", file: file, line: line)
        XCTAssertTrue(fake.scripts.first.map(PinFakeSafari.isIndexAnchor) == true,
                      "the id is read first:\n\(fake.transcript)", file: file, line: line)
        let after = fake.scripts(afterFirst: PinFakeSafari.isIndexAnchor)
        XCTAssertFalse(after.isEmpty, "nothing after the pin:\n\(fake.transcript)", file: file, line: line)
        XCTAssertFalse(after.contains(where: namesAPosition), "a later script names a position:\n\(fake.transcript)",
                       file: file, line: line)
        XCTAssertTrue(after.contains { $0.contains("window id 5822") }, "window 2 was id 5822:\n\(fake.transcript)",
                      file: file, line: line)
        return fake
    }

    private static let snapshotJSON = #"{"refs":["@e1 button \"Go\""],"json":[]}"#

    // MARK: 2.1 the commands

    func testReadCommandsFollowTheWindowThatWasNNotThePosition() async {
        await runRaised(GetURL.self, ["--window", "2"])
        await runRaised(GetTitle.self, ["--window", "2"])
        await runRaised(GetText.self, ["#log", "--window", "2"])
        await runRaised(GetSource.self, ["--window", "2"])
        await runRaised(IsVisible.self, ["#a", "--window", "2"])
        await runRaised(SnapshotCommand.self, ["--window", "2"], answer: Self.snapshotJSON)
        await runRaised(SnapshotCommand.self, ["--page", "--window", "2"])
        await runRaised(StorageLocalGet.self, ["k", "--window", "2"])
        await runRaised(CookiesGet.self, ["--window", "2"])
        await runRaised(ConsoleCommand.self, ["--window", "2"])
        // The fake's title carries no marker: "unmarked" is exit 1, the answer this probe gives.
        await runRaised(TabIsMarkedCommand.self, ["--window", "2"], expect: { ($0 as? ExitCode)?.rawValue == 1 })
    }

    func testActionCommandsFollowTheWindowThatWasNNotThePosition() async {
        await runRaised(ClickCommand.self, ["#go", "--window", "2"])
        await runRaised(FillCommand.self, ["#q", "x", "--window", "2"])
        await runRaised(PressCommand.self, ["Enter", "--window", "2"])
        await runRaised(BackCommand.self, ["--window", "2"])
        await runRaised(ScrollCommand.self, ["down", "--window", "2"])
        await runRaised(StorageLocalSet.self, ["k", "v", "--window", "2"])
        await runRaised(TabUnmarkCommand.self, ["--window", "2"])
        await runRaised(SetMedia.self, ["dark", "--window", "2"])
    }

    func testATabOfAWindowNumberIsAddressedByIDAndTab() async {
        let fake = PinFakeSafari()
        fake.raiseAfterScripts = 1
        await fake.run(GetURL.self, ["--window", "1", "--tab-in-window", "2"])
        let after = fake.scripts(afterFirst: PinFakeSafari.isIndexAnchor)
        XCTAssertTrue(after.contains { $0.contains("tab 2 of window id 4711") }, fake.transcript)
        XCTAssertFalse(after.contains(where: namesAPosition), fake.transcript)
    }

    /// With `--profile` the id comes from one enumeration, which is the profile check for the whole command: the
    /// wrap, the click and the unwrap of `click --mark-tab` address that id and never count windows again. Before
    /// #354 each of those calls enumerated, and the window raised after the first one became the profile's
    /// window 1 for the later calls.
    func testWithAProfileEveryLaterStepNamesTheIDWithoutCountingAgain() async {
        let fake = PinFakeSafari()
        fake.raiseAfterScripts = 1
        let error = await fake.run(ClickCommand.self, ["#go", "--mark-tab", "--window", "1", "--profile", "Work"])
        XCTAssertNil(error, fake.transcript)
        XCTAssertTrue(fake.scripts.first.map(PinFakeSafari.isEnumeration) == true, fake.transcript)
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isEnumeration).count, 1, fake.transcript)
        let targeted = fake.scripts.filter { !PinFakeSafari.isEnumeration($0) }
        XCTAssertGreaterThanOrEqual(targeted.count, 3, "title read, click, title read back:\n\(fake.transcript)")
        XCTAssertTrue(targeted.allSatisfy { $0.contains("window id 5822") }, fake.transcript)
        XCTAssertFalse(targeted.contains(where: namesAPosition), fake.transcript)
    }

    /// The pin under `--profile` reads no dialog state; the command's own first step does (verify F31).
    func testThePinItselfDoesNotProbeForDialogs() async throws {
        let fake = PinFakeSafari()
        let options = try TargetOptions.parse(["--window", "1", "--profile", "Work"])
        _ = try await fake.drive { try await options.pinWindowAtStart() }
        XCTAssertEqual(fake.probes, 0)
    }

    /// The id cannot be read: the scripts are the positional ones they always were.
    func testAnUnreadableIDLeavesTheOldPositionalScripts() async {
        let fake = PinFakeSafari()
        let error = await fake.run(GetURL.self, ["--window", "9"])
        guard case SafariBrowserError.documentNotFound(let pattern, _)? = error else {
            return XCTFail("expected the old targeting miss, got \(String(describing: error))\n\(fake.transcript)")
        }
        XCTAssertEqual(pattern, "window 9")
        XCTAssertTrue(fake.scripts.contains { $0.contains("window 9") && !PinFakeSafari.isIndexAnchor($0) }, fake.transcript)
    }

    // MARK: 2.2 --mark-tab

    /// The id is read before the title is read and wrapped, so the wrap, the click and the unwrap all name it.
    func testClickMarkTabPinsBeforeTheWrap() async {
        let fake = await runRaised(ClickCommand.self, ["#go", "--mark-tab", "--window", "2"])
        let titleScripts = fake.scripts.filter { $0.contains("document.title") }
        XCTAssertFalse(titleScripts.isEmpty, "the marker read and wrote the title:\n\(fake.transcript)")
        XCTAssertTrue(titleScripts.allSatisfy { $0.contains("window id 5822") }, fake.transcript)
    }

    // MARK: 2.3 open

    func testOpenWithAWindowNumberReadsTheReferenceByIDAndActivatesLast() async {
        let fake = PinFakeSafari()
        fake.raiseAfterScripts = 1
        await fake.run(OpenCommand.self, ["https://example.com/b", "--window", "2"])
        let after = fake.scripts(afterFirst: PinFakeSafari.isIndexAnchor)
        guard let navigate = after.first(where: { $0.contains("window.location.href") }) else {
            return XCTFail("no navigation:\n\(fake.transcript)")
        }
        XCTAssertTrue(navigate.contains("get name of document of window id 5822"), navigate)
        let activate = navigate.range(of: "activate")
        let href = navigate.range(of: "window.location.href")
        XCTAssertNotNil(activate)
        if let activate, let href { XCTAssertGreaterThan(activate.lowerBound, href.lowerBound, "activate comes last:\n\(navigate)") }
        XCTAssertFalse(navigate.contains("make new document"), navigate)
        XCTAssertFalse(after.contains(where: namesAPosition), fake.transcript)
    }

    func testOpenWithAWindowNumberAndNoWindowStillMakesANewDocument() async {
        let fake = PinFakeSafari(windows: [])
        await fake.run(OpenCommand.self, ["https://example.com/b", "--window", "1"])
        XCTAssertTrue(fake.scripts.contains { $0.contains("make new document") }, fake.transcript)
    }

    func testOpenNewTabWithAWindowNumberKeepsItsOwnReadBeforeActivate() async {
        let fake = PinFakeSafari()
        await fake.run(OpenCommand.self, ["https://example.com/b", "--new-tab", "--window", "2"])
        XCTAssertFalse(fake.scripts.contains(where: PinFakeSafari.isIndexAnchor),
                       "--new-tab is not pinned at command start:\n\(fake.transcript)")
        XCTAssertTrue(fake.scripts.contains { $0.contains("id of window 2") && $0.contains("activate") }, fake.transcript)
    }

    // MARK: 2.4 upload --js

    func testUploadOnTheJavaScriptPathAddressesTheID() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await runRaised(UploadCommand.self, ["--js", "input[type=file]", file.path, "--window", "2"])
    }

    // MARK: 3 exec

    private final class Recorder: StepDispatcher, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        var shared: [[String]] { lock.withLock { calls } }
        func dispatch(cmd: String, args: [String], sharedTargetArgs: [String]) async throws -> String {
            lock.withLock { calls.append(sharedTargetArgs) }
            return "x"
        }
    }

    /// The daemon route: the request carries `--window-id W`, read once before the script is sent.
    func testExecSendsTheDaemonTheWindowIDReadOnceBeforeRouting() async throws {
        let fake = PinFakeSafari()
        final class Box: @unchecked Sendable { var args: [String]? }
        let box = Box()
        try await fake.drive {
            try await ExecCommand.parse(["--window", "2"]).execute(
                source: ##"[{"cmd":"get url"},{"cmd":"js","args":["1"]}]"##, pacingEnabled: false, daemonOptedIn: true
            ) { command, steps in
                box.args = command.daemonEnvelope(steps: steps)["targetArgs"] as? [String]
                return "[]"
            }
        }
        XCTAssertEqual(box.args, ["--window-id", "5822", "--pinned-from-window", "2"])
        XCTAssertEqual(fake.scripts.count, 1, fake.transcript)
        XCTAssertTrue(fake.scripts.first.map(PinFakeSafari.isIndexAnchor) == true, fake.transcript)
    }

    /// The step-by-step route: every step gets the same `--window-id W`, and windows are counted once.
    func testExecGivesEveryLocalStepTheWindowIDReadOnce() async throws {
        let fake = PinFakeSafari()
        fake.raiseAfterScripts = 1
        let recorder = Recorder()
        try await fake.drive {
            try await ExecCommand.parse(["--window", "2", "--tab-in-window", "1"]).execute(
                source: ##"[{"cmd":"get url"},{"cmd":"get title"},{"cmd":"js","args":["1"]}]"##,
                pacingEnabled: false, daemonOptedIn: false, viaDaemon: { _, _ in XCTFail("not sent"); return nil },
                stepDispatcher: recorder)
        }
        XCTAssertEqual(recorder.shared.count, 3)
        for args in recorder.shared {
            XCTAssertEqual(args, ["--window-id", "5822", "--pinned-from-window", "2", "--tab-in-window", "1"])
        }
        XCTAssertEqual(fake.scripts.count, 1, "one read for the whole run:\n\(fake.transcript)")
    }

    /// `exec`'s own read failed. Step by step, `exec` says so once, through its `note` seam, and every step gets
    /// `--window N` to read again at its own start. When the daemon takes the whole script, `exec` says nothing:
    /// the daemon makes the one more attempt and speaks for itself, so a note that the daemon's read would make
    /// untrue is never printed, and nothing is said twice.
    func testExecWritesItsFallbackNoteOnlyWhenItRunsStepByStep() async throws {
        let source = ##"[{"cmd":"get url"}]"##
        let silent = SafariBrowserError.appleScriptFailed("execution error: Safari got an error: AppleEvent timed out. (-1712)")

        let local = PinFakeSafari()
        local.anchorError = silent
        let recorder = Recorder()
        var localNotes: [String] = []
        try await local.drive {
            try await ExecCommand.parse(["--window", "2"]).execute(
                source: source, pacingEnabled: false, daemonOptedIn: false,
                viaDaemon: { _, _ in XCTFail("not sent"); return nil },
                note: { localNotes.append($0) }, environment: [:], stepDispatcher: recorder)
        }
        XCTAssertEqual(localNotes, [TargetOptions.pinFallbackNote(window: 2)])
        XCTAssertEqual(recorder.shared, [["--window", "2"]])
        XCTAssertEqual(local.diagnostics, [], "through the seam, not the request context")

        let remote = PinFakeSafari()
        remote.anchorError = silent
        var remoteNotes: [String] = []
        var sent: [String] = []
        try await remote.drive {
            try await ExecCommand.parse(["--window", "2"]).execute(
                source: source, pacingEnabled: false, daemonOptedIn: true,
                viaDaemon: { command, _ in sent = ScriptInterpreter.encodeTargetArgs(command.target); return "[]" },
                note: { remoteNotes.append($0) }, environment: [:])
        }
        XCTAssertEqual(sent, ["--window", "2"], "the daemon receives the position and makes its own attempt")
        XCTAssertEqual(remoteNotes, [])
        XCTAssertEqual(remote.diagnostics, [])

        // The daemon was tried and declined (no socket, an older daemon): the script runs step by step after
        // all, and the note held back for the daemon is written then, once.
        let declined = PinFakeSafari()
        declined.anchorError = silent
        let declinedRecorder = Recorder()
        var declinedNotes: [String] = []
        try await declined.drive {
            try await ExecCommand.parse(["--window", "2"]).execute(
                source: source, pacingEnabled: false, daemonOptedIn: true,
                viaDaemon: { _, _ in nil },
                note: { declinedNotes.append($0) }, environment: [:], stepDispatcher: declinedRecorder)
        }
        XCTAssertEqual(declinedNotes, [TargetOptions.pinFallbackNote(window: 2)])
        XCTAssertEqual(declinedRecorder.shared, [["--window", "2"]])
    }

    /// In the daemon: a step's own `--window N` is pinned at the start of that step; the shared `--window-id`
    /// is used as it is, without another read.
    func testAnInProcessStepPinsItsOwnWindowNumber() async throws {
        let fake = PinFakeSafari()
        fake.raiseAfterScripts = 1
        let dispatcher = InProcessStepDispatcher()
        let own = try await fake.drive {
            try await dispatcher.dispatch(cmd: "get url", args: ["--window", "2"], sharedTargetArgs: ["--window-id", "4711"])
        }
        XCTAssertEqual(own, "https://work.example/a1", "the step read window 5822, which was window 2 when it started")
        XCTAssertTrue(fake.scripts.first.map(PinFakeSafari.isIndexAnchor) == true, fake.transcript)
        let after = fake.scripts(afterFirst: PinFakeSafari.isIndexAnchor)
        XCTAssertTrue(after.contains { $0.contains("URL of") && $0.contains("window id 5822") }, fake.transcript)
        XCTAssertFalse(after.contains(where: namesAPosition), fake.transcript)

        let shared = PinFakeSafari()
        let viaShared = try await shared.drive {
            try await InProcessStepDispatcher().dispatch(
                cmd: "get url", args: [], sharedTargetArgs: ["--window-id", "5822", "--pinned-from-window", "2"])
        }
        XCTAssertEqual(viaShared, "https://work.example/a1")
        XCTAssertFalse(shared.scripts.contains(where: PinFakeSafari.isIndexAnchor), shared.transcript)
        XCTAssertTrue(shared.scripts.contains { $0.contains("URL of") }, "the step did read:\n\(shared.transcript)")
        XCTAssertTrue(shared.scripts.allSatisfy { $0.contains("window id 5822") }, shared.transcript)
    }

    /// A pinned window that closes between two steps: the next step fails naming `--window 2`, not the window
    /// now at position 2.
    func testAnExecStepAfterThePinnedWindowClosedNamesTheWindowNumber() async throws {
        let fake = PinFakeSafari()
        fake.closeAfterScripts = (1, 5822)
        let dispatcher = InProcessStepDispatcher()
        do {
            _ = try await fake.drive {
                try await dispatcher.dispatch(cmd: "get url", args: [],
                                              sharedTargetArgs: ["--window-id", "5822", "--pinned-from-window", "2"])
            }
            _ = try await fake.drive {
                try await dispatcher.dispatch(cmd: "get url", args: [],
                                              sharedTargetArgs: ["--window-id", "5822", "--pinned-from-window", "2"])
            }
            XCTFail("the second step must miss:\n\(fake.transcript)")
        } catch SafariBrowserError.documentNotFound(let pattern, _) {
            XCTAssertEqual(pattern, "window 2 (window id 5822 at command start)")
        }
    }

    // MARK: 2.5 tripwire

    /// Every command STRUCT that composes `TargetOptions` calls `pinWindowAtStart()`, or is a known exception
    /// with its reason, so a new command cannot go back to counting `--window N` at every Apple event unnoticed.
    /// A shape check, not a proof: it cannot see a command that pins and then reads `self.target` again (the
    /// driven tests above are what catch that).
    func testEveryCommandStructWithATargetPinsTheWindowExceptTheKnownOnes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SafariBrowser/Commands")
        let known: [String: String] = [
            "JSCommand": "anchors --window N itself (resolveToAnchoredTarget, #180), with the current-tab check",
            "WaitCommand": "anchors --window N itself (resolveToAnchoredTarget, #168)",
            "SavePDFCommand": "anchors --window N itself (resolveToAnchoredTarget, #344)",
            "CloseCommand": "window-level primitive: #353",
            "ScreenshotCommand": "window-level primitive: #353",
            "PdfCommand": "window-level primitive: #353",
            "TabsCommand": "lists the window's tabs by the id one enumeration read",
            "TabSwitchCommand": "`tab <N>` is one Apple event (by position without --profile, by the enumeration's id with it); `tab new` reads the id itself (#351, #352)",
            "TabFocusCommand": "resolves once and switches by the id the resolver read (#352)",
            "DocumentsCommand": "lists every tab and reads no single target",
            "PDFCacheGet": "reads one tab URL through its injected seam; nothing after it addresses the window",
        ]
        let optionGroup = try NSRegularExpression(pattern: #"@OptionGroup var \w+: TargetOptions"#)
        var missing: [String] = []
        var seen: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() where file.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            var structs = text.components(separatedBy: "\nstruct ")
            structs.removeFirst()
            for block in structs {
                let name = String(block.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                guard optionGroup.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)) != nil else { continue }
                seen.insert(name)
                // A call, with or without the `note:` argument `exec` passes.
                if block.contains(".pinWindowAtStart(") { continue }
                if known[name] == nil { missing.append("\(file): \(name)") }
            }
        }
        XCTAssertEqual(missing, [], "a command struct with a target that never pins --window N")
        XCTAssertEqual(Set(known.keys).subtracting(seen), [], "a known exception that no longer exists")
    }
}
