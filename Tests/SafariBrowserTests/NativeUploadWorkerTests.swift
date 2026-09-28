import Foundation
import XCTest
@testable import SafariBrowser

final class NativeUploadWorkerTests: XCTestCase {
    private let image = String(repeating: "a", count: 32)
    private func request() -> NativeUploadRequest {
        NativeUploadRequest(selector: "input[type=file]", path: "/tmp/隱藏 ' café.txt", fileSize: 17,
            modificationTimeMilliseconds: -627, clipboardChangeCount: 42, window: 2, timeout: 8,
            nonce: "148D368A-54B0-4AC6-927C-CC4FAB64B86E", windowID: 8128, tabIndex: 1, deadlineUptime: 107)
    }
    private func validate(_ value: NativeUploadRequest, parent: String? = "/private/bin/safari-browser",
                          expected: String? = nil, current: String? = nil, now: Double = 100) throws {
        try NativeUploadWorkerValidation.validate(value, expectedImage: expected ?? image, currentImage: current ?? image,
            parentExecutable: parent, executable: "/private/bin/safari-browser", now: now)
    }

    func testRejectsDifferentParentOrImageBeforeExecution() throws {
        try validate(request())
        XCTAssertThrowsError(try validate(request(), parent: "/bin/zsh"))
        XCTAssertThrowsError(try validate(request(), parent: nil))
        XCTAssertThrowsError(try validate(request(), expected: String(repeating: "b", count: 32)))
        XCTAssertThrowsError(try validate(request(), expected: "", current: ""))
    }

    func testRequestBoundsRejectInvalidTransaction() throws {
        let invalid: [(inout NativeUploadRequest) -> Void] = [
            { $0.version = 2 }, { $0.selector = "" }, { $0.selector = String(repeating: "x", count: 65_537) },
            { $0.path = "relative.txt" }, { $0.path = "/tmp/../private/secret" }, { $0.path = "/tmp/a\0b" },
            { $0.path = "/" }, { $0.fileSize = -1 }, { $0.fileSize = 9_007_199_254_740_992 },
            { $0.modificationTimeMilliseconds = Int64.max }, { $0.clipboardChangeCount = -1 },
            { $0.window = 0 }, { $0.windowID = 0 }, { $0.tabIndex = 0 },
            { $0.timeout = .nan }, { $0.timeout = 0 }, { $0.timeout = 86_401 },
            { $0.deadlineUptime = .infinity }, { $0.deadlineUptime = 100 }, { $0.deadlineUptime = 109 },
            { $0.nonce = "not a nonce" }
        ]
        for change in invalid {
            var value = request(); change(&value)
            XCTAssertThrowsError(try validate(value), "Should reject \(value)")
        }
        XCTAssertThrowsError(try validate(request(), now: .nan))
    }

    func testBoundedFixedSchemaRoundTrip() throws {
        let value = request()
        XCTAssertEqual(try NativeUploadRequest.decode(value.encodedArgument()), value)
        XCTAssertThrowsError(try NativeUploadRequest.decode("not base64"))
        XCTAssertThrowsError(try NativeUploadRequest.decode(String(repeating: "A", count: 200_000)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object["script"] = "arbitrary code"
        XCTAssertThrowsError(try NativeUploadRequest.decode(JSONSerialization.data(withJSONObject: object).base64EncodedString()))
        object.removeValue(forKey: "script"); object.removeValue(forKey: "version")
        XCTAssertThrowsError(try NativeUploadRequest.decode(JSONSerialization.data(withJSONObject: object).base64EncodedString()))
    }
}

extension NativeUploadWorkerTests {
    func testOptionalTabStillCapturesCurrentTabInFixedBuilder() throws {
        var value = request(); value.tabIndex = nil
        try validate(value)
        XCTAssertTrue(value.makeScript().contains("set uploadTabIndex to index of current tab of window id uploadWindowID"))
    }

    func testCallbackRejectsWithoutReadingAXOrPasteboard() {
        var probes = 0; var clipboardReads = 0
        let probe: (Int, String, Double) -> String = { _, _, _ in probes += 1; return "MATCH" }
        let clipboard = { clipboardReads += 1; return 42 }
        XCTAssertEqual(NativeUploadWorkerContext.selection(windowID: 8128, request: nil, now: {100}, clipboardCount: clipboard, probe: probe), "OWNER_CHANGED")
        XCTAssertEqual(NativeUploadWorkerContext.selection(windowID: 8129, request: request(), now: {100}, clipboardCount: clipboard, probe: probe), "OWNER_CHANGED")
        XCTAssertEqual(NativeUploadWorkerContext.selection(windowID: 8128, request: request(), now: {107}, clipboardCount: clipboard, probe: probe), "DEADLINE")
        XCTAssertEqual(probes, 0); XCTAssertEqual(clipboardReads, 0)
    }

    func testCallbackRechecksDeadlineAndClipboardAfterExactBoundProbe() {
        var now = 100.0; var count = 42; var probes = 0
        func check(_ during: () -> Void) -> String {
            NativeUploadWorkerContext.selection(windowID: 8128, request: request(), now: {now}, clipboardCount: {count}) { id, path, deadline in
                probes += 1; XCTAssertEqual(id, 8128); XCTAssertEqual(path, self.request().path); XCTAssertEqual(deadline, 107)
                during(); return "MATCH"
            }
        }
        XCTAssertEqual(check({}), "MATCH")
        XCTAssertEqual(check({ count = 43 }), "CLIPBOARD_CHANGED")
        XCTAssertEqual(check({}), "CLIPBOARD_CHANGED")
        XCTAssertEqual(probes, 2)
        count = 42
        XCTAssertEqual(check({ now = 107 }), "DEADLINE")
    }

    func testRuntimeErrorRenderingPreservesParentInputMarkerMapping() {
        let details: NSDictionary = [NSAppleScript.errorMessage: "SB_UPLOAD_INPUT_NOT_FOUND", NSAppleScript.errorNumber: -2700]
        let rendered = SafariBrowser.fullMessage(for: NativeUploadWorkerCommand.runtimeError(details))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(rendered.hasSuffix(": execution error: SB_UPLOAD_INPUT_NOT_FOUND (-2700)"), rendered)
        XCTAssertFalse(rendered.contains("Usage:"), rendered)
    }

    func testErrorsPreserveInputMarkerAndLoggerRejectsInjection() {
        XCTAssertEqual(NativeUploadWorkerCommand.scriptError([NSAppleScript.errorMessage: "SB_UPLOAD_INPUT_NOT_FOUND", NSAppleScript.errorNumber: -2700]), "execution error: SB_UPLOAD_INPUT_NOT_FOUND (-2700)")
        XCTAssertEqual(NativeUploadWorkerContext.confirmationLine("上傳"), "confirming file dialog: pressing named button \"上傳\"\n")
        XCTAssertNil(NativeUploadWorkerContext.confirmationLine("Open\nforged diagnostics"))
        XCTAssertNil(NativeUploadWorkerContext.confirmationLine("Delete"))
    }

    @MainActor
    func testObjectiveCBridgeIsCallableWithoutContextAndDoesNotTouchUI() throws {
        let script = try XCTUnwrap(NSAppleScript(source: """
        use framework "Foundation"
        return (current application's SBNativeUploadBridge's selectionForWindow:8128) as text
        """))
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        XCTAssertNil(error)
        XCTAssertEqual(result.stringValue, "OWNER_CHANGED")
        var expired = request(); expired.deadlineUptime = 0
        let bound = NativeUploadWorkerContext.$request.withValue(expired) {
            script.executeAndReturnError(&error).stringValue
        }
        XCTAssertNil(error)
        XCTAssertEqual(bound, "DEADLINE", "Objective-C dispatch must retain the TaskLocal request")
        XCTAssertNil(NativeUploadWorkerContext.request)
    }

    func testConfirmationAuthorizationRejectsBeforeWriting() {
        var writes: [String] = []; var clipboardReads = 0
        func attempt(_ value: NativeUploadRequest?, title: String = "Open", now: Double = 100, count: Int = 42) -> Bool {
            NativeUploadWorkerContext.authorizeConfirmation(title: title, request: value, now: {now},
                clipboardCount: { clipboardReads += 1; return count }, write: { writes.append($0) })
        }
        XCTAssertFalse(attempt(nil))
        XCTAssertFalse(attempt(request(), title: "open"))
        XCTAssertFalse(attempt(request(), title: "UPLOAD"))
        XCTAssertFalse(attempt(request(), title: "Open\nforged"))
        XCTAssertFalse(attempt(request(), now: 107))
        XCTAssertEqual(clipboardReads, 0)
        XCTAssertFalse(attempt(request(), count: 43))
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(attempt(request(), title: "上傳"))
        XCTAssertEqual(writes, ["confirming file dialog: pressing named button \"上傳\"\n"])
    }

    func testConfirmationAuthorizationRejectsFailedOrDelayedWriter() {
        enum WriteFailure: Error { case closed }
        var writes = 0; var count = 42; var now = 100.0
        func attempt(_ writer: () throws -> Void) -> Bool {
            NativeUploadWorkerContext.authorizeConfirmation(title: "Open", request: request(), now: {now}, clipboardCount: {count}) { _ in
                writes += 1; try writer()
            }
        }
        XCTAssertFalse(attempt({ throw WriteFailure.closed }))
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(attempt({ count = 43 }))
        XCTAssertEqual(writes, 2)
        count = 42
        XCTAssertFalse(attempt({ now = 107 }))
        XCTAssertEqual(writes, 3)
    }

    @MainActor
    func testConfirmationBridgeReturnsFalseForAbsentOrExpiredContext() throws {
        let script = try XCTUnwrap(NSAppleScript(source: """
        use framework "Foundation"
        return (current application's SBNativeUploadBridge's logConfirmation:"Open") as boolean
        """))
        var error: NSDictionary?
        let absent = script.executeAndReturnError(&error)
        XCTAssertNil(error, "A refused confirmation must return false, not a missing value")
        XCTAssertFalse(absent.booleanValue)
        var expired = request(); expired.deadlineUptime = 0
        let result = NativeUploadWorkerContext.$request.withValue(expired) {
            script.executeAndReturnError(&error)
        }
        XCTAssertNil(error)
        XCTAssertFalse(result.booleanValue)
    }

    func testActualWorkerEntryRejectsUnrelatedParentBeforeUI() async throws {
        var value = request()
        value.deadlineUptime = ProcessInfo.processInfo.systemUptime + 5
        var command = try NativeUploadWorkerCommand.parse([value.encodedArgument(), MCPWorkerContext.currentImageIdentifier()])
        do {
            try await command.run()
            XCTFail("An XCTest worker must not authorize its unrelated launcher")
        } catch {
            XCTAssertTrue(String(describing: error).contains("matching parent executable"), "Unexpected error: \(error)")
        }
    }
    private func constrainedRequest() throws -> NativeUploadRequest {
        var value = request()
        value.targetConstraint = try NativeUploadTargetConstraint.from(.resolvedTab(windowID: 8128, tabInWindow: 1,
            rematch: .exact("https://fixture.invalid/upload"), profile: "Work"))
        return value
    }

    func testTargetConstraintSurvivesClosedRequestRoundTrip() throws {
        let value = try constrainedRequest()
        XCTAssertEqual(try NativeUploadRequest.decode(value.encodedArgument()), value)
        XCTAssertTrue(value.makeScript().contains("my verifyUploadRequestedTarget()"))
        XCTAssertFalse(request().makeScript().contains("my verifyUploadRequestedTarget()"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        let invalidConstraints: [[String: Any]] = [
            ["profile": "Work", "script": "arbitrary"],
            ["matcher": ["kind": "exact", "pattern": "https://fixture.invalid/upload", "script": "arbitrary"]],
            ["matcher": ["kind": "script", "pattern": "arbitrary"]],
            ["matcher": ["kind": "regex", "pattern": "[", "options": 0]],
            ["profile": NSNull()], [:]
        ]
        for constraint in invalidConstraints {
            var invalid = object; invalid["targetConstraint"] = constraint
            XCTAssertThrowsError(try NativeUploadRequest.decode(JSONSerialization.data(withJSONObject: invalid).base64EncodedString()))
        }
    }

    func testTargetConstraintChecksOriginalURLAndProfile() throws {
        let value = try constrainedRequest()
        func check(url: String = "https://fixture.invalid/upload", name: String = "Work — Fixture") -> Bool {
            NativeUploadWorkerContext.targetMatches(windowID: 8128, url: url, windowName: name,
                request: value, now: {100}, clipboardCount: {42})
        }
        XCTAssertTrue(check())
        XCTAssertFalse(check(url: "https://fixture.invalid/other"))
        XCTAssertFalse(check(name: "Personal — Fixture"))
        XCTAssertFalse(check(name: "Fixture"))
    }

    func testTargetConstraintRejectsAbsentExpiredOrWrongWindowBeforeClipboard() throws {
        var clipboardReads = 0
        let value = try constrainedRequest()
        func check(_ value: NativeUploadRequest?, windowID: Int = 8128, now: Double = 100) -> Bool {
            NativeUploadWorkerContext.targetMatches(windowID: windowID, url: "https://fixture.invalid/upload",
                windowName: "Work — Fixture", request: value, now: {now},
                clipboardCount: { clipboardReads += 1; return 42 })
        }
        XCTAssertFalse(check(nil))
        XCTAssertFalse(check(request()))
        XCTAssertFalse(check(value, windowID: 8129))
        XCTAssertFalse(check(value, now: 107))
        XCTAssertEqual(clipboardReads, 0)
    }

    func testTargetConstraintRechecksClockAndClipboardAfterMatching() throws {
        let value = try constrainedRequest()
        for (times, counts) in [([100.0, 100.0], [42, 42]), ([100.0, 107.0], [42, 42]), ([100.0, 100.0], [42, 43]), ([100.0, 100.0], [43, 42])] {
            var timeIndex = 0; var countIndex = 0
            let result = NativeUploadWorkerContext.targetMatches(windowID: 8128, url: "https://fixture.invalid/upload",
                windowName: "Work — Fixture", request: value,
                now: { defer { timeIndex += 1 }; return times[min(timeIndex, times.count - 1)] },
                clipboardCount: { defer { countIndex += 1 }; return counts[min(countIndex, counts.count - 1)] })
            XCTAssertEqual(result, times[1] < 107 && counts == [42, 42])
        }
    }

    @MainActor
    func testTargetConstraintObjCBridgeRejectsAbsentOrExpiredContextWithoutUI() throws {
        let script = try XCTUnwrap(NSAppleScript(source: """
        use framework "Foundation"
        return (current application's SBNativeUploadBridge's targetMatchesWindow:8128 urlString:"https://fixture.invalid/upload" windowName:"Work — Fixture") as boolean
        """))
        var error: NSDictionary?
        XCTAssertFalse(script.executeAndReturnError(&error).booleanValue)
        XCTAssertNil(error)
        var expired = try constrainedRequest(); expired.deadlineUptime = 0
        let result = NativeUploadWorkerContext.$request.withValue(expired) { script.executeAndReturnError(&error) }
        XCTAssertFalse(result.booleanValue)
        XCTAssertNil(error)
    }

}
