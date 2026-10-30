import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

final class ScopedDialogCommandTests: XCTestCase {
    func testPositiveStableWindowScopeIsAcceptedByBothCommands() throws {
        _ = try DialogListCommand.parse(["--window-id", "42"])
        _ = try DialogDismissCommand.parse(["--window-id", "42", "--button", "好"])
        _ = try DialogDismissCommand.parse(["--window-id", "42", "--button", "好",
            "--expect-window-id", "42", "--expect-message", "新增這筆資料。確定嗎？"])
    }

    func testInvalidAndConflictingScopesAreRejected() {
        for id in ["0", "-1", "not-an-id"] {
            XCTAssertThrowsError(try DialogListCommand.parse(["--window-id=\(id)"]))
            XCTAssertThrowsError(try DialogDismissCommand.parse(["--window-id=\(id)", "--button", "好"]))
        }
        XCTAssertThrowsError(try DialogDismissCommand.parse(["--window-id", "42", "--button", "好",
            "--expect-window-id", "99", "--expect-message", "nonce"]))
    }

    func testIncompleteDiagnosticDoesNotRecommendIdenticalRetry() {
        let message = SafariBrowserError.dialogInspectionIncomplete.localizedDescription
        XCTAssertFalse(message.contains("dialog list again"))
        XCTAssertTrue(message.contains("--window-id"))
        XCTAssertTrue(message.contains("manually"))
    }

    private func observation(_ provider: DialogTreeScannerTests.Provider = DialogTreeScannerTests.dialog) -> WindowDialogObservation {
        WindowDialogObservation(snapshot: DialogTreeScanner<DialogTreeScannerTests.Provider>().scan(
            provider: provider, deadline: .now() + 1))
    }

    func testAllThreeOperationsRetainScopeAndObservedIdentity() throws {
        for args in [["--button", "Continue"],
                     ["--button", "Continue", "--window-id", "42"],
                     ["--button", "Continue", "--expect-window-id", "42", "--expect-message", "Source Body"]] {
            let command = try DialogDismissCommand.parse(args)
            let expectedScope: Int? = args.count == 2 ? nil : 42
            var inspections = 0, presses = 0
            try command.execute(inspect: { scope in
                XCTAssertEqual(scope, expectedScope)
                inspections += 1
                return observation()
            }, press: { expectedID, scope, decide in
                XCTAssertEqual(expectedID, 42, "even global dismissal anchors the first observed identity")
                XCTAssertEqual(scope, expectedScope, "global mode must not silently narrow on the second scan")
                XCTAssertEqual(decide(.init(message: "Source Body", buttons: ["Cancel", "Continue"])), 1)
                presses += 1
                return .pressed
            })
            XCTAssertEqual(inspections, 2)
            XCTAssertEqual(presses, 1)
        }
    }

    func testIncompleteAmbiguousAndWrongWindowObservationsNeverReachPress() throws {
        let command = try DialogDismissCommand.parse(["--button", "Continue", "--window-id", "42"])
        var other = DialogTreeScannerTests.dialog
        other.nodes[1]!.id = 99
        var multiple = DialogTreeScannerTests.dialog
        multiple.nodes[1]!.children.append(10)
        multiple.nodes[10] = .init(role: "AXSheet")
        for value in [WindowDialogObservation.unavailable(reason: "incomplete"), observation(other), observation(multiple)] {
            XCTAssertThrowsError(try command.execute(inspect: { _ in value },
                press: { _, _, _ in XCTFail("unconfirmed candidate must not press"); return .pressed }))
        }
    }

    func testChangedMessageOrButtonsInActualSecondScanNeverPress() throws {
        let command = try DialogDismissCommand.parse(["--button", "Continue", "--window-id", "42"])
        for variant in ["message", "missing", "duplicate", "reordered"] {
            var p = DialogTreeScannerTests.dialog
            switch variant {
            case "message": p.nodes[3]!.text = "Delete everything?"
            case "missing": p.nodes[7]!.title = nil
            case "duplicate": p.nodes[6]!.title = "Continue"
            default: p.nodes[2]!.children = [3, 4, 7, 6]
            }
            let reread = DialogTreeScanner<DialogTreeScannerTests.Provider>().scan(provider: p, deadline: .now() + 1)
            XCTAssertThrowsError(try command.execute(inspect: { _ in observation() },
                press: { expectedID, _, decide in
                    DialogPressExecutor.perform(snapshot: reread, deadline: .now() + 1, session: .init { [:] },
                        expectedWindowID: expectedID, decide: decide,
                        press: { _, _ in XCTFail("changed dialog must not press"); return .pressed })
                }), variant)
        }
    }

    func testMissingOrDuplicateNamedButtonRefusesBeforePress() throws {
        for title in ["Missing", "Continue"] {
            var p = DialogTreeScannerTests.dialog
            if title == "Continue" { p.nodes[6]!.title = "Continue" }
            let command = try DialogDismissCommand.parse(["--button", title, "--window-id", "42"])
            XCTAssertThrowsError(try command.execute(inspect: { _ in observation(p) },
                press: { _, _, _ in XCTFail("button must be uniquely named"); return .pressed }))
        }
    }

    func testScopedListingNamesStableIDAndRecoveryScope() throws {
        let text = try DialogListCommand.output(for: observation().scanResult, windowID: 42)
        XCTAssertEqual(text.components(separatedBy: "\n").first, "blocking dialog present")
        XCTAssertTrue(text.contains("Safari window id 42"))
        XCTAssertTrue(text.contains("dialog dismiss --window-id 42 --button"))
        let none = try DialogListCommand.output(for: .none, windowID: 42)
        XCTAssertEqual(none, "Safari window id 42\nno blocking dialog found")
        XCTAssertTrue(SafariBrowserError.noBlockingDialog.localizedDescription.contains("Accessibility"))
        XCTAssertTrue(SafariBrowserError.noBlockingDialog.localizedDescription.contains("manually"))
    }
}
