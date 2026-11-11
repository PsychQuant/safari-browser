import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #354, the rows of the verify report of 2026-11-11 (gate round 1) that changed code or wording.
final class WindowPinGateRound1Tests: XCTestCase {

    private func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private func run(_ type: any AsyncParsableCommand.Type, _ args: [String], on fake: PinFakeSafari) async -> Error? {
        do {
            var command = try type.parseAsRoot(args) as! any AsyncParsableCommand
            try await fake.drive { try await command.run() }
            return nil
        } catch {
            return error
        }
    }

    // MARK: row 1 — the marker probes keep their exit codes when the pin fails

    /// `tab is-marked` answers with its exit code: 0 marked, 1 unmarked, 2 error. An error the pin raised left
    /// `run()` as a thrown error, which exits 1: "unmarked", for a tab nobody read. `tab unmark` documents 2 for
    /// an error the same way. Under `--profile` the pin can fail in two ways, and both are exit 2.
    func testAFailedPinOfTheMarkerProbesIsTheirErrorExit() async {
        let commands: [(String, any AsyncParsableCommand.Type)] = [
            ("tab is-marked", TabIsMarkedCommand.self), ("tab unmark", TabUnmarkCommand.self),
        ]
        for (name, type) in commands {
            let stuck = PinFakeSafari()
            stuck.enumerationError = SafariBrowserError.processTimedOut(command: "osascript", seconds: 30)
            let timedOut = await run(type, ["--window", "1", "--profile", "Work"], on: stuck)
            XCTAssertEqual((timedOut as? ExitCode)?.rawValue, 2,
                           "\(name): an enumeration that times out, got \(String(describing: timedOut))\n\(stuck.transcript)")
            XCTAssertFalse(stuck.scripts.contains { $0.contains("do JavaScript") }, "\(name): no title is read:\n\(stuck.transcript)")

            // Window 4711 is Home's: the id arrives with the private record, and the check at command start refuses it.
            let other = PinFakeSafari()
            let refused = await run(type, ["--window-id", "4711", "--pinned-from-window", "1", "--profile", "Work"], on: other)
            XCTAssertEqual((refused as? ExitCode)?.rawValue, 2,
                           "\(name): an id of another profile, got \(String(describing: refused))\n\(other.transcript)")
            XCTAssertFalse(other.scripts.contains { $0.contains("do JavaScript") }, "\(name): no title is read:\n\(other.transcript)")
        }
    }

    /// The answers the two commands give when nothing fails are unchanged.
    func testTheMarkerProbesStillAnswerWhenThePinSucceeds() async {
        let probe = PinFakeSafari()
        let unmarked = await run(TabIsMarkedCommand.self, ["--window", "1", "--profile", "Work"], on: probe)
        XCTAssertEqual((unmarked as? ExitCode)?.rawValue, 1, "the fake's title carries no marker\n\(probe.transcript)")
        let cleanup = PinFakeSafari()
        let unmark = await run(TabUnmarkCommand.self, ["--window", "1", "--profile", "Work"], on: cleanup)
        XCTAssertNil(unmark, cleanup.transcript)
    }

    // MARK: row 2 — one enumeration for a pinned tab that arrives under a profile

    /// `js`, `wait` and `save-pdf` anchor instead of pinning, so `--window-id W --tab-in-window T
    /// --pinned-from-window N --profile P` reaches the anchoring entry unchecked. One enumeration checks it against
    /// the profile and finds the tab; a second one, made by a branch that ran before the first, bought nothing.
    func testAPinnedTabThatArrivesUnderAProfileIsCheckedByOneEnumeration() async throws {
        let fake = PinFakeSafari()
        let anchored = try await fake.drive {
            try await SafariBridge.resolveToAnchoredTarget(.windowID(5822, tabInWindow: 1, pinnedFrom: 1), profile: "Work")
        }
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isEnumeration).count, 1, fake.transcript)
        guard case .resolvedTab(let windowID, let tab, _, let profile) = anchored else {
            return XCTFail("expected the tab by window id, got \(anchored)")
        }
        XCTAssertEqual(windowID, 5822)
        XCTAssertEqual(tab, 1)
        XCTAssertEqual(profile, "Work")

        // The one enumeration is still the profile check: window 4711 is Home's.
        let other = PinFakeSafari()
        do {
            let target = try await other.drive {
                try await SafariBridge.resolveToAnchoredTarget(.windowID(4711, tabInWindow: 1, pinnedFrom: 1), profile: "Work")
            }
            XCTFail("a window of another profile must be refused, got \(target)")
        } catch SafariBrowserError.documentNotFound {
            XCTAssertEqual(other.scripts.filter(PinFakeSafari.isEnumeration).count, 1, other.transcript)
        }
    }

    // MARK: row 4 — save-image's position read

    /// `save-image --window N` asks for the pinned window's position once (its early target check). A failure of
    /// that read other than "no such window" is the command's error, and the image is not read. Stated in the
    /// requirement "Window number resolved to its id at command start".
    func testSaveImageFailsWhenThePositionOfThePinnedWindowCannotBeRead() async {
        let fake = PinFakeSafari()
        fake.indexReadError = SafariBrowserError.processTimedOut(command: "osascript", seconds: 2)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pin-gate-\(UUID().uuidString).png").path
        let error = await run(SaveImageCommand.self, [path, "--element", "img", "--window", "2"], on: fake)
        guard case SafariBrowserError.processTimedOut? = error else {
            return XCTFail("expected the timeout of the position read, got \(String(describing: error))\n\(fake.transcript)")
        }
        XCTAssertTrue(fake.scripts.contains { $0.contains("get index of window id 5822") }, fake.transcript)
        XCTAssertFalse(fake.scripts.contains { $0.contains("do JavaScript") }, "the image is not read:\n\(fake.transcript)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// The same read answering "no such window" is the pinned miss, in the words of a window that was looked for.
    func testSaveImageReportsAPinnedWindowThatClosedBeforeThePositionRead() async {
        let fake = PinFakeSafari()
        fake.closeAfterScripts = (1, 5822)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pin-gate-\(UUID().uuidString).png").path
        let error = await run(SaveImageCommand.self, [path, "--element", "img", "--window", "2"], on: fake)
        guard case SafariBrowserError.documentNotFound(let pattern, let available)? = error else {
            return XCTFail("expected the pinned miss, got \(String(describing: error))\n\(fake.transcript)")
        }
        XCTAssertEqual(pattern, "window 2 (window id 5822 at command start)")
        XCTAssertEqual(available, [SafariBridge.windowIDMissNote(pinnedFrom: 2, tabs: false)])
        XCTAssertTrue(available[0].contains("is no longer open;"), "the query named only the window: \(available[0])")
    }

    // MARK: row 5 — a miss says only what the failed step shows

    /// A step that names `current tab of window id W` and gets "object not found" has not shown that the window
    /// closed: the same answer comes back for a window with no tab. Without `--profile` nothing is looked up
    /// afterwards, so the note and the hint name both possibilities.
    func testAPinnedWindowMissThatWasNotCheckedNamesBothPossibilities() async throws {
        let fake = PinFakeSafari()
        fake.closeAfterScripts = (1, 5822)
        let error = await fake.run(GetURL.self, ["--window", "2"])
        guard let error = error as? SafariBrowserError, case .documentNotFound(let pattern, let available) = error else {
            return XCTFail("expected a targeting miss, got \(String(describing: error))\n\(fake.transcript)")
        }
        XCTAssertEqual(pattern, "window 2 (window id 5822 at command start)")
        XCTAssertEqual(available, [SafariBridge.windowIDMissNote(pinnedFrom: 2, tabs: false, checked: false)])
        XCTAssertEqual(available[0], "(the window that was window 2 at command start, or its current tab, could not be found; "
            + "the command does not move on to the window now in that position)")
        XCTAssertFalse(available[0].contains("is no longer open"), available[0])
        XCTAssertEqual(fake.scripts.count, 2, "the pin and the failed read; nothing is looked up afterwards:\n\(fake.transcript)")
        let message = flat(error.localizedDescription)
        XCTAssertTrue(message.contains("the window that --window N named when the command started is no longer open, or its "
            + "current tab could not be found, and the command did not move on to the window now in that position"), message)
    }

    /// A window that a query or an enumeration looked for and did not find is said to be gone.
    func testACheckedPinnedWindowMissSaysTheWindowIsNoLongerOpen() {
        XCTAssertEqual(SafariBridge.windowIDMissNote(pinnedFrom: 2, tabs: false),
                       "(the window that was window 2 at command start is no longer open; "
                           + "the command does not move on to the window now in that position)")
        XCTAssertEqual(SafariBridge.windowIDMissNote(pinnedFrom: nil, tabs: false, checked: false), "(no such window)",
                       "an id the user typed keeps its note")
    }

    // MARK: row 7 — under a profile, a pin of exec that cannot list the windows is exec's error

    private final class Recorder: StepDispatcher, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var commands: [String] { lock.withLock { calls } }
        func dispatch(cmd: String, args: [String], sharedTargetArgs: [String]) async throws -> String {
            lock.withLock { calls.append(cmd) }
            return "x"
        }
    }

    /// `exec --window N --profile P`: the enumeration that reads the id times out. That is `exec`'s own error:
    /// nothing is routed to the daemon, no step is dispatched, and no note about a position is written (the
    /// position is not used). Both specs say so (document-targeting, script-exec "Shared target resolution").
    func testExecUnderAProfileFailsBeforeAnyStepWhenTheWindowsCannotBeListed() async {
        let source = ##"[{"cmd":"get url","onError":"continue"},{"cmd":"get title","onError":"continue"}]"##
        for daemonOptedIn in [false, true] {
            let fake = PinFakeSafari()
            fake.enumerationError = SafariBrowserError.processTimedOut(command: "osascript", seconds: 30)
            let recorder = Recorder()
            var notes: [String] = []
            do {
                try await fake.drive {
                    try await ExecCommand.parse(["--window", "1", "--profile", "Work"]).execute(
                        source: source, pacingEnabled: false, daemonOptedIn: daemonOptedIn,
                        viaDaemon: { _, _ in XCTFail("nothing is sent to the daemon"); return nil },
                        note: { notes.append($0) }, environment: [:], stepDispatcher: recorder)
                }
                XCTFail("daemon \(daemonOptedIn): exec must fail\n\(fake.transcript)")
            } catch SafariBrowserError.processTimedOut {
                XCTAssertEqual(recorder.commands, [], "daemon \(daemonOptedIn): no step runs")
                XCTAssertEqual(notes, [], "daemon \(daemonOptedIn): the position is not used, so no note says it is")
                XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isEnumeration).count, 1, fake.transcript)
                XCTAssertEqual(fake.scripts.count, 1, "nothing but the one enumeration:\n\(fake.transcript)")
            } catch {
                XCTFail("daemon \(daemonOptedIn): expected the timeout, got \(error)")
            }
        }
    }

    /// The scope of that rule: a script in which no step uses the exec-level target is not pinned, so nothing is
    /// enumerated and the steps run.
    func testExecUnderAProfileDoesNotListTheWindowsWhenNoStepUsesItsTarget() async throws {
        let fake = PinFakeSafari()
        fake.enumerationError = SafariBrowserError.processTimedOut(command: "osascript", seconds: 30)
        let recorder = Recorder()
        try await fake.drive {
            try await ExecCommand.parse(["--window", "1", "--profile", "Work"]).execute(
                source: ##"[{"cmd":"documents"}]"##, pacingEnabled: false, daemonOptedIn: false,
                viaDaemon: { _, _ in XCTFail("not sent"); return nil },
                note: { _ in }, environment: [:], stepDispatcher: recorder)
        }
        XCTAssertEqual(recorder.commands, ["documents"])
        XCTAssertEqual(fake.scripts, [], fake.transcript)
    }

    // MARK: row 9 — an attempt of the daemon's that raises an error is not recorded

    private func daemonRun(on fake: PinFakeSafari, targetArgs: [String], markTab: String? = nil,
                           steps: [[String: Any]]) async throws -> [[String: Any]] {
        var envelope: [String: Any] = ["steps": steps, "targetArgs": targetArgs]
        if let markTab { envelope["markTab"] = markTab }
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let reply = try await fake.drive { try await DaemonDispatch.Handlers.execRunScript(paramsData: data) }
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let results = try XCTUnwrap(object["results"] as? String)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(results.utf8)) as? [[String: Any]])
    }

    /// A run without the marker whose target arrives as `--window N --profile P` (the client could not read the
    /// id): the first step that needs it makes the attempt. An attempt that raises an error is that step's error
    /// and is not recorded as the request's answer, so the next step that needs the target makes the attempt
    /// again; one that returns is used by every later step.
    func testADaemonAttemptThatRaisesAnErrorIsTriedAgainByTheNextStep() async throws {
        let fake = PinFakeSafari()
        fake.enumerationError = SafariBrowserError.processTimedOut(command: "osascript", seconds: 30)
        fake.enumerationErrorCount = 1
        let steps: [[String: Any]] = [
            ["cmd": "get url", "onError": "continue"], ["cmd": "get url", "onError": "continue"],
            ["cmd": "get title", "onError": "continue"],
        ]
        let results = try await daemonRun(on: fake, targetArgs: ["--window", "1", "--profile", "Work"], steps: steps)
        XCTAssertEqual(results.count, 3, "\(results)")
        XCTAssertNotNil(results[0]["error"], "the first step reports the failed attempt: \(results)")
        XCTAssertNil(results[1]["error"], "the second step made the attempt again: \(results)\n\(fake.transcript)")
        XCTAssertNil(results[2]["error"], "\(results)")
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isEnumeration).count, 2,
                       "one failed attempt, one that returned and is reused by the third step:\n\(fake.transcript)")
        let reads = fake.scripts.filter { !PinFakeSafari.isEnumeration($0) }
        XCTAssertFalse(reads.isEmpty, fake.transcript)
        XCTAssertTrue(reads.allSatisfy { $0.contains("window id 5822") }, "Work's first window is 5822:\n\(fake.transcript)")
    }

    /// With the marker, the one attempt is made before the title is read, and an error it raises fails the
    /// request as a whole: no title is read or rewritten and no step runs.
    func testAMarkedDaemonRunFailsAsAWholeWhenItsAttemptRaisesAnError() async {
        let fake = PinFakeSafari()
        fake.enumerationError = SafariBrowserError.processTimedOut(command: "osascript", seconds: 30)
        do {
            let results = try await daemonRun(on: fake, targetArgs: ["--window", "1", "--profile", "Work"], markTab: "ephemeral",
                                              steps: [["cmd": "get url", "onError": "continue"]])
            XCTFail("the request must fail: \(results)\n\(fake.transcript)")
        } catch SafariBrowserError.processTimedOut {
            XCTAssertEqual(fake.scripts.count, 1, "the enumeration, and nothing else:\n\(fake.transcript)")
        } catch {
            XCTFail("expected the timeout, got \(error)")
        }
    }

    // MARK: row 8 — the help of --window

    func testTheWindowHelpSaysWhatAFailedEnumerationUnderAProfileDoes() {
        let help = flat(GetURL.helpMessage(columns: 400))
        XCTAssertTrue(help.contains("If the id cannot be read at start, a note says so and N stays a position; with --profile, an "
            + "enumeration that times out or fails is the command's error instead."), help)
    }
}
