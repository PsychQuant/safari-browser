import Foundation
import XCTest
@testable import SafariBrowser

final class NativeUploadTargetGuardScriptTests: XCTestCase {
    func testOriginalConstraintIsCheckedBeforeActivatingCapturedCandidate() async throws {
        let source = NativeUploadScript.make(selector: "#file", path: "/tmp/owned.txt", fileSize: 1,
            modificationTimeMilliseconds: 1, clipboardChangeCount: 1, window: 1, timeout: 10,
            nonce: "fixture", windowID: 42, tabIndex: 2, deadlineUptime: 999999999,
            targetCheckRequired: true)
        let begin = try XCTUnwrap(source.range(of: "set uploadEndTime to "))
        let end = try XCTUnwrap(source.range(of: "try\n    repeat", range: begin.upperBound..<source.endIndex))
        var main = String(source[begin.lowerBound..<end.lowerBound])
        main = main.replacingOccurrences(of: "tell application \"Safari\"", with: "tell me")
            .replacingOccurrences(of: "set uploadWindowID to id of window id 42", with: "set uploadWindowID to 42")
            .replacingOccurrences(of: "set uploadTabIndex to index of current tab of window id uploadWindowID", with: "set uploadTabIndex to 2")
            .replacingOccurrences(of: "set uploadPageURL to URL of current tab of window id uploadWindowID", with: "set uploadPageURL to \"https://b.example/other\"")
            .replacingOccurrences(of: "set index of window id uploadWindowID to 1", with: "set raises to raises + 1")
            .replacingOccurrences(of: "    activate", with: "    set activations to activations + 1")
        var guardBody = NativeUploadScript.requestedTargetGuardScript()
        guardBody = guardBody.replacingOccurrences(of: "tell application \"Safari\" to set requestedWindowName to name of window id uploadWindowID", with: "set requestedWindowName to \"fixture\"")
            .replacingOccurrences(of: "current application's SBNativeUploadBridge's targetMatchesWindow:uploadWindowID urlString:uploadPageURL windowName:requestedWindowName", with: "requestMatches")
        XCTAssertFalse(main.contains("tell application"))
        XCTAssertFalse(guardBody.contains("tell application"))
        for allowed in [false, true] {
            let isolated = """
            property raises : 0
            property activations : 0
            property requestMatches : \(allowed ? "true" : "false")
            property uploadWindowID : 0
            property uploadPageURL : ""
            on checkUploadDeadline()
            end checkUploadDeadline
            on checkUploadClipboard()
            end checkUploadClipboard
            on verifyUploadNativeTarget()
            end verifyUploadNativeTarget
            on verifyUploadRequestedTarget()
                \(guardBody)
            end verifyUploadRequestedTarget
            try
                \(main)
            end try
            return (raises as text) & ":" & activations
            """
            let result = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", isolated], timeout: 3)
            XCTAssertEqual(result, allowed ? "1:1" : "0:0")
        }
    }
}
