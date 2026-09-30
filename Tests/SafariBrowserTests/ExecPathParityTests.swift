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
            } catch ScriptDispatchError.unsupportedInExec {
            } catch {
                XCTFail("\(cmd) \(args): expected unsupportedInExec, got \(error)")
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
    /// though the flag was given — unlike every other `get` command.
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
