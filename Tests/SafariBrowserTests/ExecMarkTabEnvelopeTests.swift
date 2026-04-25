import XCTest
import Foundation
@testable import SafariBrowser

/// Section 7 of `tab-ownership-marker` v2 — pure tests for the
/// `markTab` envelope field on `exec.runScript`. The handler runs the
/// entire script wrapped in `SafariBridge.markTabIfRequested(mode:)` so
/// the marker spans all steps in one request. This avoids per-step
/// toggle latency (Requirement 7.3 — marker is owned by the request,
/// not by individual steps).
///
/// Live-Safari behavior is exercised in `Tests/e2e-mark-tab.sh`; here
/// we cover envelope decoding, default mode, validation of bad values.
final class ExecMarkTabEnvelopeTests: XCTestCase {

    // MARK: - markTab field defaulting + validation

    func testExecRunScript_acceptsValidMarkTabModes() async throws {
        // Each value must be accepted: off (default), ephemeral, persist.
        for value in ["off", "ephemeral", "persist"] {
            let envelope: [String: Any] = [
                "steps": [],
                "targetArgs": [],
                "maxSteps": 100,
                "markTab": value,
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [])
            let result = try await DaemonDispatch.Handlers.execRunScript(paramsData: data)
            // Empty steps yields {"results":"[]"}.
            let parsed = try JSONSerialization.jsonObject(with: result, options: []) as? [String: Any]
            XCTAssertEqual(parsed?["results"] as? String, "[]")
        }
    }

    func testExecRunScript_defaultsToOffWhenMissing() async throws {
        // Missing markTab field → off (no title mutation).
        let envelope: [String: Any] = [
            "steps": [],
            "targetArgs": [],
            "maxSteps": 100,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [])
        let result = try await DaemonDispatch.Handlers.execRunScript(paramsData: data)
        XCTAssertGreaterThan(result.count, 0)
    }

    func testExecRunScript_rejectsInvalidMarkTabValue() async {
        let envelope: [String: Any] = [
            "steps": [],
            "targetArgs": [],
            "maxSteps": 100,
            "markTab": "always",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [])) ?? Data()
        do {
            _ = try await DaemonDispatch.Handlers.execRunScript(paramsData: data)
            XCTFail("expected malformedEnvelope for invalid markTab value")
        } catch let err as DaemonDispatch.ExecRunScriptError {
            switch err {
            case .malformedEnvelope(let reason):
                XCTAssertTrue(reason.contains("markTab"),
                              "rejection reason must mention markTab: \(reason)")
                XCTAssertTrue(reason.contains("always") || reason.contains("invalid"),
                              "rejection reason must echo bad value or mark as invalid: \(reason)")
            case .parseError:
                XCTFail("expected malformedEnvelope, got parseError: \(err)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Client-side encoding

    func testExecCommand_envelopeIncludesMarkTabFromTargetOptions() throws {
        // Bare --mark-tab should resolve to "ephemeral" and ride along
        // in the envelope. We verify by parsing args through TargetOptions
        // then checking markTabResolved().
        let target = try TargetOptions.parse(["--mark-tab"])
        XCTAssertEqual(target.markTabResolved(env: [:]), .ephemeral)
        XCTAssertEqual(target.markTabResolved(env: [:]).rawValue, "ephemeral")
    }

    func testExecCommand_envelopeMarkTabPersistRoundTrip() throws {
        let target = try TargetOptions.parse(["--mark-tab-persist"])
        XCTAssertEqual(target.markTabResolved(env: [:]), .persist)
    }

    func testExecCommand_envelopeMarkTabOffByDefault() throws {
        let target = try TargetOptions.parse([])
        XCTAssertEqual(target.markTabResolved(env: [:]), .off)
    }

    func testExecCommand_envelopeMarkTabFromEnvVar() throws {
        let target = try TargetOptions.parse([])
        XCTAssertEqual(
            target.markTabResolved(env: ["SAFARI_BROWSER_MARK_TAB": "1"]),
            .ephemeral
        )
        XCTAssertEqual(
            target.markTabResolved(env: ["SAFARI_BROWSER_MARK_TAB": "persist"]),
            .persist
        )
    }

    // MARK: - InProcessStepDispatcher v2.1 expanded supported set

    func testInProcessDispatcher_v2_1_supportsGetTextAndGetSource() {
        XCTAssertTrue(InProcessStepDispatcher.isSupported("get text"))
        XCTAssertTrue(InProcessStepDispatcher.isSupported("get source"))
    }
}
