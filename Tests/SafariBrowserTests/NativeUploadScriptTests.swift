import Foundation
import JavaScriptCore
import XCTest
@testable import SafariBrowser

final class NativeUploadScriptTests: XCTestCase {
    private func script(window: Int? = 2) -> String {
        NativeUploadScript.make(selector: "input[data-name=\"a'\\b\"]", path: "/tmp/隱藏 ' café.txt", fileSize: 17, modificationTimeMilliseconds: 123456, clipboardChangeCount: 42, window: window, timeout: 8, nonce: "test-'\\nonce")
    }

    func testGeneratedScriptCompilesWithoutRunningSafari() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        for window in [nil, 2] as [Int?] {
            let source = dir.appendingPathComponent("upload.applescript")
            try script(window: window).write(to: source, atomically: true, encoding: .utf8)
            _ = try await SafariBridge.runShell("/usr/bin/osacompile", ["-o", dir.appendingPathComponent("upload.scpt").path, source.path], timeout: 10)
        }
    }

    func testNoKeyboardFallbackAndBoundedNamedConfirmation() {
        let source = script()
        for forbidden in ["keystroke", "key code", "default button", "defaultBtn", "Go to Folder", "entire contents"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertTrue(source.contains("systemUptime"))
        XCTAssertTrue(source.contains("changeCount"))
        XCTAssertTrue(source.contains("set uploadWindowID to id of window 2"))
        XCTAssertTrue(source.contains("Unexpected sheet before native upload"))
        XCTAssertTrue(source.contains("Nested sheet appeared"))
        XCTAssertTrue(source.contains("confirming file dialog: pressing named button"))
        XCTAssertEqual(source.components(separatedBy: "perform action \"AXPress\" of confirmationButton").count - 1, 1)
        XCTAssertTrue(source.contains("my verifyUploadMenuState()\n        perform action \"AXPress\" of pasteItem"))
    }

    private func context() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var listener;
        var document = {};
        var input = {tagName:'INPUT', type:'file', isConnected:true, ownerDocument:document,
          disabled:false, files:[], addEventListener:function(_, f){listener=f;},
          removeEventListener:function(){listener=null;}, click:function(){}};
        document.querySelector = function(){return input;};
        var window = {location:{href:'https://fixture.invalid/upload'}};
        """)
        return context
    }

    private func initialize(_ context: JSContext) {
        XCTAssertEqual(context.evaluateScript(NativeUploadScript.initializeJS(selector: "#upload", nonce: "fixture"))?.toString(), "OK")
        XCTAssertNil(context.exception)
    }

    private func result(_ context: JSContext) -> String? {
        context.evaluateScript(NativeUploadScript.completionJS(selector: "#upload", nonce: "fixture", fileName: "café.txt", fileSize: 17, modificationTimeMilliseconds: 123456))?.toString()
    }

    func testMetadataValidatorExecutesRealJavaScript() throws {
        let context = try context()
        initialize(context)
        XCTAssertEqual(result(context), "PENDING")
        context.evaluateScript("input.files=[{name:'cafe\\u0301.txt',size:17,lastModified:123457}];listener({target:input,isTrusted:true});")
        XCTAssertEqual(result(context), "OK")
        for (mutation, expected) in [
            ("input.files=[]", "MISMATCH_COUNT"),
            ("input.files.push(input.files[0])", "MISMATCH_COUNT"),
            ("input.files[0].size=18", "MISMATCH_SIZE"),
            ("input.files[0].name='other.txt'", "MISMATCH_NAME"),
            ("input.files[0].lastModified=123458", "MISMATCH_TIME"),
            ("input.files[0].lastModified=NaN", "MISMATCH_TIME")
        ] {
            context.evaluateScript("input.files=[{name:'café.txt',size:17,lastModified:123456}];" + mutation)
            XCTAssertEqual(result(context), expected, mutation)
        }
        XCTAssertNil(context.exception)
    }

    func testOldSelectionAndChangedOwnerCannotSucceed() throws {
        let context = try context()
        initialize(context)
        context.evaluateScript("input.files=[{name:'café.txt',size:17,lastModified:123456}]")
        XCTAssertEqual(result(context), "PENDING", "Old selection cannot prove this attempt succeeded")
        context.evaluateScript("listener({target:input,isTrusted:true});window.location.href='https://fixture.invalid/elsewhere'")
        XCTAssertEqual(result(context), "OWNER_CHANGED")
    }

    func testElementReplacementAndDetachmentRejected() throws {
        for mutation in ["input.isConnected=false", "document.querySelector=function(){return {}}", "input.ownerDocument={}", "input.type='text'", "input.disabled=true"] {
            let context = try context()
            initialize(context)
            context.evaluateScript(mutation)
            XCTAssertEqual(result(context), "OWNER_CHANGED", mutation)
        }
    }

    func testCleanupRemovesOnlyOwnPageStateAndListener() throws {
        let context = try context()
        initialize(context)
        XCTAssertEqual(context.evaluateScript(NativeUploadScript.cleanupJS(nonce: "fixture"))?.toString(), "OK")
        XCTAssertTrue(context.evaluateScript("listener === null")!.toBool())
        XCTAssertEqual(result(context), "OWNER_CHANGED")
    }

    func testUntrustedChangeCannotTurnOldSelectionIntoSuccess() throws {
        let context = try context()
        initialize(context)
        context.evaluateScript("input.files=[{name:'café.txt',size:17,lastModified:123456}];listener({target:input,isTrusted:false})")
        XCTAssertEqual(result(context), "PENDING")
    }

    func testRefSelectorAndEscapedNonceExecuteWithoutInjection() throws {
        let context = try context()
        context.evaluateScript("window.__sbRefs=[input]")
        let nonce = "'\\\n\u{2028};throw Error('injected');"
        XCTAssertEqual(context.evaluateScript(NativeUploadScript.initializeJS(selector: "@e1", nonce: nonce))?.toString(), "OK")
        XCTAssertEqual(context.evaluateScript(NativeUploadScript.ownerJS(selector: "@e1", nonce: nonce))?.toString(), "OK")
        context.evaluateScript("window.__sbRefs=[{}]")
        XCTAssertEqual(context.evaluateScript(NativeUploadScript.ownerJS(selector: "@e1", nonce: nonce))?.toString(), "OWNER_CHANGED")
        XCTAssertNil(context.exception)
    }

    func testActualAppleScriptGuardsRejectBeforeDispatch() async throws {
        let source = script()
        func handler(_ name: String) throws -> String {
            let begin = try XCTUnwrap(source.range(of: "on \(name)()"))
            let end = try XCTUnwrap(source.range(of: "end \(name)", range: begin.lowerBound..<source.endIndex))
            return String(source[begin.lowerBound..<end.upperBound])
        }
        let deadline = try handler("checkUploadDeadline").replacingOccurrences(
            of: "((current application's NSProcessInfo's processInfo()'s systemUptime()) as real)", with: "clockTick")
        let clipboard = try handler("checkUploadClipboard").replacingOccurrences(
            of: "((current application's NSPasteboard's generalPasteboard()'s changeCount()) as integer)", with: "pasteboardCount")
        XCTAssertFalse(deadline.contains("current application"))
        XCTAssertFalse(clipboard.contains("current application"))
        for (beforeTick, afterTick, beforeClipboard, afterClipboard, owner, prefix, checked) in [
            (0, 1, 42, 42, true, "OK", true),
            (10, 10, 42, 42, true, "Native upload deadline expired", false),
            (0, 10, 42, 42, true, "Native upload deadline expired", true),
            (0, 1, 43, 42, true, "Clipboard changed", false),
            (0, 1, 42, 43, true, "Clipboard changed", true),
            (0, 1, 42, 42, false, "owner", true)
        ] {
            let isolated = """
            property clockTick : \(beforeTick)
            property pasteboardCount : \(beforeClipboard)
            property uploadEndTime : 10
            property ownerChecked : false
            \(deadline)
            \(clipboard)
            on verifyUploadOwner()
                set ownerChecked to true
                if not \(owner ? "true" : "false") then error "owner"
                set clockTick to \(afterTick)
                set pasteboardCount to \(afterClipboard)
            end verifyUploadOwner
            try
                \(NativeUploadScript.stateGuardScript())
                return "OK:" & ownerChecked
            on error messageText
                return messageText & ":" & ownerChecked
            end try
            """
            let outcome = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", isolated], timeout: 3)
            XCTAssertTrue(outcome.hasPrefix(prefix), outcome)
            XCTAssertTrue(outcome.hasSuffix(checked ? ":true" : ":false"), outcome)
        }
    }

    func testInitialNativeTabIsCapturedBeforeActivation() {
        let source = script()
        XCTAssertTrue(source.contains("set uploadTabIndex to index of current tab of window id uploadWindowID"))
        XCTAssertTrue(source.contains("if index of current tab of window id uploadWindowID is not uploadTabIndex"))
        XCTAssertTrue(source.contains("my verifyUploadNativeTarget()\n    activate"))
        XCTAssertTrue(source.contains("my verifyUploadNativeTarget()\n    set index of window id uploadWindowID to 1"))
    }

    func testMenuTrackingAvoidsSafariAppleEventsAndCancelsOwnedMenuBeforePageCleanup() throws {
        let source = script()
        let opened = try XCTUnwrap(source.range(of: "perform action \"AXPress\" of editItem"))
        let pasted = try XCTUnwrap(source.range(of: "perform action \"AXPress\" of pasteItem", range: opened.upperBound..<source.endIndex))
        let tracking = String(source[opened.upperBound..<pasted.lowerBound])
        for forbidden in ["verifyUploadPanel()", "verifyUploadState()", "verifyUploadOwner()", "verifyUploadNativeTarget()", "do JavaScript", "tell application \"Safari\""] {
            XCTAssertFalse(tracking.contains(forbidden), forbidden)
        }
        XCTAssertTrue(tracking.contains("my verifyUploadMenuState()"))
        XCTAssertTrue(source.contains("set uploadAXWindow to front window"))
        XCTAssertTrue(source.contains("my cancelOwnedUploadMenu()\n    my cleanupUploadPage()"))
        XCTAssertTrue(source.contains("if uploadMenuTracking then return"))
    }

    func testMenuGuardTransitiveHelpersNeverSendSafariAppleEvents() throws {
        let source = script()
        for name in ["verifyUploadMenuState", "verifyUploadAXPanel", "verifyUploadAXOwner", "checkUploadDeadline", "checkUploadClipboard"] {
            let begin = try XCTUnwrap(source.range(of: "on \(name)()"))
            let end = try XCTUnwrap(source.range(of: "end \(name)", range: begin.lowerBound..<source.endIndex))
            let handler = String(source[begin.lowerBound..<end.upperBound])
            for forbidden in ["tell application \"Safari\"", "do JavaScript", "verifyUploadState()", "verifyUploadOwner()", "verifyUploadNativeTarget()"] {
                XCTAssertFalse(handler.contains(forbidden), "\(name): \(forbidden)")
            }
        }
    }

    func testPasteExplicitlyClosesOwnedEditMenuBeforeSafariCalls() throws {
        let source = script()
        XCTAssertFalse(source.contains("AXSelected"))
        XCTAssertFalse(source.contains("awaitUploadMenuClosed"))
        XCTAssertTrue(source.contains("set uploadAXWindowName to name of uploadAXWindow"))
        XCTAssertTrue(source.contains("if name of uploadAXWindow is not uploadAXWindowName"))
        let pasted = try XCTUnwrap(source.range(of: "perform action \"AXPress\" of pasteItem"))
        let resumed = try XCTUnwrap(source.range(of: "my verifyUploadState()", range: pasted.upperBound..<source.endIndex))
        XCTAssertTrue(source[pasted.upperBound..<resumed.lowerBound].contains("my closeOwnedUploadMenu()"))
    }

    func testActualMenuCleanupDispatchesCancelAtMostOnceAndRefusesChangedOwner() async throws {
        let source = script()
        func handler(_ name: String) throws -> String {
            let begin = try XCTUnwrap(source.range(of: "on \(name)()"))
            let end = try XCTUnwrap(source.range(of: "end \(name)", range: begin.lowerBound..<source.endIndex))
            return String(source[begin.lowerBound..<end.upperBound])
                .replacingOccurrences(of: "tell application \"System Events\" to tell process \"Safari\"", with: "tell me")
                .replacingOccurrences(of: "exists sheet 1 of uploadAXWindow", with: "panelPresent")
                .replacingOccurrences(of: "perform action \"AXCancel\" of menu 1 of uploadEditItem", with: "my simulateAXCancel()")
        }
        let closeHandler = try handler("closeOwnedUploadMenu")
        let cleanupHandler = try handler("cancelOwnedUploadMenu")
        XCTAssertFalse(closeHandler.contains("tell application"))
        for (owner, nested, cancelFails, expected) in [
            (true, false, false, "1:false"),
            (true, false, true, "1:true"),
            (false, false, false, "0:true"),
            (true, true, false, "0:true")
        ] {
            let isolated = """
            property uploadMenuTracking : true
            property uploadMenuCancelAttempted : false
            property panelPresent : true
            property dispatchCount : 0
            \(closeHandler)
            \(cleanupHandler)
            on verifyUploadAXOwner()
                if not \(owner ? "true" : "false") then error "owner"
            end verifyUploadAXOwner
            on verifyUploadAXPanel()
                if \(nested ? "true" : "false") then error "nested"
            end verifyUploadAXPanel
            on simulateAXCancel()
                set dispatchCount to dispatchCount + 1
                if \(cancelFails ? "true" : "false") then error "unknown cancel outcome"
            end simulateAXCancel
            try
                my closeOwnedUploadMenu()
            end try
            my cancelOwnedUploadMenu()
            return (dispatchCount as text) & ":" & uploadMenuTracking
            """
            let outcome = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", isolated], timeout: 3)
            XCTAssertEqual(outcome, expected)
        }
    }

}
