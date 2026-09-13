import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

final class DialogExpectationTests: XCTestCase {
    func testExpectationFlagsMustBePairedAndWindowMustBePositive() throws {
        for arguments in [
            ["--button", "OK", "--expect-window-id", "71"],
            ["--button", "OK", "--expect-message", "nonce"],
            ["--button", "OK", "--expect-window-id", "0", "--expect-message", "nonce"],
            ["--button", "OK", "--expect-window-id=-1", "--expect-message", "nonce"]
        ] { XCTAssertThrowsError(try DialogDismissCommand.parse(arguments)) }
        let guarded = try DialogDismissCommand.parse(["--button", "OK", "--expect-window-id", "71", "--expect-message", "nonce"])
        XCTAssertEqual(guarded.expectWindowID, 71)
        XCTAssertEqual(guarded.expectMessage, "nonce")
        let ordinary = try DialogDismissCommand.parse(["--button", "OK"])
        XCTAssertNil(ordinary.expectWindowID)
        XCTAssertNil(ordinary.expectMessage)
    }

    func testRawMessageMismatchCannotBecomeTheNewExpectedDialog() throws {
        let userDialog = SafariBridge.BlockingDialog(message: "user action", buttons: ["OK"])
        XCTAssertThrowsError(try DialogDismissCommand.validateExpectedMessage("fixture nonce", actual: userDialog))
        let raw = SafariBridge.BlockingDialog(message: "nonce\n", buttons: ["OK"])
        XCTAssertThrowsError(try DialogDismissCommand.validateExpectedMessage("nonce", actual: raw))
        try DialogDismissCommand.validateExpectedMessage("nonce\n", actual: raw)
        try DialogDismissCommand.validateExpectedMessage(nil, actual: userDialog)
        try DialogDismissCommand.validateExpectedMessage("", actual: .init(message: "", buttons: ["OK"]))
    }

    private func snapshot(windowID: Int) -> DialogTreeSnapshot<Int> {
        .init(candidates: [.init(windowID: windowID, element: 1,
            dialog: .init(message: "nonce", buttons: ["OK"]), buttons: [(element: 2, title: "OK")])])
    }

    func testDifferentWindowWithIdenticalFingerprintNeverDecidesOrPresses() {
        var decisions = 0, presses = 0
        let result = DialogPressExecutor.perform(snapshot: snapshot(windowID: 72), deadline: .now() + 1,
            session: .init { [:] }, expectedWindowID: 71,
            decide: { _ in decisions += 1; return 0 },
            press: { _, _ in presses += 1; return .pressed })
        XCTAssertEqual(result, .refused(current: .init(message: "nonce", buttons: ["OK"])))
        XCTAssertEqual(decisions, 0)
        XCTAssertEqual(presses, 0)
    }

    func testMatchingAndUnspecifiedWindowRetainExistingFingerprintDecision() {
        for expectedID: Int? in [71, nil] {
            var elements: [Int] = []
            let original = SafariBridge.BlockingDialog(message: "nonce", buttons: ["OK"])
            let result = DialogPressExecutor.perform(snapshot: snapshot(windowID: 71), deadline: .now() + 1,
                session: .init { [:] }, expectedWindowID: expectedID,
                decide: { current in
                    if case .press(let index) = DialogDismissCommand.decidePress(title: "OK", expected: original, current: current) { return index }
                    return nil
                }, press: { element, _ in elements.append(element); return .pressed })
            XCTAssertEqual(result, .pressed)
            XCTAssertEqual(elements, [2])
        }
    }

    func testMatchingWindowDoesNotOverrideMessageChangeOrIncompleteScan() {
        var incomplete = snapshot(windowID: 71)
        incomplete.isComplete = false
        let rejected = DialogPressExecutor.perform(snapshot: incomplete, deadline: .now() + 1,
            session: .init { [:] }, expectedWindowID: 71,
            decide: { _ in XCTFail("incomplete must not decide"); return 0 },
            press: { _, _ in XCTFail("incomplete must not press"); return .pressed })
        XCTAssertEqual(rejected, .inspectionIncomplete)
        let changed = DialogPressExecutor.perform(snapshot: snapshot(windowID: 71), deadline: .now() + 1,
            session: .init { [:] }, expectedWindowID: 71,
            decide: { current in
                if case .press(let index) = DialogDismissCommand.decidePress(title: "OK", expected: .init(message: "older", buttons: ["OK"]), current: current) { return index }
                return nil
            }, press: { _, _ in XCTFail("changed message must not press"); return .pressed })
        XCTAssertEqual(changed, .refused(current: .init(message: "nonce", buttons: ["OK"])))
    }
}
