import Foundation
import XCTest

@testable import SafariBrowser

final class GlobalDialogProbeTests: XCTestCase {
    func testGlobalScanUsesCompleteScannerVerdicts() {
        let clear = GlobalDialogProbe { DialogTreeScannerTests.Provider() }
        XCTAssertEqual(clear.scan(), .none)
        let blocked = GlobalDialogProbe { DialogTreeScannerTests.dialog }
        XCTAssertEqual(blocked.scan(), .one(.init(message: "Source Body", buttons: ["Cancel", "Continue"])))
        let failed = GlobalDialogProbe { DialogTreeScannerTests.Provider(fail: "windows") }
        XCTAssertEqual(failed.scan(), .inspectionIncomplete)
    }

    func testEveryBlockedGlobalReadHasABoundedCallerWait() {
        for operation in ["windows", "id", "role", "subrole", "children", "editable", "text", "title"] {
            var p = DialogTreeScannerTests.dialog
            p.delayedOperation = operation
            p.delay = 0.25
            let provider = p
            let global = GlobalDialogProbe { provider }
            let start = Date()
            XCTAssertEqual(global.scan(budget: 0.02), .inspectionIncomplete, operation)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.15, operation)
            XCTAssertEqual(global.scan(), .inspectionIncomplete, "the same in-flight worker remains busy")
        }
    }

    func testDeniedAndInvalidBudgetAreDistinctFromClear() {
        let denied = GlobalDialogProbe { DialogTreeScannerTests.Provider(deny: true) }
        XCTAssertEqual(denied.scan(), .accessibilityDenied)
        for budget in [0.0, -1.0, Double.nan, Double.infinity] {
            XCTAssertEqual(denied.scan(budget: budget), .inspectionIncomplete)
        }
    }

    func testDeadlineAndSessionAreCheckedAfterDecision() {
        let snapshot = DialogTreeScanner<DialogTreeScannerTests.Provider>().scan(
            provider: DialogTreeScannerTests.dialog, deadline: .now() + 0.7)
        var pressed = false
        let result = DialogPressExecutor.perform(
            snapshot: snapshot, deadline: .now() + 0.01, session: .init { [:] },
            decide: { _ in
                Thread.sleep(forTimeInterval: 0.02)
                return 0
            },
            press: { _, _ in
                pressed = true
                return .pressed
            })
        XCTAssertEqual(result, .inspectionIncomplete)
        XCTAssertFalse(pressed)
        let locked = DialogPressExecutor.perform(
            snapshot: snapshot, deadline: .now() + 0.7,
            session: .init { ["CGSSessionScreenIsLocked": true] },
            decide: { _ in
                XCTFail("locked session must not decide")
                return 0
            },
            press: { _, _ in
                XCTFail("locked session must not press")
                return .pressed
            })
        XCTAssertEqual(locked, .sessionLocked)
    }

    func testIncompleteAndExpiredScansNeverInvokeDecisionOrPress() {
        let complete = DialogTreeScanner<DialogTreeScannerTests.Provider>().scan(
            provider: DialogTreeScannerTests.dialog, deadline: .now() + 0.7)
        var incomplete = complete
        incomplete.isComplete = false
        for (snapshot, deadline) in [(incomplete, DispatchTime.now() + 1), (complete, DispatchTime.now() - 1)] {
            var called = false
            let result = DialogPressExecutor.perform(
                snapshot: snapshot, deadline: deadline, session: .init { [:] },
                decide: { _ in
                    called = true
                    return 0
                },
                press: { _, _ in
                    called = true
                    return .pressed
                })
            XCTAssertEqual(result, .inspectionIncomplete)
            XCTAssertFalse(called)
        }
    }

    func testPressUsesTheSelectedElementFromTheSameSnapshot() {
        let snapshot = DialogTreeScanner<DialogTreeScannerTests.Provider>().scan(
            provider: DialogTreeScannerTests.dialog, deadline: .now() + 0.7)
        var elements: [Int] = []
        let result = DialogPressExecutor.perform(
            snapshot: snapshot, deadline: .now() + 0.7, session: .init { [:] },
            decide: { dialog in
                XCTAssertEqual(dialog.buttons, ["Cancel", "Continue"])
                return 1
            },
            press: { element, timeout in
                elements.append(element)
                XCTAssertGreaterThan(timeout, 0)
                return .pressed
            })
        XCTAssertEqual(result, .pressed)
        XCTAssertEqual(elements, [7])
    }

    func testUnknownScanProducesAnExplicitCommandError() {
        XCTAssertThrowsError(try DialogListCommand.output(for: .inspectionIncomplete)) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not inspect"))
        }
        XCTAssertEqual(try DialogListCommand.output(for: .none), DialogListCommand.noDialogMessage)
    }

    func testGlobalAndEntryInspectionShareBusyAllowance() {
        let worker = BoundedAXWorker()
        worker.withExclusive(fallback: ()) {
            let global = GlobalDialogProbe(worker: worker) { DialogTreeScannerTests.Provider() }
            let entry = BoundedDialogProbe(worker: worker) { DialogTreeScannerTests.Provider() }
            XCTAssertEqual(global.scan(), .inspectionIncomplete)
            XCTAssertEqual(entry.check(windowKey: .id(42)), .unprobed)
        }
    }
}
