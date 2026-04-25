import XCTest
import Foundation
@testable import SafariBrowser

/// Section 10 v2 of `script-exec-command` — pure tests for the
/// `exec.runScript` daemon path. Live-Safari wired tests would require
/// a running browser; here we cover (a) the in-process dispatcher's
/// support set, (b) round-trip through `ScriptStep.toDictionary()`, (c)
/// the envelope decoding contract that the daemon handler accepts.
final class ExecDaemonRouterTests: XCTestCase {

    // MARK: - InProcessStepDispatcher.isSupported

    func testInProcessDispatcher_supportsCoreReadCommands() {
        XCTAssertTrue(InProcessStepDispatcher.isSupported("js"))
        XCTAssertTrue(InProcessStepDispatcher.isSupported("get url"))
        XCTAssertTrue(InProcessStepDispatcher.isSupported("get title"))
        XCTAssertTrue(InProcessStepDispatcher.isSupported("documents"))
    }

    func testInProcessDispatcher_doesNotSupportV2DeferredCommands() {
        // v2.1 added pure-read `get text` / `get source`; the mutating
        // and stateful commands below stay subprocess until a future
        // iteration covers them.
        XCTAssertFalse(InProcessStepDispatcher.isSupported("click"))
        XCTAssertFalse(InProcessStepDispatcher.isSupported("fill"))
        XCTAssertFalse(InProcessStepDispatcher.isSupported("type"))
        XCTAssertFalse(InProcessStepDispatcher.isSupported("press"))
        XCTAssertFalse(InProcessStepDispatcher.isSupported("wait"))
        XCTAssertFalse(InProcessStepDispatcher.isSupported("snapshot"))
        XCTAssertFalse(InProcessStepDispatcher.isSupported("storage local get"))
    }

    func testInProcessDispatcher_unsupportedThrowsUnsupportedInExec() async {
        let dispatcher = InProcessStepDispatcher()
        do {
            _ = try await dispatcher.dispatch(cmd: "click", args: [".btn"], sharedTargetArgs: [])
            XCTFail("expected unsupportedInExec for unsupported command")
        } catch let err as ScriptDispatchError {
            XCTAssertEqual(err.code, "unsupportedInExec")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Target argument extraction / stripping

    func testExtractTargetArgs_pullsFlagPairs() {
        let raw = ["--url", "plaud", "selector", "--first-match", "--unrelated", "x"]
        let extracted = InProcessStepDispatcher.extractTargetArgs(raw)
        XCTAssertEqual(extracted, ["--url", "plaud", "--first-match"])
    }

    func testStripTargetFlags_removesFlagPairs() {
        let raw = ["--url", "plaud", "selector", "--first-match", "--unrelated", "x"]
        let stripped = InProcessStepDispatcher.stripTargetFlags(raw)
        XCTAssertEqual(stripped, ["selector", "--unrelated", "x"])
    }

    func testStripTargetFlags_emptyArgsRoundTrip() {
        XCTAssertEqual(InProcessStepDispatcher.stripTargetFlags([]), [])
        XCTAssertEqual(InProcessStepDispatcher.extractTargetArgs([]), [])
    }

    func testParseTargetOptions_emptyProducesDefault() throws {
        let target = try InProcessStepDispatcher.parseTargetOptions(from: [])
        XCTAssertNil(target.url)
        XCTAssertNil(target.window)
        XCTAssertFalse(target.firstMatch)
    }

    func testParseTargetOptions_urlAndFirstMatch() throws {
        let target = try InProcessStepDispatcher.parseTargetOptions(
            from: ["--url", "github.com", "--first-match"]
        )
        XCTAssertEqual(target.url, "github.com")
        XCTAssertTrue(target.firstMatch)
    }

    // MARK: - ScriptStep round-trip

    func testScriptStep_toDictionaryRoundTrip() throws {
        let step = ScriptStep(
            cmd: "get url",
            args: ["--url", "github.com"],
            varName: "u",
            ifExpression: "$x exists",
            onError: .continue
        )
        let dict = step.toDictionary()
        XCTAssertEqual(dict["cmd"] as? String, "get url")
        XCTAssertEqual(dict["args"] as? [String], ["--url", "github.com"])
        XCTAssertEqual(dict["var"] as? String, "u")
        XCTAssertEqual(dict["if"] as? String, "$x exists")
        XCTAssertEqual(dict["onError"] as? String, "continue")

        // Re-encode → re-decode should reproduce the same struct.
        let data = try JSONSerialization.data(withJSONObject: [dict], options: [])
        let json = String(data: data, encoding: .utf8) ?? "[]"
        let parsed = try ScriptInterpreter.parseScript(source: json, maxSteps: 100)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].cmd, "get url")
        XCTAssertEqual(parsed[0].args, ["--url", "github.com"])
        XCTAssertEqual(parsed[0].varName, "u")
    }

    func testScriptStep_toDictionaryOmitsOptionals() {
        let step = ScriptStep(cmd: "documents", args: [])
        let dict = step.toDictionary()
        XCTAssertNil(dict["var"])
        XCTAssertNil(dict["if"])
        XCTAssertEqual(dict["cmd"] as? String, "documents")
        XCTAssertEqual(dict["onError"] as? String, "abort")
    }

    // MARK: - ScriptInterpreter dispatcher injection

    /// Confirms the refactor preserved behavior: the default dispatcher
    /// is the subprocess one. Pure check via type identity.
    func testScriptInterpreter_defaultDispatcherIsSubprocess() {
        let interpreter = ScriptInterpreter()
        XCTAssertTrue(type(of: interpreter.dispatcher) == SubprocessStepDispatcher.self)
    }

    func testScriptInterpreter_acceptsCustomDispatcher() async throws {
        // A trivial dispatcher that returns the cmd name as the result.
        struct EchoDispatcher: StepDispatcher {
            func dispatch(cmd: String, args: [String], sharedTargetArgs: [String]) async throws -> String {
                return cmd
            }
        }
        let interpreter = ScriptInterpreter(dispatcher: EchoDispatcher())
        let source = #"[{"cmd":"documents","args":[]}]"#
        let target = try TargetOptions.parse([])
        let results = try await interpreter.run(source: source, target: target)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .ok)
        XCTAssertEqual(results[0].value, "documents")
    }

    func testScriptInterpreter_runStepsIsCallableDirectly() async throws {
        struct EchoDispatcher: StepDispatcher {
            func dispatch(cmd: String, args: [String], sharedTargetArgs: [String]) async throws -> String {
                return "\(cmd):\(args.joined(separator: ","))"
            }
        }
        let interpreter = ScriptInterpreter(dispatcher: EchoDispatcher())
        let steps = [
            ScriptStep(cmd: "documents", args: []),
            ScriptStep(cmd: "get url", args: ["--url", "x"], varName: "u"),
        ]
        let results = try await interpreter.runSteps(steps, target: try TargetOptions.parse([]))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].value, "documents:")
        XCTAssertEqual(results[1].value, "get url:--url,x")
        XCTAssertEqual(results[1].varName, "u")
    }

    // MARK: - Daemon handler envelope decoding

    func testExecRunScriptHandler_acceptsValidEnvelope() async throws {
        // Envelope shape the client sends: {steps, targetArgs, maxSteps}
        let stepArr: [[String: Any]] = [
            ["cmd": "documents", "args": [], "onError": "abort"],
        ]
        let envelope: [String: Any] = [
            "steps": stepArr,
            "targetArgs": [],
            "maxSteps": 100,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [])
        // Calling the handler directly from this test would require a
        // running Safari (documents calls SafariBridge); instead we
        // verify the decoder accepts the envelope by invoking the
        // pure pre-flight: parse steps from an envelope-shaped JSON.
        let stepsData = try JSONSerialization.data(withJSONObject: stepArr, options: [])
        let stepsJSON = String(data: stepsData, encoding: .utf8) ?? "[]"
        let parsed = try ScriptInterpreter.parseScript(source: stepsJSON, maxSteps: 100)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].cmd, "documents")
        // Also confirm the envelope serialized correctly.
        XCTAssertGreaterThan(data.count, 10)
    }

    func testExecRunScriptHandler_rejectsMissingSteps() async {
        let envelope: [String: Any] = ["targetArgs": [], "maxSteps": 100]
        let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [])) ?? Data()
        do {
            _ = try await DaemonDispatch.Handlers.execRunScript(paramsData: data)
            XCTFail("expected malformedEnvelope")
        } catch let err as DaemonDispatch.ExecRunScriptError {
            switch err {
            case .malformedEnvelope(let reason):
                XCTAssertTrue(reason.contains("steps"))
            case .parseError:
                XCTFail("expected malformedEnvelope, got parseError: \(err)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testExecRunScriptHandler_rejectsMalformedJSON() async {
        do {
            _ = try await DaemonDispatch.Handlers.execRunScript(paramsData: Data("not json".utf8))
            XCTFail("expected malformedEnvelope")
        } catch _ as DaemonDispatch.ExecRunScriptError {
            // expected
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
