import Foundation
import XCTest

@testable import SafariBrowser

final class WindowDialogObservationTests: XCTestCase {
    private func snapshot(_ provider: DialogTreeScannerTests.Provider) -> DialogTreeSnapshot<Int> {
        DialogTreeScanner<DialogTreeScannerTests.Provider>().scan(provider: provider, deadline: .now() + 0.7)
    }

    func testCompleteSnapshotAssociatesDialogsWithStableWindowID() {
        var provider = DialogTreeScannerTests.dialog
        provider.nodes[1]!.id = 72
        provider.roots.insert(8, at: 0)
        provider.nodes[8] = .init(role: "AXWindow", id: 71)
        let captured = snapshot(provider)
        let observation = WindowDialogObservation(snapshot: captured)
        XCTAssertEqual(captured.observedWindowIDs, [71, 72])
        XCTAssertEqual(observation.status(for: 71).state, .clear)
        XCTAssertEqual(observation.status(for: 72).state, .present)
        XCTAssertEqual(observation.status(for: 72).messages, ["Source Body"])
        XCTAssertEqual(observation.scanResult, captured.scanResult)
    }

    func testUnknownIdentityCannotBorrowAnotherWindowsClearResult() {
        let observation = WindowDialogObservation(snapshot: snapshot(.init()))
        for id: Int? in [nil, 0, -1] {
            let status = observation.status(for: id)
            XCTAssertEqual(status.state, .unknown)
            XCTAssertEqual(status.reason, "missingID")
            XCTAssertEqual(status.messages, [])
        }
        let missing = observation.status(for: 99)
        XCTAssertEqual(missing.state, .unknown)
        XCTAssertEqual(missing.reason, "notobserved")
        XCTAssertEqual(missing.windowID, 99)
    }

    func testIncompleteSnapshotSuppressesAllPartialDetailsAndPreservesManyVerdict() {
        var provider = DialogTreeScannerTests.dialog
        provider.nodes[4]!.subrole = "AXDialog"
        let captured = snapshot(provider)
        XCTAssertEqual(captured.scanResult, .many(messages: ["Source", ""]))
        let observation = WindowDialogObservation(snapshot: captured)
        XCTAssertEqual(observation.scanResult, captured.scanResult)
        let status = observation.status(for: 42)
        XCTAssertEqual(status.state, .unknown)
        XCTAssertEqual(status.reason, "incomplete")
        XCTAssertEqual(status.messages, [])
    }

    func testDuplicateOrInvalidWindowIDsNeverAuthorizeAStatus() {
        for provider in [DialogTreeScannerTests.Provider(roots: [1, 1]),
                         .init(nodes: [1: .init(role: "AXWindow", id: 0)])] {
            let captured = snapshot(provider)
            XCTAssertFalse(captured.observedWindowIDs.contains(0))
            XCTAssertEqual(WindowDialogObservation(snapshot: captured).status(for: 42).state, .unknown)
        }
    }

    func testGlobalObserveUsesSameLegacyVerdictsAndExplicitFailureReasons() {
        let clear = GlobalDialogProbe { DialogTreeScannerTests.Provider() }.observe()
        XCTAssertEqual(clear.scanResult, .none)
        XCTAssertEqual(clear.status(for: 42).state, .clear)
        let denied = GlobalDialogProbe { DialogTreeScannerTests.Provider(deny: true) }.observe()
        XCTAssertEqual(denied.scanResult, .accessibilityDenied)
        XCTAssertEqual(denied.status(for: 42).reason, "denied")
        let failed = GlobalDialogProbe { DialogTreeScannerTests.Provider(fail: "windows") }.observe()
        XCTAssertEqual(failed.scanResult, .inspectionIncomplete)
        XCTAssertEqual(failed.status(for: 42).reason, "incomplete")
    }

    func testObserveHasBoundedWaitAndSharesBusyAllowanceWithLegacyScan() {
        var provider = DialogTreeScannerTests.dialog
        provider.delayedOperation = "windows"
        provider.delay = 0.25
        let capturedProvider = provider
        let global = GlobalDialogProbe { capturedProvider }
        let start = Date()
        let result = global.observe(budget: 0.02)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.15)
        XCTAssertEqual(result.status(for: 42).reason, "incomplete")
        XCTAssertEqual(global.scan(), .inspectionIncomplete)
        for budget in [0.0, -1.0, Double.nan, Double.infinity] {
            XCTAssertEqual(global.observe(budget: budget).status(for: 42).state, .unknown)
        }
    }

    func testCaptureProviderAndDisabledRequestDoNotRequireGUIAccess() throws {
        let fixture = WindowDialogObservation(snapshot: snapshot(.init()))
        let enabled = DaemonRequestContext(environment: [:])
        let captured = DaemonRequestContext.$current.withValue(enabled) {
            WindowDialogObservation.$provider.withValue({ fixture }) {
                WindowDialogObservation.capture()
            }
        }
        XCTAssertEqual(captured.status(for: 42).state, .clear)
        try enabled.configureDialogProbe(.init(environment: [BlockingDialogGate.optOutVariable: "1"]))
        XCTAssertTrue(enabled.dialogProbeDisabled)
        let disabled = DaemonRequestContext.$current.withValue(enabled) {
            WindowDialogObservation.$provider.withValue({
                XCTFail("an opted-out request must never run the provider")
                return fixture
            }) {
                WindowDialogObservation.capture()
            }
        }
        XCTAssertEqual(disabled.status(for: 42).reason, "disabled")
        XCTAssertEqual(disabled.status(for: 42).state, .unknown)
    }

    func testCaptureRejectsLockedAndUnavailableSessionsBeforeLiveProbe() {
        for (session, reason, scan): (GUISession, String, SafariBridge.DialogScan) in [
            (.init { ["CGSSessionScreenIsLocked": true] }, "locked", .sessionLocked),
            (.init { nil }, "unavailable", .sessionUnavailable),
        ] {
            let observation = WindowDialogObservation.capture(session: session)
            XCTAssertEqual(observation.status(for: 42).reason, reason)
            XCTAssertEqual(observation.scanResult, scan)
        }
    }

    func testJSONKeepsRawMessagesAndExplicitNullsWhileTextIsBoundedAndEscaped() throws {
        let raw = "a\t\n\u{1B}\"\\" + String(repeating: "測", count: 400)
        let captured = CapturedDialog(windowID: 42, element: 1,
                                      dialog: SafariBridge.BlockingDialog(message: raw, buttons: []),
                                      buttons: [(element: Int, title: String)]())
        let observation = WindowDialogObservation(snapshot: DialogTreeSnapshot(
            candidates: [captured], observedWindowIDs: [42, 99]))
        let status = observation.status(for: 42)
        XCTAssertEqual(status.jsonObject["messages"] as? [String], [raw])
        XCTAssertEqual(status.jsonObject["state"] as? String, "present")
        XCTAssertEqual(status.jsonObject["window_id"] as? Int, 42)
        XCTAssertTrue(status.jsonObject["reason"] is NSNull)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: status.jsonObject))
        let text = try XCTUnwrap(status.textSuffix)
        XCTAssertTrue(text.contains(TerminalText.truncationMarker))
        XCTAssertLessThanOrEqual(text.unicodeScalars.count, TerminalText.dialogFieldLimit + 20)
        for control in ["\n", "\t", "\u{1B}"] { XCTAssertFalse(text.contains(control)) }
        XCTAssertNil(observation.status(for: 99).textSuffix)
        let missing = observation.status(for: nil)
        XCTAssertTrue(missing.jsonObject["window_id"] is NSNull)
        XCTAssertTrue(try XCTUnwrap(missing.textSuffix).contains("unknown"))
    }

    func testMultipleMessagesUseCountAndEmptyMessagesStayExplicit() {
        let captured = CapturedDialog(windowID: 42, element: 1,
                                      dialog: SafariBridge.BlockingDialog(message: "", buttons: []),
                                      buttons: [(element: Int, title: String)]())
        let single = WindowDialogObservation(snapshot: DialogTreeSnapshot(candidates: [captured], observedWindowIDs: [42]))
        XCTAssertEqual(single.status(for: 42).textSuffix, "[dialog: (no readable message)]")
        let multiple = WindowDialogObservation(snapshot: DialogTreeSnapshot(
            candidates: [captured, captured], observedWindowIDs: [42]))
        XCTAssertEqual(multiple.status(for: 42).messages, ["", ""])
        XCTAssertEqual(multiple.status(for: 42).textSuffix, "[dialogs: 2]")
    }
    func testExplicitRequestEnableOverridesDisabledDaemonEnvironment() throws {
        let context = DaemonRequestContext(environment: [BlockingDialogGate.optOutVariable: "1"])
        try context.configureDialogProbe(DialogProbeOptions(environment: [:]))
        let observed = DaemonRequestContext.$current.withValue(context) {
            WindowDialogObservation.$provider.withValue({ .unavailable(reason: "provider-called") }) {
                WindowDialogObservation.capture(session: .init { [:] },
                    environment: [BlockingDialogGate.optOutVariable: "1"])
            }
        }
        XCTAssertEqual(observed.status(for: 71).reason, "provider-called")
    }

}
