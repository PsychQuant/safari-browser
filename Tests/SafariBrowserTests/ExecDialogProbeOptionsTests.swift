import XCTest
import Foundation
@testable import SafariBrowser

final class ExecDialogProbeOptionsTests: XCTestCase {
    func testMalformedPresentOptionsAreRejectedBeforeAnyStep() async throws {
        let invalid: [Any] = [NSNull(), true, 1, "1", [], [:],
            ["disabled": true], ["debug": false],
            ["disabled": 1, "debug": false], ["disabled": false, "debug": 0],
            ["disabled": "1", "debug": false],
            ["disabled": false, "debug": false, "extra": true]]
        for value in invalid {
            let data = try JSONSerialization.data(withJSONObject: [
                "steps": [["cmd": "documents"]], "dialogProbe": value,
            ])
            do {
                _ = try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in
                    XCTFail("malformed options reached an executable step")
                    return ""
                }) {
                    try await DaemonDispatch.Handlers.execRunScript(paramsData: data)
                }
                XCTFail("malformed options accepted: \(value)")
            } catch let error as DaemonDispatch.ExecRunScriptError {
                XCTAssertTrue(error.description.contains("dialogProbe"))
            }
        }
    }

    func testClientEnvelopeUsesOnlyExactOneAndAlwaysSendsBothBooleans() throws {
        let command = try ExecCommand.parse([])
        for disabled in [nil, "", "0", "true", "1"] as [String?] {
            for debug in [nil, "", "0", "true", "1"] as [String?] {
                var environment = ["SECRET_TOKEN": "must-not-cross-socket"]
                environment[BlockingDialogGate.optOutVariable] = disabled
                environment[BlockingDialogGate.debugVariable] = debug
                let envelope = command.daemonEnvelope(steps: [], environment: environment)
                let data = try JSONSerialization.data(withJSONObject: envelope)
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET"))
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("must-not-cross"))
                XCTAssertEqual(envelope["dialogProbe"] as? [String: Bool],
                               ["disabled": disabled == "1", "debug": debug == "1"])
                XCTAssertEqual(Set(envelope.keys), ["steps", "targetArgs", "maxSteps", "markTab", "dialogProbe"])
            }
        }
    }

    func testExplicitOptionsOverrideDaemonEnvironmentInAllFourCombinations() async throws {
        for disabled in [false, true] {
            for debug in [false, true] {
                let context = DaemonRequestContext(probe: { _ in .clear }, environment: [
                    BlockingDialogGate.optOutVariable: disabled ? "0" : "1",
                    BlockingDialogGate.debugVariable: debug ? "0" : "1",
                ])
                let data = try JSONSerialization.data(withJSONObject: [
                    "steps": [], "dialogProbe": ["disabled": disabled, "debug": debug],
                ])
                _ = try await DaemonRequestContext.$current.withValue(context) {
                    try await DaemonDispatch.Handlers.execRunScript(paramsData: data)
                }
                XCTAssertEqual(context.gate.check(.id(17)), disabled ? .unprobed : .clear)
                XCTAssertEqual(context.diagnostics.contains { $0.contains("dialog probe:") }, !disabled && debug)
            }
        }
    }

    func testLegacyRequestKeepsDaemonDefaultsAfterExplicitOverride() async throws {
        let environment = [BlockingDialogGate.optOutVariable: "1", BlockingDialogGate.debugVariable: "0"]
        for options in [["disabled": false, "debug": true], nil] as [[String: Bool]?] {
            let context = DaemonRequestContext(probe: { _ in .clear }, environment: environment)
            var envelope: [String: Any] = ["steps": []]
            if let options { envelope["dialogProbe"] = options }
            let data = try JSONSerialization.data(withJSONObject: envelope)
            _ = try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonDispatch.Handlers.execRunScript(paramsData: data)
            }
            XCTAssertEqual(context.gate.check(.id(17)), options == nil ? .unprobed : .clear)
            XCTAssertEqual(context.diagnostics.isEmpty, options == nil)
        }
        XCTAssertNil(DaemonRequestContext.current)
    }

    func testOptionsCannotSilentlyReplaceAnAlreadyUsedGate() throws {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        _ = context.gate.check(.id(17))
        XCTAssertThrowsError(try context.configureDialogProbe(DialogProbeOptions(environment: [
            BlockingDialogGate.optOutVariable: "1",
        ])))
        XCTAssertEqual(context.gate.state(for: .id(17)), .clear)
    }

    func testDirectHandlerCreatesIsolatedContextEvenAfterStepFailure() async throws {
        final class Observations: @unchecked Sendable {
            let lock = NSLock()
            var contexts: [DaemonRequestContext] = []
            func record(_ context: DaemonRequestContext) {
                lock.lock(); defer { lock.unlock() }
                contexts.append(context)
            }
        }
        let observed = Observations()
        let data = try JSONSerialization.data(withJSONObject: [
            "steps": [["cmd": "documents"]],
            "dialogProbe": ["disabled": true, "debug": true],
        ])
        for _ in 0..<2 {
            let result = try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in
                guard let context = DaemonRequestContext.current else {
                    XCTFail("direct handler must own a request context")
                    throw SafariBrowserError.appleScriptFailed("missing context")
                }
                observed.record(context)
                XCTAssertEqual(context.gate.check(.id(17)), .unprobed)
                XCTAssertTrue(context.diagnostics.isEmpty)
                context.emit("failure warning")
                throw SafariBrowserError.appleScriptFailed("injected failure")
            }) {
                try await DaemonDispatch.Handlers.execRunScript(paramsData: data)
            }
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: String])
            let results = try XCTUnwrap(payload["results"]?.data(using: .utf8))
            let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: results) as? [[String: Any]])
            XCTAssertEqual(rows.first?["status"] as? String, "error")
            XCTAssertNil(DaemonRequestContext.current)
        }
        XCTAssertEqual(observed.contexts.count, 2)
        XCTAssertEqual(Set(observed.contexts.map(\.id)).count, 2)
        XCTAssertTrue(observed.contexts.allSatisfy { $0.diagnostics == ["failure warning"] })
    }

}
