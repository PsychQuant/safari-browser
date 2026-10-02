import Foundation
import XCTest
@testable import SafariBrowser

/// #219: a script with one step that was not in-process used to send the whole script to a child
/// process per step. `click`, `fill`, `type`, `press` and the `storage` subcommands are one JavaScript
/// call whose script and result handling the CLI command shares with the dispatcher (`perform`,
/// `StorageScripts`); they now run in-process, for the closed list of argument shapes below. These tests
/// hold the two paths together: the JavaScript a step sends is the one the CLI command sends, and so is
/// what it returns and how it fails.
final class ExecMoreStepsInProcessTests: XCTestCase, @unchecked Sendable {
    typealias Fake = ExecSharedTargetTests.Fake

    // MARK: - The closed list of shapes

    private let targetArgs = ["--window", "1", "--tab-in-window", "2"]

    func testEveryShapeOfTheNewStepsIsAcceptedWithAndWithoutATargetFlag() {
        let cases: [(String, [String])] = [
            ("click", ["#go"]), ("click", ["@e3"]),
            ("fill", ["#q", "hello"]), ("fill", ["#q", ""]),
            ("type", ["#q", "abc"]),
            ("press", ["Enter"]), ("press", ["Shift+Tab"]),
            ("storage local get", ["k"]), ("storage session get", ["k"]),
            ("storage local remove", ["k"]), ("storage session remove", ["k"]),
            ("storage local set", ["k", "v"]), ("storage session set", ["k", "v"]),
            ("storage local clear", []), ("storage session clear", []),
        ]
        for (cmd, args) in cases {
            XCTAssertTrue(InProcessStepDispatcher.runsInProcess(cmd: cmd, args: args), "\(cmd) \(args)")
            XCTAssertTrue(InProcessStepDispatcher.runsInProcess(cmd: cmd, args: args + ["--url", "plaud"]), "\(cmd) \(args) --url")
            XCTAssertTrue(InProcessStepDispatcher.runsInProcess(cmd: cmd, args: args + targetArgs), "\(cmd) \(args) window/tab")
        }
    }

    /// Each of these is read differently by the CLI command's parser, or has no step to run: a child
    /// process runs it, and so does the rest of the script.
    func testShapesTheCLIWouldReadDifferentlyAreNotRunInProcess() {
        let cases: [(String, [String], String)] = [
            ("click", [], "no selector"),
            ("click", ["#a", "#b"], "a stray positional"),
            ("click", ["-x"], "a selector that starts like an option"),
            ("click", ["#a", "--mark-tab"], "a flag the dispatcher does not read"),
            ("click", ["#a", "--first-match"], "step-level --first-match with no target flag"),
            ("fill", ["#a"], "no text"),
            ("fill", ["#a", "-5"], "text that starts like an option"),
            ("fill", ["-a", "x"], "a selector that starts like an option"),
            ("fill", ["#a", "x", "y"], "a stray positional"),
            ("type", [], "no arguments"),
            ("type", ["#a", "-v"], "text that starts like an option"),
            ("press", [], "no key"),
            ("press", ["-"], "a key that starts like an option"),
            ("press", ["Enter", "Tab"], "a stray positional"),
            ("storage local get", [], "no key"),
            ("storage local get", ["k", "extra"], "a stray positional"),
            ("storage local set", ["k"], "no value"),
            ("storage session set", ["k", "-v"], "a value that starts like an option"),
            ("storage session remove", ["-k"], "a key that starts like an option"),
            ("storage local clear", ["k"], "clear takes no argument"),
            ("storage local", [], "not a runnable subcommand"),
            ("storage", ["local", "get", "k"], "the subcommand belongs in the command, not the arguments"),
            // Still run as child processes, whatever the arguments.
            ("wait", [], "a polling loop with its own timeout"),
            ("wait", ["--for-url", "x"], "a polling loop with its own timeout"),
            ("snapshot", [], "chunked reads and options"),
            ("screenshot", [], "unsupported in exec"),
        ]
        for (cmd, args, why) in cases {
            XCTAssertFalse(InProcessStepDispatcher.runsInProcess(cmd: cmd, args: args), "\(cmd) \(args): \(why)")
        }
    }

    /// The client sends a script to the daemon only when every step runs in-process: one `wait` or
    /// `snapshot` keeps the whole script on the subprocess path, as before.
    func testAScriptOfTheNewStepsGoesToTheDaemonAndOneWaitKeepsItOff() throws {
        func steps(_ json: String) throws -> [ScriptStep] { try ScriptInterpreter.parseScript(source: json, maxSteps: 50) }
        let inProcess = try steps("""
            [{"cmd":"click","args":["#go"]},{"cmd":"fill","args":["#q","hi"]},{"cmd":"press","args":["Enter"]},
             {"cmd":"storage local get","args":["k"]},{"cmd":"js","args":["1+1"]},{"cmd":"get url"}]
            """)
        XCTAssertTrue(ExecCommand.allStepsRunInProcess(inProcess))
        let withWait = try steps(##"[{"cmd":"click","args":["#go"]},{"cmd":"wait","args":["--for-url","x"]}]"##)
        XCTAssertFalse(ExecCommand.allStepsRunInProcess(withWait))
        let withSnapshot = try steps(##"[{"cmd":"snapshot"},{"cmd":"click","args":["#go"]}]"##)
        XCTAssertFalse(ExecCommand.allStepsRunInProcess(withSnapshot))
        // A variable reference at the start of an argument has no shape until it runs (#220).
        let withVariable = try steps(##"[{"cmd":"get url","var":"u"},{"cmd":"fill","args":["#q","$u"]},{"cmd":"click","args":["$sel"]}]"##)
        XCTAssertFalse(ExecCommand.allStepsRunInProcess(withVariable))
    }

    // MARK: - The same JavaScript, the same output, the same failure as the CLI command

    /// stdout of `body`, as `ExecPathParityTests` captures it.
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

    /// The fake Safari, with what `do JavaScript` answers set by the test. The dialog observation and the
    /// background-tab query are answered, so nothing here looks at the real Safari.
    private func withFake<T>(_ fake: Fake, javaScriptAnswer: String, _ body: () async throws -> T) async throws -> T {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        return try await BackgroundTabDiagnostics.$query.withValue({ _ in "" }) {
            try await DaemonRequestContext.$current.withValue(context) {
                try await WindowDialogObservation.$provider.withValue({ WindowDialogObservation.unavailable(reason: "test") }) {
                    try await DaemonRequestContext.$appleScriptRunner.withValue({ script in
                        let base = try fake.respond(script)
                        return script.contains("do JavaScript") ? javaScriptAnswer : base
                    }) { try await body() }
                }
            }
        }
    }

    /// What the step sent Safari to run: the text between `do JavaScript "` and the closing `" in`.
    private func javaScripts(_ fake: Fake) -> [String] {
        fake.scripts.compactMap { script in
            guard let start = script.range(of: "do JavaScript \""),
                  let end = script.range(of: "\" in ", options: .backwards), start.upperBound <= end.lowerBound else { return nil }
            return String(script[start.upperBound..<end.lowerBound])
        }
    }

    private func runCLI(_ cmd: String, _ args: [String]) async throws {
        switch cmd {
        case "click": try await ClickCommand.parse(args).run()
        case "fill": try await FillCommand.parse(args).run()
        case "type": try await TypeCommand.parse(args).run()
        case "press": try await PressCommand.parse(args).run()
        case "storage local get": try await StorageLocalGet.parse(args).run()
        case "storage local set": try await StorageLocalSet.parse(args).run()
        case "storage local remove": try await StorageLocalRemove.parse(args).run()
        case "storage local clear": try await StorageLocalClear.parse(args).run()
        case "storage session get": try await StorageSessionGet.parse(args).run()
        case "storage session set": try await StorageSessionSet.parse(args).run()
        case "storage session remove": try await StorageSessionRemove.parse(args).run()
        case "storage session clear": try await StorageSessionClear.parse(args).run()
        default: XCTFail("no CLI command for \(cmd)")
        }
    }

    private let differentialCases: [(cmd: String, args: [String])] = [
        ("click", ["#go"]), ("click", ["@e3"]), ("click", ["a[href=\"x\"]"]),
        ("fill", ["#q", "hello"]), ("fill", ["#q", "it's \"quoted\" \\ back\nline"]),
        ("type", ["#q", "abc"]), ("type", ["#q", "日本語 🎌"]),
        ("press", ["Enter"]), ("press", ["Shift+Tab"]), ("press", ["Control+a"]),
        ("storage local get", ["k"]), ("storage local set", ["k", "it's"]), ("storage local remove", ["k"]), ("storage local clear", []),
        ("storage session get", ["k"]), ("storage session set", ["k", "v"]), ("storage session remove", ["k"]), ("storage session clear", []),
    ]

    func testEachStepSendsTheJavaScriptTheCLICommandSendsAndReturnsWhatItPrints() async throws {
        for (cmd, args) in differentialCases {
            XCTAssertTrue(InProcessStepDispatcher.runsInProcess(cmd: cmd, args: args), "\(cmd) \(args) is a shape the dispatcher runs")
            let cliFake = Fake()
            let cliOut = try await withFake(cliFake, javaScriptAnswer: "OK") {
                try await printed { try await runCLI(cmd, args + targetArgs) }
            }
            let stepFake = Fake()
            let stepOut = try await withFake(stepFake, javaScriptAnswer: "OK") {
                try await InProcessStepDispatcher().dispatch(cmd: cmd, args: args, sharedTargetArgs: targetArgs)
            }
            XCTAssertEqual(javaScripts(stepFake), javaScripts(cliFake), "\(cmd) \(args): the JavaScript sent")
            XCTAssertEqual(javaScripts(stepFake).count, 1, "\(cmd) \(args): one JavaScript call")
            // Only `storage ... get` has a value: the CLI prints it, the step returns it.
            let expected = cmd.hasSuffix(" get") ? "OK" : ""
            XCTAssertEqual(stepOut, expected, "\(cmd) \(args): the step's value")
            XCTAssertEqual(cliOut.trimmingCharacters(in: .newlines), expected, "\(cmd) \(args): what the CLI prints")
        }
    }

    /// A `get` returns the stored value, an empty string for a missing key, as the CLI prints it.
    func testAStorageGetReturnsTheValueTheCLIPrints() async throws {
        for answer in ["stored value", ""] {
            let cliOut = try await withFake(Fake(), javaScriptAnswer: answer) {
                try await printed { try await runCLI("storage local get", ["k"] + targetArgs) }
            }
            let stepOut = try await withFake(Fake(), javaScriptAnswer: answer) {
                try await InProcessStepDispatcher().dispatch(cmd: "storage local get", args: ["k"], sharedTargetArgs: targetArgs)
            }
            XCTAssertEqual(stepOut, cliOut.trimmingCharacters(in: .newlines), "answer \"\(answer)\"")
            XCTAssertEqual(stepOut, answer)
        }
    }

    /// An element that is not there fails the same way: `elementNotFound` with the selector.
    func testAMissingElementFailsLikeTheCLICommand() async throws {
        let cases: [(String, [String])] = [("click", ["#nope"]), ("fill", ["#nope", "x"]), ("type", ["#nope", "x"])]
        for (cmd, args) in cases {
            var cliError: Error?
            do { try await withFake(Fake(), javaScriptAnswer: "NOT_FOUND") { try await runCLI(cmd, args + targetArgs) } }
            catch { cliError = error }
            var stepError: Error?
            do {
                _ = try await withFake(Fake(), javaScriptAnswer: "NOT_FOUND") {
                    try await InProcessStepDispatcher().dispatch(cmd: cmd, args: args, sharedTargetArgs: targetArgs)
                }
            } catch { stepError = error }
            guard case SafariBrowserError.elementNotFound(let selector)? = stepError else {
                XCTFail("\(cmd): expected elementNotFound, got \(String(describing: stepError))"); continue
            }
            XCTAssertEqual(selector, "#nope")
            XCTAssertEqual(String(describing: stepError), String(describing: cliError), "\(cmd): the CLI fails the same way")
        }
    }

    // MARK: - The target rules of #170 apply to the new steps

    /// A `--url` shared target is resolved once and reused after a check, for these steps as for the read
    /// steps: three steps, one enumeration, a check before the second and the third.
    func testTheSharedURLTargetIsResolvedOnceAcrossTheNewSteps() async throws {
        let fake = Fake()
        _ = try await withFake(fake, javaScriptAnswer: "OK") {
            let dispatcher = InProcessStepDispatcher()
            let shared = ["--url-exact", "https://w1.example/2"]
            _ = try await dispatcher.dispatch(cmd: "click", args: ["#go"], sharedTargetArgs: shared)
            _ = try await dispatcher.dispatch(cmd: "fill", args: ["#q", "x"], sharedTargetArgs: shared)
            _ = try await dispatcher.dispatch(cmd: "storage local get", args: ["k"], sharedTargetArgs: shared)
        }
        XCTAssertEqual(fake.enumerations, 1)
        XCTAssertEqual(fake.verifications, 2)
        XCTAssertEqual(javaScripts(fake).count, 3)
    }

    /// A step whose arguments are outside the closed list is refused before anything is resolved, with the
    /// code the spec names, as for the older steps.
    func testAShapeTheDispatcherDoesNotRunIsRefusedBeforeResolving() async throws {
        let fake = Fake()
        do {
            _ = try await withFake(fake, javaScriptAnswer: "OK") {
                try await InProcessStepDispatcher().dispatch(cmd: "fill", args: ["#q", "-5"], sharedTargetArgs: ["--url-exact", "https://w1.example/2"])
            }
            XCTFail("a text that starts like an option is not run in-process")
        } catch ScriptDispatchError.unsupportedArguments(let cmd) {
            XCTAssertEqual(cmd, "fill")
        }
        XCTAssertEqual(fake.scripts, [], "nothing was resolved or sent")
    }
}
