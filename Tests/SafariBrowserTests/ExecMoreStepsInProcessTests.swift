import ArgumentParser
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
            ("press", ["Enter"]), ("press", ["Shift+Tab"]), ("press", ["Control+Shift+a"]),
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
            ("press", [""], "an empty key has no name: the CLI command reports it, a child runs it (#219)"),
            ("press", ["+"], "a key made only of `+` has no name"),
            ("press", ["++"], "a key made only of `+` has no name"),
            ("press", ["-"], "a key that starts like an option"),
            ("fill", ["#q", "--url"], "a target flag with no value is the CLI's error"),
            ("click", ["--window"], "a target flag with no value is the CLI's error"),
            ("storage local set", ["k", "--first-match"], "step-level --first-match with no target flag"),
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
    /// The key of a `press` has a name only if some character of it is not `+`, so a reference anywhere in it
    /// (`+$k` with `$k` empty) can leave it nameless after substitution: such a script runs step by step.
    func testAPressKeyWithAVariableReferenceAnywhereIsNotSentToTheDaemon() throws {
        func steps(_ json: String) throws -> [ScriptStep] { try ScriptInterpreter.parseScript(source: json, maxSteps: 50) }
        for key in ["+$k", "$k", "a$k", "$k+$k"] {
            let json = "[{\"cmd\":\"press\",\"args\":[\"\(key)\"]}]"
            XCTAssertFalse(ExecCommand.allStepsRunInProcess(try steps(json)), "press \(key)")
        }
        // A literal `\$` is not a reference; the key is `$x` after substitution.
        XCTAssertTrue(ExecCommand.allStepsRunInProcess(try steps(##"[{"cmd":"press","args":["\\$x"]}]"##)))
        XCTAssertTrue(ExecCommand.allStepsRunInProcess(try steps(##"[{"cmd":"press","args":["Enter"]}]"##)))
        // Other steps keep the old rule: only an argument that begins with a reference has no shape.
        XCTAssertTrue(ExecCommand.allStepsRunInProcess(try steps(##"[{"cmd":"fill","args":["#q","x$k"]}]"##)))
        XCTAssertFalse(ExecCommand.allStepsRunInProcess(try steps(##"[{"cmd":"fill","args":["#q","$k"]}]"##)))
    }

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
        try await withFake(fake, javaScript: { _ in javaScriptAnswer }, body)
    }

    private func withFake<T>(_ fake: Fake, javaScript answer: @escaping @Sendable (String) -> String,
                             _ body: () async throws -> T) async throws -> T {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        return try await BackgroundTabDiagnostics.$query.withValue({ _ in "" }) {
            try await DaemonRequestContext.$current.withValue(context) {
                try await WindowDialogObservation.$provider.withValue({ WindowDialogObservation.unavailable(reason: "test") }) {
                    try await DaemonRequestContext.$appleScriptRunner.withValue({ script in
                        let base = try fake.respond(script)
                        return script.contains("do JavaScript") ? answer(script) : base
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
        // A number too large for `Int` names no ref; it used to trap, which would take the daemon down.
        ("click", ["@e99999999999999999999"]),
        ("fill", ["#q", ""]), ("fill", ["#q", "hello"]), ("fill", ["#q", "it's \"quoted\" \\ back\nline"]),
        ("type", ["#q", "abc"]), ("type", ["#q", "日本語 🎌"]),
        ("press", ["Enter"]), ("press", ["Shift+Tab"]), ("press", ["Control+a"]), ("press", ["Control+Shift+a"]),
        ("storage local get", ["k"]), ("storage local set", ["k", ""]), ("storage local set", ["k", "it's"]), ("storage local remove", ["k"]), ("storage local clear", []),
        ("storage session get", ["k"]), ("storage session set", ["k", "v"]), ("storage session remove", ["k"]), ("storage session clear", []),
    ]

    func testEachStepSendsTheJavaScriptTheCLICommandSendsAndReturnsWhatItPrints() async throws {
        // `click` reads the environment for the tab marker, which would add title scripts to the CLI side only.
        try XCTSkipIf(ProcessInfo.processInfo.environment["SAFARI_BROWSER_MARK_TAB"] != nil,
                      "SAFARI_BROWSER_MARK_TAB is set: the CLI click would wrap the tab title")
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

    // MARK: - What the two ways of sending a step leave to the shared function

    /// The shared function builds the JavaScript from its own arguments; the dispatcher chooses the target, the
    /// profile and the first-match rule it passes in. These tests look at those, which the JavaScript text cannot.
    func testTheJavaScriptGoesToTheTabTheTargetNames() async throws {
        let steps: [(String, [String])] = [("click", ["#go"]), ("fill", ["#q", "x"]), ("type", ["#q", "x"]),
                                           ("press", ["Enter"]), ("storage local get", ["k"]), ("storage session clear", [])]
        for (cmd, args) in steps {
            // The exec-level target.
            let shared = Fake()
            _ = try await withFake(shared, javaScriptAnswer: "OK") {
                try await InProcessStepDispatcher().dispatch(cmd: cmd, args: args, sharedTargetArgs: targetArgs)
            }
            XCTAssertTrue(shared.scripts.contains { $0.contains("do JavaScript") && $0.contains("tab 2 of window id 101") },
                          "\(cmd): the exec-level target is window 1 tab 2\n\(shared.scripts.joined(separator: "\n---\n"))")
            // A target flag of the step's own replaces it.
            let own = Fake()
            _ = try await withFake(own, javaScriptAnswer: "OK") {
                try await InProcessStepDispatcher().dispatch(cmd: cmd, args: args + ["--window", "2", "--tab-in-window", "3"], sharedTargetArgs: targetArgs)
            }
            XCTAssertTrue(own.scripts.contains { $0.contains("do JavaScript") && $0.contains("tab 3 of window id 102") },
                          "\(cmd): the step's own target is window 2 tab 3")
            XCTAssertFalse(own.scripts.contains { $0.contains("do JavaScript") && $0.contains("window id 101") }, "\(cmd): not the exec-level one")
        }
    }

    /// `--profile` restricts the resolution (every window of the fake belongs to profile 個人).
    func testTheProfileRestrictsTheResolutionOfTheNewSteps() async throws {
        for (cmd, args) in [("click", ["#go"]), ("storage local get", ["k"])] {
            let inProfile = Fake()
            _ = try await withFake(inProfile, javaScriptAnswer: "OK") {
                try await InProcessStepDispatcher().dispatch(cmd: cmd, args: args, sharedTargetArgs: ["--url-exact", "https://w1.example/2", "--profile", "個人"])
            }
            XCTAssertTrue(inProfile.scripts.contains { $0.contains("do JavaScript") }, "\(cmd): found in its own profile")
            let elsewhere = Fake()
            do {
                _ = try await withFake(elsewhere, javaScriptAnswer: "OK") {
                    try await InProcessStepDispatcher().dispatch(cmd: cmd, args: args, sharedTargetArgs: ["--url-exact", "https://w1.example/2", "--profile", "其他"])
                }
                XCTFail("\(cmd): a window of another profile must not be found")
            } catch SafariBrowserError.documentNotFound {
            }
            XCTAssertFalse(elsewhere.scripts.contains { $0.contains("do JavaScript") }, "\(cmd): nothing was sent")
        }
    }

    /// An ambiguous `--url` fails closed for these steps as for any command; a step's own `--first-match`
    /// (with a target flag) takes the first match, and the JavaScript goes to that tab.
    func testAnAmbiguousURLFailsClosedAndFirstMatchTakesTheFirstTab() async throws {
        let ambiguous = Fake()
        do {
            _ = try await withFake(ambiguous, javaScriptAnswer: "OK") {
                try await InProcessStepDispatcher().dispatch(cmd: "click", args: ["#go"], sharedTargetArgs: ["--url", "w1.example"])
            }
            XCTFail("three tabs match: the step must not pick one")
        } catch SafariBrowserError.ambiguousWindowMatch {
        }
        XCTAssertFalse(ambiguous.scripts.contains { $0.contains("do JavaScript") }, "nothing was sent to either tab")

        let first = Fake()
        _ = try await withFake(first, javaScriptAnswer: "OK") {
            try await InProcessStepDispatcher().dispatch(cmd: "click", args: ["#go", "--url", "w1.example", "--first-match"], sharedTargetArgs: [])
        }
        XCTAssertTrue(first.scripts.contains { $0.contains("do JavaScript") && $0.contains("tab 1 of window id 101") }, "the first match")
    }

    // MARK: - Nothing the person typed can leave the string it is in

    /// The AppleScript-literal escaping `doJavaScript` applies, undone, so what Safari would run can be read.
    private func unescapedAppleScript(_ text: String) -> String {
        var out = "", escaped = false
        for ch in text {
            if escaped { out.append(ch); escaped = false } else if ch == "\\" { escaped = true } else { out.append(ch) }
        }
        return out
    }

    /// The expected JavaScript is written out by hand here, not built by the code under test, so dropping an
    /// escape from a shared builder fails: the argument is `it's "quoted" \ back` and a newline.
    func testTypedTextIsEscapedIntoItsJavaScriptStringLiteral() async throws {
        let text = "it's \"quoted\" \\ back\nline"
        let js = "'it\\'s \"quoted\" \\\\ back\\nline'"
        let cases: [(String, [String], String)] = [
            ("fill", ["#q", text], "el.value = \(js);"),
            ("type", ["#q", text], "el.value += \(js);"),
            ("storage local set", ["k", text], "localStorage.setItem('k', \(js))"),
            ("storage session set", ["k", text], "sessionStorage.setItem('k', \(js))"),
            ("storage local get", [text], "localStorage.getItem(\(js)) || ''"),
            ("storage session remove", [text], "sessionStorage.removeItem(\(js))"),
        ]
        for (cmd, args, expected) in cases {
            let fake = Fake()
            _ = try await withFake(fake, javaScriptAnswer: "OK") {
                try await InProcessStepDispatcher().dispatch(cmd: cmd, args: args, sharedTargetArgs: targetArgs)
            }
            let sent = javaScripts(fake).map(unescapedAppleScript)
            XCTAssertEqual(sent.count, 1, cmd)
            XCTAssertTrue(sent[0].contains(expected), "\(cmd): expected\n\(expected)\nin\n\(sent[0])")
        }
    }

    /// A quote, a backslash or a double quote followed by a combining mark is one `Character` that is not
    /// equal to the quote, and Foundation's `replacingOccurrences` skips it unless it is asked to be literal:
    /// the character is left unescaped and ends the string early. The helpers are literal.
    func testTheEscapingHelpersAreLiteralAfterACombiningMark() {
        let mark = "\u{301}"
        XCTAssertEqual("x'\(mark)y".escapedForJS, "x\\'\(mark)y")
        XCTAssertEqual("x\\\(mark)y".escapedForJS, "x\\\\\(mark)y")
        XCTAssertEqual("x\"\(mark)y".escapedForAppleScript, "x\\\"\(mark)y")
        XCTAssertEqual("x\\\(mark)y".escapedForAppleScript, "x\\\\\(mark)y")
        XCTAssertEqual("x\"\(mark)y".jsStringLiteral, "\"x\\\"\(mark)y\"")
        // The other characters the JavaScript helper handles, in one string.
        XCTAssertEqual("a\r\0\u{2028}\u{2029}b".escapedForJS, "a\\r\\0\\u2028\\u2029b")
    }

    func testTypedTextWithACombiningMarkAfterAQuoteReachesSafariEscaped() async throws {
        let fake = Fake()
        _ = try await withFake(fake, javaScriptAnswer: "OK") {
            try await InProcessStepDispatcher().dispatch(cmd: "fill", args: ["#q", "x'\u{301};alert(1);//"], sharedTargetArgs: targetArgs)
        }
        let sent = javaScripts(fake).map(unescapedAppleScript)
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].contains("el.value = 'x\\'\u{301};alert(1);//';"), sent[0])
    }

    // MARK: - Nothing here may bring the daemon down

    /// A key with no name used to trap on a force-unwrap; in the daemon that is the whole process.
    func testAKeyWithNoNameIsAnErrorNotACrash() async throws {
        for key in ["", "+", "++"] {
            do {
                try await withFake(Fake(), javaScriptAnswer: "OK") {
                    try await PressCommand.perform(key: key, target: .frontWindow, firstMatch: false, warnWriter: nil, profile: nil)
                }
                XCTFail("press \"\(key)\" must fail")
            } catch is ValidationError {
            }
            // And the dispatcher does not run it: a child process reports the CLI command's own error.
            do {
                _ = try await withFake(Fake(), javaScriptAnswer: "OK") {
                    try await InProcessStepDispatcher().dispatch(cmd: "press", args: [key], sharedTargetArgs: [])
                }
                XCTFail("press \"\(key)\" is not a shape the dispatcher runs")
            } catch ScriptDispatchError.unsupportedArguments {
            }
        }
    }

    func testARefTooLargeForIntNamesNothingInsteadOfTrapping() async throws {
        let fake = Fake()
        do {
            _ = try await withFake(fake, javaScriptAnswer: "NOT_FOUND") {
                try await InProcessStepDispatcher().dispatch(cmd: "click", args: ["@e99999999999999999999"], sharedTargetArgs: targetArgs)
            }
            XCTFail("no such ref")
        } catch SafariBrowserError.elementNotFound(let selector) {
            XCTAssertEqual(selector, "@e99999999999999999999")
        }
        XCTAssertTrue(javaScripts(fake).first?.contains("__sbRefs[9223372036854775806]") == true, "an index past the end, not a crash")
    }

    // MARK: - Inside a script: variables, conditions, errors and the route

    /// `var`, `if:` and `onError` work for the new steps as for the others, through the real interpreter.
    func testTheNewStepsWorkWithVariablesConditionsAndOnError() async throws {
        let steps = try ScriptInterpreter.parseScript(source: ##"""
            [{"cmd":"storage local get","args":["k"],"var":"v"},
             {"cmd":"click","args":["#nope"],"onError":"continue"},
             {"cmd":"storage local get","args":["k"],"if":"$v equals \"stored\"","var":"w"},
             {"cmd":"fill","args":["#q","$w"]}]
            """##, maxSteps: 50)
        XCTAssertTrue(ExecCommand.allStepsRunInProcess(Array(steps.prefix(3))), "the first three are runnable shapes")
        let results = try await withFake(Fake(), javaScript: { $0.contains("localStorage.getItem") ? "stored" : "NOT_FOUND" }) {
            try await ScriptInterpreter(dispatcher: InProcessStepDispatcher()).runSteps(steps, target: try TargetOptions.parse(targetArgs))
        }
        XCTAssertEqual(results.map(\.status), [.ok, .error, .ok, .error])
        XCTAssertEqual(results[0].value, "stored")
        XCTAssertEqual(results[0].varName, "v")
        XCTAssertEqual(results[1].errorCode, "elementNotFound")
        XCTAssertEqual(results[2].value, "stored", "the condition on $v held")
        // The last step fills `#q`, which is not there in this fake: the run reports it, nothing is lost earlier.
        XCTAssertEqual(results[3].errorCode, "elementNotFound")
    }

    /// The route `ExecCommand` takes: a script of the new steps goes to the daemon, one with a `wait` does not.
    func testExecSendsAScriptOfTheNewStepsToTheDaemonAndKeepsAWaitLocal() async throws {
        final class Sent: @unchecked Sendable {
            private let lock = NSLock(); private var items: [[String]] = []
            func add(_ steps: [ScriptStep]) { lock.withLock { items.append(steps.map(\.cmd)) } }
            var all: [[String]] { lock.withLock { items } }
        }
        func route(_ source: String, pacing: Bool = false) async throws -> [[String]] {
            let sent = Sent()
            _ = try await printed {
                try await ExecCommand.parse([]).execute(source: source, pacingEnabled: pacing, daemonOptedIn: true) { steps in
                    sent.add(steps); return "[]"
                }
            }
            return sent.all
        }
        // Guarded by an `if` that is false, so a local run touches nothing in Safari.
        let never = #""if":"$never exists""#
        let runnable = "[{\"cmd\":\"click\",\"args\":[\"#go\"],\(never)},{\"cmd\":\"storage local set\",\"args\":[\"k\",\"v\"],\(never)}]"
        let sentRunnable = try await route(runnable)
        XCTAssertEqual(sentRunnable, [["click", "storage local set"]])
        let withWait = "[{\"cmd\":\"click\",\"args\":[\"#go\"],\(never)},{\"cmd\":\"wait\",\"args\":[\"--for-url\",\"x\"],\(never)}]"
        let sentWait = try await route(withWait)
        XCTAssertEqual(sentWait, [], "one wait keeps the whole script off the daemon")
        let sentPaced = try await route(runnable, pacing: true)
        XCTAssertEqual(sentPaced, [], "pacing on runs step by step")
    }
}
