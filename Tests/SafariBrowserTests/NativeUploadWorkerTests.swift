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
}
