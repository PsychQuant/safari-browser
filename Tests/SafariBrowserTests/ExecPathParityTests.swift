import Foundation
import XCTest
@testable import SafariBrowser

/// #220: the same exec script must not give different results because one path (the daemon's
/// in-process dispatcher) is chosen over the other (a child process per step). A step whose
/// arguments the in-process dispatcher does not honour exactly is not run in-process at all;
/// the differences that remain are recorded in the spec, not hidden.
final class ExecPathParityTests: XCTestCase, @unchecked Sendable {
    typealias FakeSafari = ExecSharedTargetTests.Fake

    // MARK: - Which steps run in-process (a closed list of shapes)

    func testEveryShapeTheInProcessDispatcherHonoursIsAccepted() {
        let cases: [(String, [String])] = [
            ("js", ["1+1"]),
            ("js", ["document.title", "--url", "plaud"]),
            ("js", ["document.title", "--window", "2", "--tab-in-window", "1"]),
            ("js", ["document.title", "--url", "plaud", "--first-match"]),
            ("get url", []), ("get title", []), ("get text", []), ("get source", []),
            ("get url", ["--url", "plaud", "--first-match"]),
            ("get text", ["--profile", "Work"]),
            ("documents", []), ("documents", ["--profile", "Work"]), ("documents", ["--json"]),
        ]
        for (cmd, args) in cases {
            XCTAssertTrue(InProcessStepDispatcher.runsInProcess(cmd: cmd, args: args), "\(cmd) \(args)")
        }
    }

    /// Each of these was silently ignored or misread in-process, and honoured (or rejected) by the
    /// child that runs the CLI command.
    func testArgumentsTheInProcessDispatcherWouldIgnoreOrMisreadSendTheStepToTheSubprocessPath() {
        let cases: [(String, [String], String)] = [
            ("js", ["--file", "script.js"], "the first positional would become the code"),
            ("js", ["1+1", "--large"], "a CLI-only option"),
            ("js", ["1+1", "--output", "out.txt"], "a CLI-only option"),
            ("js", ["1+1", "2+2"], "a stray positional"),
            ("js", [], "no code"),
            ("js", ["-1"], "code that starts like an option"),
            ("get text", ["#selector"], "the selector would be ignored and the whole page returned"),
            ("get url", ["stray"], "ArgumentParser rejects it in the child"),
            ("get title", ["stray"], "ArgumentParser rejects it in the child"),
            ("get source", ["--bogus"], "an unknown option"),
            ("documents", ["stray"], "a stray positional"),
            ("get url", ["--first-match"], "step-level --first-match with no target flag is dropped in-process"),
            ("js", ["1+1", "--first-match"], "step-level --first-match with no target flag is dropped in-process"),
            ("get text", ["--mark-tab"], "a flag the in-process dispatcher does not read"),
            ("click", ["#x"], "not an in-process command"),
        ]
        for (cmd, args, why) in cases {
            XCTAssertFalse(InProcessStepDispatcher.runsInProcess(cmd: cmd, args: args), "\(cmd) \(args): \(why)")
        }
    }

    func testATargetFlagWithNoValueIsNotARunnableShape() {
        XCTAssertFalse(InProcessStepDispatcher.runsInProcess(cmd: "get url", args: ["--url"]))
        XCTAssertFalse(InProcessStepDispatcher.runsInProcess(cmd: "js", args: ["1+1", "--window"]))
        XCTAssertTrue(InProcessStepDispatcher.runsInProcess(cmd: "get url", args: ["--url", "plaud"]))
    }

    /// A step whose arguments name a variable has no shape until it runs. Judged on the text as
    /// written, `$n * 2` looks like ordinary code and passes; the daemon substitutes `-4 * 2`, the
    /// dispatcher refuses it — after earlier steps have already run, with no way back. So a step
    /// that references a variable is not sent to the daemon.
    func testAStepThatReferencesAVariableIsNotSentToTheDaemon() throws {
        let cases: [(String, Bool)] = [
            (##"[{"cmd":"js","args":["1-5"],"var":"n"},{"cmd":"js","args":["$n * 2"]}]"##, false),
            (##"[{"cmd":"get url","var":"u"},{"cmd":"js","args":["$u.length"]}]"##, false),
            (##"[{"cmd":"js","args":["1"]},{"cmd":"get url","args":["--url","$target"]}]"##, false),
            (##"[{"cmd":"js","args":["'\\$5'"]}]"##, true),
            (##"[{"cmd":"js","args":["a $1 b $% c"]}]"##, true),
        ]
        for (source, expected) in cases {
            let steps = try ScriptInterpreter.parseScript(source: source, maxSteps: 10)
            XCTAssertEqual(ExecCommand.allStepsRunInProcess(steps), expected, source)
        }
        XCTAssertTrue(VariableStore.hasReference("a $name b"))
        XCTAssertFalse(VariableStore.hasReference("a \\$name b"), "an escaped dollar is literal")
        XCTAssertFalse(VariableStore.hasReference("$1 $% $"))
    }

    // MARK: - The decision `ExecCommand.run` makes

    func testTheRouteSendsAScriptToTheDaemonOnlyWhenEverythingAgrees() {
        let honoured = ##"[{"cmd":"get url"},{"cmd":"js","args":["1+1"]}]"##
        let selector = ##"[{"cmd":"get url"},{"cmd":"get text","args":["#sel"]}]"##
        func route(_ source: String, pacing: Bool = false, daemon: Bool = true) -> ExecCommand.Route {
            ExecCommand.route(source: source, maxSteps: 100, pacingEnabled: pacing, daemonOptedIn: daemon)
        }
        XCTAssertEqual(route(honoured), .daemon([ScriptStep(cmd: "get url"), ScriptStep(cmd: "js", args: ["1+1"])]))
        XCTAssertEqual(route(selector), .subprocess, "one step the dispatcher cannot honour: the whole script runs as children")
        XCTAssertEqual(route(honoured, pacing: true), .subprocess)
        XCTAssertEqual(route(honoured, daemon: false), .subprocess)
        XCTAssertEqual(route("not json"), .subprocess)
    }

    /// `run()` hands the decision to `execute`, which asks `route`: the daemon request is made for a
    /// script every step of which runs in-process and for nothing else, and a script that is not
    /// sent (or whose request comes back empty) runs locally.
    func testExecSendsAScriptToTheDaemonOrRunsItLocallyAsTheRouteSays() async throws {
        final class Sent: @unchecked Sendable {
            private let lock = NSLock(); private var items: [[ScriptStep]] = []
            func add(_ steps: [ScriptStep]) { lock.withLock { items.append(steps) } }
            var all: [[ScriptStep]] { lock.withLock { items } }
        }
        func run(_ source: String, pacing: Bool = false, daemon: Bool = true, answer: String? = "FROM-DAEMON") async throws -> (printed: String, sent: [[ScriptStep]]) {
            let sent = Sent()
            let out = try await printed {
                try await ExecCommand.parse([]).execute(source: source, pacingEnabled: pacing, daemonOptedIn: daemon) { steps in
                    sent.add(steps); return answer
                }
            }
            return (out, sent.all)
        }
        // Steps guarded by an `if` that is false, so the local interpreter runs nothing in Safari.
        let honouredButSkipped = ##"[{"cmd":"get url","if":"$never exists"},{"cmd":"js","args":["1+1"],"if":"$never exists"}]"##
        let selectorAndSkipped = ##"[{"cmd":"get text","args":["#sel"],"if":"$never exists"}]"##

        let viaDaemon = try await run(honouredButSkipped)
        XCTAssertEqual(viaDaemon.sent.map { $0.map(\.cmd) }, [["get url", "js"]])
        XCTAssertTrue(viaDaemon.printed.contains("FROM-DAEMON"), viaDaemon.printed)

        for (label, result) in [("one step the dispatcher cannot honour", try await run(selectorAndSkipped)),
                                ("pacing on", try await run(honouredButSkipped, pacing: true)),
                                ("daemon not opted in", try await run(honouredButSkipped, daemon: false))] {
            XCTAssertEqual(result.sent.count, 0, "\(label): the script must not be sent to the daemon")
            XCTAssertFalse(result.printed.contains("FROM-DAEMON"), label)
        }

        // A daemon that cannot take the request (`nil`) sends the script to the local interpreter.
        let unavailable = try await run("[]", answer: nil)
        XCTAssertEqual(unavailable.sent.count, 1)
        XCTAssertEqual(unavailable.printed.trimmingCharacters(in: .whitespacesAndNewlines), "[]",
                       "the local interpreter ran the (empty) script and printed its results")
    }

    // MARK: - What the subprocess path actually launches

    private final class Launches: @unchecked Sendable {
        private let lock = NSLock(); private var items: [[String]] = []
        func add(_ a: [String]) { lock.withLock { items.append(a) } }
        var all: [[String]] { lock.withLock { items } }
    }

    func testTheSubprocessDispatchLaunchesADocumentsChildWithJSON() async throws {
        let launches = Launches()
        for (cmd, args, shared) in [("documents", [String](), ["--profile", "Work"]), ("get url", [], ["--url", "plaud"]), ("js", ["1+1"], [])] {
            _ = try await CommandDispatch.dispatch(cmd: cmd, args: args, sharedTargetArgs: shared) { _, arguments in
                launches.add(arguments); return ""
            }
        }
        XCTAssertEqual(launches.all, [["documents", "--json", "--profile", "Work"], ["get", "url", "--url", "plaud"], ["js", "1+1"]])
    }

    func testAScriptGoesToTheDaemonOnlyWhenEveryStepIsHonoured() throws {
        let honoured = try ScriptInterpreter.parseScript(
            source: #"[{"cmd":"get url"},{"cmd":"js","args":["1+1"]}]"#, maxSteps: 10)
        XCTAssertTrue(ExecCommand.allStepsRunInProcess(honoured))
        let one = try ScriptInterpreter.parseScript(
            source: ##"[{"cmd":"get url"},{"cmd":"get text","args":["#sel"]}]"##, maxSteps: 10)
        XCTAssertFalse(ExecCommand.allStepsRunInProcess(one), "one step the dispatcher cannot honour sends the whole script to the subprocess path")
    }

    /// The dispatcher enforces the same list itself, before it resolves anything, for a client that
    /// did not pre-flight.
    func testTheDispatcherRefusesAShapeItDoesNotHonourBeforeResolvingAnything() async {
        let fake = FakeSafari()
        let dispatcher = InProcessStepDispatcher()
        for (cmd, args) in [("get text", ["#sel"]), ("js", ["--file", "x.js"]), ("get url", ["stray"]), ("documents", ["stray"])] {
            do {
                _ = try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                    try await dispatcher.dispatch(cmd: cmd, args: args, sharedTargetArgs: ["--url", "w1.example/53"])
                }
                XCTFail("\(cmd) \(args) should not run in-process")
            } catch ScriptDispatchError.unsupportedArguments {
            } catch {
                XCTFail("\(cmd) \(args): expected unsupportedArguments, got \(error)")
            }
        }
        XCTAssertEqual(fake.scripts.count, 0, "nothing was resolved or sent:\n\(fake.scripts.joined(separator: "\n---\n"))")
    }

    // MARK: - The subprocess path: `documents` is JSON, as it is in-process

    func testTheSubprocessPathAsksForJSONFromADocumentsStep() {
        XCTAssertEqual(CommandDispatch.invocation(cmd: "documents", args: [], sharedTargetArgs: []), ["documents", "--json"])
        XCTAssertEqual(CommandDispatch.invocation(cmd: "documents", args: ["--profile", "Work"], sharedTargetArgs: []),
                       ["documents", "--profile", "Work", "--json"])
        XCTAssertEqual(CommandDispatch.invocation(cmd: "documents", args: ["--json"], sharedTargetArgs: []), ["documents", "--json"],
                       "not added twice")
        // Other commands are untouched, and shared target flags are still added when the step has none.
        XCTAssertEqual(CommandDispatch.invocation(cmd: "get url", args: [], sharedTargetArgs: ["--url", "plaud"]),
                       ["get", "url", "--url", "plaud"])
        XCTAssertEqual(CommandDispatch.invocation(cmd: "get url", args: ["--window", "2"], sharedTargetArgs: ["--url", "plaud"]),
                       ["get", "url", "--window", "2"])
        XCTAssertEqual(CommandDispatch.invocation(cmd: "js", args: ["1+1"], sharedTargetArgs: []), ["js", "1+1"])
        // The command is split the way `dispatch` splits it, so a stray space does not lose the flag.
        XCTAssertEqual(CommandDispatch.invocation(cmd: "documents ", args: [], sharedTargetArgs: []), ["documents", "--json"])
        XCTAssertEqual(CommandDispatch.invocation(cmd: " documents", args: [], sharedTargetArgs: []), ["documents", "--json"])
    }

    // MARK: - Differential: the same fake Safari through the dispatcher and through the CLI command

    /// Runs `body` with stdout redirected to a file and returns what was written.
    private func printed(_ body: () async throws -> Void) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stdout-\(UUID().uuidString)")
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd); try? FileManager.default.removeItem(at: url) }
        fflush(nil)
        let saved = dup(STDOUT_FILENO)
        defer { close(saved) }
        dup2(fd, STDOUT_FILENO)
        var failure: Error?
        do { try await body() } catch { failure = error }
        fflush(nil)
        dup2(saved, STDOUT_FILENO)
        if let failure { throw failure }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Both paths ask for a dialog observation, which is a live Accessibility scan of whatever
    /// Safari the developer has open unless it is provided; the answer is fixed here, so the
    /// comparison depends on the fake alone and the test does not look at the real Safari.
    private func withFake<T>(_ fake: FakeSafari, _ body: () async throws -> T) async throws -> T {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        return try await DaemonRequestContext.$current.withValue(context) {
            try await WindowDialogObservation.$provider.withValue({ WindowDialogObservation.unavailable(reason: "test") }) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) { try await body() }
            }
        }
    }

    /// The claim behind "`documents` returns the same rows on both paths": one fake Safari, one
    /// step through the dispatcher and the CLI command a child would run (`documents --json`),
    /// compared as text. Also the empty listing and a profile filter.
    func testADocumentsStepReturnsWhatTheChildCommandPrints() async throws {
        for args in [[String](), ["--profile", "個人"], ["--profile", "NoSuchProfile"]] {
            let fake = FakeSafari()
            let inProcess = try await withFake(fake) {
                try await InProcessStepDispatcher().dispatch(cmd: "documents", args: args, sharedTargetArgs: [])
            }
            let cli = try await withFake(fake) {
                try await printed { try await DocumentsCommand.parse(args + ["--json"]).run() }
            }
            XCTAssertEqual(inProcess.trimmingCharacters(in: .whitespacesAndNewlines),
                           cli.trimmingCharacters(in: .whitespacesAndNewlines), "documents \(args)")
        }
        // The empty listing is `[]` on both paths, not an empty string on one of them.
        let empty = try await withFake(FakeSafari()) {
            try await InProcessStepDispatcher().dispatch(cmd: "documents", args: ["--profile", "NoSuchProfile"], sharedTargetArgs: [])
        }
        XCTAssertEqual(empty, "[]")
    }

    /// `get text` with no selector: the dispatcher's result equals what `GetText` prints, for a page
    /// with native text and for one whose native text is empty.
    func testAGetTextStepReturnsWhatTheChildCommandPrints() async throws {
        for native in ["native words", ""] {
            let answer: @Sendable (String) -> String = { source in
                if source.contains("get text of") { return native }
                if source.contains("window.__sbResultLen") && !source.contains("window.__sbResult =") { return "5.0" }
                if source.contains("window.__sbResult.substring(") { return "inner" }
                return ""
            }
            let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            func viaRunner<T>(_ body: () async throws -> T) async throws -> T {
                try await DaemonRequestContext.$current.withValue(context) {
                    try await DaemonRequestContext.$appleScriptRunner.withValue({ answer($0) }) { try await body() }
                }
            }
            let inProcess = try await viaRunner { try await InProcessStepDispatcher().dispatch(cmd: "get text", args: [], sharedTargetArgs: []) }
            let cli = try await viaRunner { try await printed { try await GetText.parse([]).run() } }
            XCTAssertEqual(inProcess, cli.trimmingCharacters(in: .newlines), "native text \"\(native)\"")
        }
    }

    // MARK: - `get text` in-process falls back to the page's innerText, as the CLI does

    private func runGetText(nativeText: String, on script: @escaping @Sendable (String) -> String?) async throws -> (String, [String]) {
        final class Log: @unchecked Sendable {
            let lock = NSLock(); private var items: [String] = []
            func add(_ s: String) { lock.withLock { items.append(s) } }
            var all: [String] { lock.withLock { items } }
        }
        let log = Log()
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let result = try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                log.add(source)
                if source.contains("get text of") { return nativeText }
                return script(source) ?? ""
            }) {
                try await InProcessStepDispatcher().dispatch(cmd: "get text", args: [], sharedTargetArgs: [])
            }
        }
        return (result, log.all)
    }

    func testAnEmptyNativeTextFallsBackToInnerTextLikeTheCLI() async throws {
        let (text, scripts) = try await runGetText(nativeText: "") { source in
            if source.contains("window.__sbResultLen") && !source.contains("window.__sbResult =") { return "5.0" }
            if source.contains("window.__sbResult.substring(") { return "hello" }
            return ""
        }
        XCTAssertEqual(text, "hello")
        XCTAssertTrue(scripts.contains { $0.contains("document.body.innerText") }, scripts.joined(separator: "\n---\n"))
    }

    func testANonEmptyNativeTextIsReturnedWithoutTheFallback() async throws {
        let (text, scripts) = try await runGetText(nativeText: "native words") { _ in nil }
        XCTAssertEqual(text, "native words")
        XCTAssertFalse(scripts.contains { $0.contains("document.body.innerText") }, scripts.joined(separator: "\n---\n"))
    }

    // MARK: - `get text --first-match` is honoured by the CLI command

    private func runGetTextCommand(_ args: [String], on fake: FakeSafari) async throws {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let command = try GetText.parse(args)
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                try await command.run()
            }
        }
    }

    /// `GetText` never handed `--first-match` to the bridge, so an ambiguous target threw even
    /// though the flag was given — unlike `get value|attr|count|box`.
    func testGetTextHonoursFirstMatchAndResolvesOnce() async throws {
        let fake = FakeSafari()
        do {
            try await runGetTextCommand(["--url", "w1.example"], on: fake)
            XCTFail("an ambiguous --url must fail without --first-match")
        } catch SafariBrowserError.ambiguousWindowMatch {
        }
        let second = FakeSafari()
        try await runGetTextCommand(["--url", "w1.example", "--first-match"], on: second)
        XCTAssertEqual(second.enumerations, 1, "one resolution for the whole command:\n\(second.scripts.joined(separator: "\n---\n"))")
    }
}
