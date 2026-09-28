import Foundation
import XCTest
@testable import SafariBrowser

/// Execute the generated decision/confirmation fragment with only its external
/// observations, clock and AX actions replaced. No Safari or clipboard access.
final class NativeUploadReadinessTests: XCTestCase {
    struct Result {
        let status: String
        let confirmations: Int
        let selections: Int
        let receipts: Int
        let sleeps: Int
        let waitedMilliseconds: Int
        let receipt: String
    }

    private func runFixture(states: [String], deliveredAt: Int = 0,
                            panel: Bool = true, timeout: Double = 0.15,
                            faultAfterWait: String = "") async throws -> Result {
        let source = NativeUploadScript.make(selector: "#owned", path: "/tmp/owned.txt",
            fileSize: 5, modificationTimeMilliseconds: 123000, clipboardChangeCount: 42,
            window: 1, timeout: 8, nonce: "owned-readiness")
        let begin = try XCTUnwrap(source.range(of: "-- Paste can accept directly"))
        let end = try XCTUnwrap(source.range(of: "    repeat\n        my verifyUploadCompletionTarget()",
            options: .backwards, range: begin.upperBound..<source.endIndex))
        var fragment = String(source[begin.lowerBound..<end.lowerBound])
        let buttons = try XCTUnwrap(fragment.range(of: "set fileButtons to buttons of uploadPanel"))
        let title = try XCTUnwrap(fragment.range(of: "set confirmationTitle to title of confirmationButton",
            range: buttons.lowerBound..<fragment.endIndex))
        fragment.replaceSubrange(buttons.lowerBound..<title.upperBound,
                                 with: "set confirmationTitle to \"Open\"")
        fragment = fragment
            .replacingOccurrences(of: "tell application \"System Events\" to tell process \"Safari\"", with: "tell me")
            .replacingOccurrences(of: "(exists sheet 1 of front window)", with: "fixturePanel")
            .replacingOccurrences(of: "perform action \"AXPress\" of confirmationButton",
                                  with: "set confirmations to confirmations + 1")
            .replacingOccurrences(of: "current application's SBNativeUploadBridge's logConfirmation:confirmationTitle",
                                  with: "my recordConfirmation(confirmationTitle)")
            .replacingOccurrences(of: "((current application's NSProcessInfo's processInfo()'s systemUptime()) as real)",
                                  with: "mockTime")
        let delay = try NSRegularExpression(pattern: #"(?m)^(\s*)delay (.+)$"#)
        fragment = delay.stringByReplacingMatches(in: fragment,
            range: NSRange(fragment.startIndex..., in: fragment), withTemplate: "$1my fixtureDelay($2)")
        guard !fragment.contains("tell application"), !fragment.contains("sheet 1"),
              !fragment.contains("current application's"), !fragment.contains("perform action"),
              !fragment.contains("keystroke") else {
            throw NSError(domain: "ReadinessFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unadapted external action or observation"])
        }
        let literals = states.map { "\"\($0)\"" }.joined(separator: ", ")
        let isolated = """
        property mockTime : 0.0
        property uploadEndTime : \(timeout)
        property fixturePanel : \(panel ? "true" : "false")
        property nativeStates : {\(literals)}
        property selections : 0
        property receipts : 0
        property sleeps : 0
        property confirmations : 0
        property outcome : "ok"
        property selectionResult : "PENDING"
        on checkUploadDeadline()
            if mockTime >= uploadEndTime then error "deadline"
        end checkUploadDeadline
        on checkUploadClipboard()
            if mockTime > 0 and "\(faultAfterWait)" is not "" then error "\(faultAfterWait)"
        end checkUploadClipboard
        on verifyUploadCompletionTarget()
            my checkUploadDeadline()
            my checkUploadClipboard()
        end verifyUploadCompletionTarget
        on verifyUploadPanel()
            my checkUploadDeadline()
            my checkUploadClipboard()
        end verifyUploadPanel
        on readUploadCompletion()
            set receipts to receipts + 1
            if \(deliveredAt) > 0 and receipts >= \(deliveredAt) then return "OK"
            return "PENDING"
        end readUploadCompletion
        on readUploadSelection()
            set selections to selections + 1
            if selections > (count nativeStates) then return last item of nativeStates
            return item selections of nativeStates
        end readUploadSelection
        on recordConfirmation(t)
            my checkUploadDeadline()
            my checkUploadClipboard()
            return true
        end recordConfirmation
        on fixtureDelay(delaySeconds)
            set sleeps to sleeps + 1
            delay delaySeconds
            set mockTime to mockTime + delaySeconds
        end fixtureDelay
        try
            \(fragment)
        on error messageText
            set outcome to messageText
        end try
        return outcome & "|" & confirmations & "|" & selections & "|" & receipts & "|" & sleeps & "|" & ((mockTime * 1000) as integer) & "|" & selectionResult
        """
        let started = ProcessInfo.processInfo.systemUptime
        let raw = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", isolated], timeout: 3)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let fields = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 7,
              let confirmations = Int(fields[1]), let selections = Int(fields[2]),
              let receipts = Int(fields[3]), let sleeps = Int(fields[4]), let waited = Int(fields[5]) else {
            throw NSError(domain: "ReadinessFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: raw])
        }
        print("readiness-fixture states=\(states.joined(separator: ",")) deliveredAt=\(deliveredAt) panel=\(panel) fault=\(faultAfterWait) result=\(raw) wallSeconds=\(elapsed)")
        return Result(status: fields[0], confirmations: confirmations, selections: selections,
                      receipts: receipts, sleeps: sleeps, waitedMilliseconds: waited, receipt: fields[6])
    }

    func testImmediateReadinessAvoidsSettleWaitWithoutExtraSelectionRead() async throws {
        for _ in 0..<5 {
            let selected = try await runFixture(states: ["MATCH"])
            XCTAssertEqual(selected.status, "ok")
            XCTAssertEqual(selected.confirmations, 1)
            XCTAssertEqual(selected.selections, 2)
            XCTAssertEqual(selected.sleeps, 0)
            let delivered = try await runFixture(states: ["UNAVAILABLE"], deliveredAt: 1)
            XCTAssertEqual(delivered.status, "ok")
            XCTAssertEqual(delivered.confirmations, 0)
            XCTAssertEqual(delivered.selections, 0)
            XCTAssertEqual(delivered.sleeps, 0)
        }
    }

    func testPendingSelectionBecomesReadyWithoutRepeatingFileActions() async throws {
        let result = try await runFixture(states: ["PENDING", "MATCH", "MATCH"])
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(result.confirmations, 1)
        XCTAssertEqual(result.selections, 3)
        XCTAssertEqual(result.sleeps, 1)
        XCTAssertEqual(result.waitedMilliseconds, 100)
    }

    func testUnknownAndChangedFinalSelectionRefuseWithoutWaiting() async throws {
        for states in [["UNAVAILABLE"], ["MATCH", "UNAVAILABLE"]] {
            let result = try await runFixture(states: states)
            XCTAssertNotEqual(result.status, "ok")
            XCTAssertEqual(result.confirmations, 0)
            XCTAssertEqual(result.sleeps, 0)
        }
    }

    func testPersistentPendingUsesOriginalRemainingDeadline() async throws {
        let result = try await runFixture(states: ["PENDING"])
        XCTAssertEqual(result.status, "deadline")
        XCTAssertEqual(result.confirmations, 0)
        XCTAssertEqual(result.sleeps, 2)
        XCTAssertEqual(result.waitedMilliseconds, 150)
    }

    func testReceiptAfterChooserDisappearsDoesNotConfirm() async throws {
        let result = try await runFixture(states: ["UNAVAILABLE"], deliveredAt: 2, panel: false)
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(result.receipt, "OK")
        XCTAssertEqual(result.confirmations, 0)
        XCTAssertEqual(result.selections, 0)
        XCTAssertEqual(result.sleeps, 1)
    }

    func testPendingStopsOnCancellationFocusTargetOrClipboardChange() async throws {
        for fault in ["cancelled", "focus changed", "target changed", "clipboard changed"] {
            let result = try await runFixture(states: ["PENDING", "MATCH"], faultAfterWait: fault)
            XCTAssertEqual(result.status, fault)
            XCTAssertEqual(result.confirmations, 0)
            XCTAssertEqual(result.receipts, 1)
            XCTAssertEqual(result.sleeps, 1)
        }
    }
}
