import Foundation
import JavaScriptCore
import XCTest
@testable import SafariBrowser

final class NativeUploadScriptTests: XCTestCase {
    private func script(window: Int? = 2, windowID: Int? = nil, tabIndex: Int? = nil, deadlineUptime: Double? = nil) -> String {
        NativeUploadScript.make(selector: "input[data-name=\"a'\\b\"]", path: "/tmp/隱藏 ' café.txt", fileSize: 17, modificationTimeMilliseconds: 123456, clipboardChangeCount: 42, window: window, timeout: 8, nonce: "test-'\\nonce", windowID: windowID, tabIndex: tabIndex, deadlineUptime: deadlineUptime)
    }

    func testGeneratedScriptCompilesWithoutRunningSafari() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        for generated in [script(window: nil), script(window: 2), script(windowID: 901, tabIndex: 4, deadlineUptime: 1234.5)] {
            let source = dir.appendingPathComponent("upload.applescript")
            try generated.write(to: source, atomically: true, encoding: .utf8)
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
        XCTAssertTrue(source.contains("SBNativeUploadBridge's logConfirmation:confirmationTitle"))
        XCTAssertEqual(source.components(separatedBy: "perform action \"AXPress\" of confirmationButton").count - 1, 1)
        XCTAssertTrue(source.contains("my verifyUploadMenuState()\n        perform action \"AXPress\" of pasteItem"))
    }

    private func context() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var listener;var registered={};
        var document = {};
        var input = {tagName:'INPUT', type:'file', isConnected:true, ownerDocument:document,
          disabled:false, hasAttribute:function(){return false;}, files:[], addEventListener:function(_, f){listener=f;},
          removeEventListener:function(){listener=null;}, click:function(){}};
        document.querySelector = function(){return input;};
        var window = {location:{href:'https://fixture.invalid/upload'},addEventListener:function(t,f){registered[t]=f;listener=f;},removeEventListener:function(t){delete registered[t];listener=null;}};
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
            let fresh = try self.context()
            initialize(fresh)
            fresh.evaluateScript("input.files=[{name:'café.txt',size:17,lastModified:123456}];" + mutation + ";listener({target:input,isTrusted:true});")
            XCTAssertEqual(result(fresh), expected, mutation)
        }
        XCTAssertNil(context.exception)
    }

    func testTimestampAcceptsOnlyExactOrWholeSecondTruncation() throws {
        for (expected, observed, verdict) in [
            (123456, 123000, "OK"), (123999, 123000, "OK"),
            (-1999, -1000, "OK"), (-627, 0, "OK"),
            (123456, 124000, "MISMATCH_TIME"), (123456, 123100, "MISMATCH_TIME"),
            (123456, 122000, "MISMATCH_TIME"), (-1999, -2000, "OK"),
            (-1999, -3000, "MISMATCH_TIME")
        ] {
            let context = try context()
            initialize(context)
            context.evaluateScript("input.files=[{name:'café.txt',size:17,lastModified:\(observed)}];listener({target:input,isTrusted:true});")
            let script = NativeUploadScript.completionJS(selector: "#upload", nonce: "fixture",
                fileName: "café.txt", fileSize: 17, modificationTimeMilliseconds: Int64(expected))
            XCTAssertEqual(context.evaluateScript(script)?.toString(), verdict, "\(expected) → \(observed)")
            XCTAssertNil(context.exception, "negative timestamps must remain valid JavaScript")
        }
    }

    func testDirectoryInputRejectedInitiallyAndBeforeOpen() throws {
        for property in ["input.webkitdirectory=true", "input.hasAttribute=function(name){return name==='webkitdirectory'}"] {
            let c = try context()
            c.evaluateScript(property)
            XCTAssertEqual(c.evaluateScript(NativeUploadScript.initializeJS(selector: "#upload", nonce: "fixture"))?.toString(), "INVALID_INPUT")
            let d = try context()
            initialize(d)
            d.evaluateScript("var clicked=false;input.click=function(){clicked=true};" + property)
            XCTAssertEqual(d.evaluateScript(NativeUploadScript.openJS(selector: "#upload", nonce: "fixture"))?.toString(), "OWNER_CHANGED")
            XCTAssertFalse(d.evaluateScript("clicked")!.toBool())
        }
    }

    func testFirstDeliverySnapshotSurvivesLaterPageChanges() throws {
        let c = try context()
        initialize(c)
        c.evaluateScript("input.files=[{name:'café.txt',size:17,lastModified:123456}];listener({target:input,isTrusted:true});")
        c.evaluateScript("input.files[0].name='wrong.txt';input.files=[];input.isConnected=false;window.location.href='#received';listener({target:input,isTrusted:true});")
        XCTAssertEqual(result(c), "OK", "First delivery metadata must be copied, not reread or replaced")
        XCTAssertEqual(c.evaluateScript(NativeUploadScript.ownerJS(selector: "#upload", nonce: "fixture"))?.toString(), "OWNER_CHANGED", "A delivery snapshot must not authorize further file actions")
        XCTAssertEqual(c.evaluateScript(NativeUploadScript.cleanupJS(nonce: "fixture"))?.toString(), "OK")
        XCTAssertTrue(c.evaluateScript("listener===null && Object.keys(registered).length===0")!.toBool())
    }

    func testCompletionLoopDoesNotRevalidateConsumedInput() async throws {
        let source = script()
        let uiRead = "tell application \"System Events\" to tell process \"Safari\" to set panelStillOpen to exists sheet 1 of front window"
        let read = try XCTUnwrap(source.range(of: uiRead))
        let loop = try XCTUnwrap(source.range(of: "repeat\n", options: .backwards, range: source.startIndex..<read.lowerBound))
        for panelInitiallyPresent in [false, true] {
        var terminal = String(source[loop.lowerBound...]).replacingOccurrences(of: uiRead, with: "set panelStillOpen to my nextPanelState()")
        let selectionLine = try XCTUnwrap(terminal.split(separator: "\n").first { $0.contains("to set selectionResult to do JavaScript") })
        terminal = terminal.replacingOccurrences(of: String(selectionLine), with: "set selectionResult to \"OK\"")
        XCTAssertFalse(terminal.contains("tell application"))
        let isolated = """
        property checks : 0
        property cleaned : false
        property panelReads : 0
        on nextPanelState()
            set panelReads to panelReads + 1
            return \(panelInitiallyPresent ? "true" : "false") and panelReads is 1
        end nextPanelState
        on verifyUploadPanel()
            error "Post-delivery input must not be revalidated while sheet closes"
        end verifyUploadPanel
        on verifyUploadCompletionPanel()
        end verifyUploadCompletionPanel
        on verifyUploadCompletionTarget()
            set checks to checks + 1
        end verifyUploadCompletionTarget
        on verifyUploadState()
            error "Consumed input must not be revalidated"
        end verifyUploadState
        on cancelOwnedUploadMenu()
        end cancelOwnedUploadMenu
        on cleanupUploadPage()
            set cleaned to true
        end cleanupUploadPage
        try
            \(terminal)
        return (checks as text) & ":" & cleaned
        """
        let result = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", isolated], timeout: 3)
        XCTAssertEqual(result, panelInitiallyPresent ? "3:true" : "2:true")
        }
    }

    func testOldSelectionAndChangedOwnerCannotSucceed() throws {
        let context = try context()
        initialize(context)
        context.evaluateScript("input.files=[{name:'café.txt',size:17,lastModified:123456}]")
        XCTAssertEqual(result(context), "PENDING", "Old selection cannot prove this attempt succeeded")
        context.evaluateScript("window.location.href='https://fixture.invalid/elsewhere';listener({target:input,isTrusted:true})")
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
        let resumed = try XCTUnwrap(source.range(of: "my verifyUploadCompletionTarget()", range: pasted.upperBound..<source.endIndex))
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

    func testAbsoluteDeadlineAndStableTargetContract() throws {
        let source = script(window: 2, windowID: 901, tabIndex: 4, deadlineUptime: 1234.5)
        XCTAssertTrue(source.contains("set uploadEndTime to 1234.5"))
        XCTAssertFalse(source.contains("systemUptime()) as real) + 8"))
        XCTAssertTrue(source.contains("set uploadWindowID to id of window id 901"))
        XCTAssertTrue(source.contains("if uploadTabIndex is not 4 then error"))
        XCTAssertTrue(source.contains("with timeout of 1 second"))
        let tabCheck = try XCTUnwrap(source.range(of: "if uploadTabIndex is not 4 then error"))
        let raise = try XCTUnwrap(source.range(of: "set index of window id uploadWindowID to 1"))
        XCTAssertLessThan(tabCheck.lowerBound, raise.lowerBound)
        for name in ["cancelOwnedUploadMenu", "cleanupUploadPage"] {
            let begin = try XCTUnwrap(source.range(of: "on \(name)()"))
            let end = try XCTUnwrap(source.range(of: "end \(name)", range: begin.lowerBound..<source.endIndex))
            XCTAssertTrue(source[begin.lowerBound..<end.upperBound].contains("with timeout of 1 second"))
        }
    }

    func testOrdinaryPendingExpiryDispatchesCleanupBeforeOuterWatchdog() async throws {
        let startTime = ProcessInfo.processInfo.systemUptime
        let source = script(deadlineUptime: startTime + 0.8)
        let deadlineAssignment = try XCTUnwrap(source.split(separator: "\n").first { $0.hasPrefix("set uploadEndTime to ") })
        let begin = try XCTUnwrap(source.range(of: "on checkUploadDeadline()"))
        let end = try XCTUnwrap(source.range(of: "end checkUploadDeadline", range: begin.lowerBound..<source.endIndex))
        let deadlineHandler = String(source[begin.lowerBound..<end.upperBound])
        let uiRead = "tell application \"System Events\" to tell process \"Safari\" to set panelStillOpen to exists sheet 1 of front window"
        let readRange = try XCTUnwrap(source.range(of: uiRead))
        let loop = try XCTUnwrap(source.range(of: "repeat\n", options: .backwards, range: source.startIndex..<readRange.lowerBound))
        var terminal = String(source[loop.lowerBound...])
            .replacingOccurrences(of: uiRead, with: "set panelStillOpen to false")
        let selectionLine = try XCTUnwrap(terminal.split(separator: "\n").first { $0.contains("to set selectionResult to do JavaScript") })
        terminal = terminal.replacingOccurrences(of: String(selectionLine), with: "set selectionResult to \"PENDING\"")
        XCTAssertFalse(terminal.contains("tell application"))
        let isolated = """
        use framework "Foundation"
        use scripting additions
        property uploadEndTime : 0
        property menuCleanupCalled : false
        property pageCleanupCalled : false
        \(deadlineHandler)
        on verifyUploadCompletionTarget()
            my checkUploadDeadline()
        end verifyUploadCompletionTarget
        on cancelOwnedUploadMenu()
            set menuCleanupCalled to true
        end cancelOwnedUploadMenu
        on cleanupUploadPage()
            set pageCleanupCalled to true
        end cleanupUploadPage
        \(deadlineAssignment)
        try
            try
                \(terminal)
        on error finalError
            return finalError & "|" & menuCleanupCalled & "|" & pageCleanupCalled
        end try
        """
        let result = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", isolated], timeout: 3)
        XCTAssertTrue(result.hasPrefix("Native upload deadline expired"), result)
        XCTAssertTrue(result.hasSuffix("|true|true"), result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startTime, 3)
    }

    func testPreconfirmationExecutesNativeSelectionAndRejectsUncertainEvidence() async throws {
        let source = script()
        let begin = try XCTUnwrap(source.range(of: "-- Paste can accept directly"))
        let terminal = "    repeat\n        my verifyUploadCompletionTarget()"
        let end = try XCTUnwrap(source.range(of: terminal, range: begin.upperBound..<source.endIndex))
        var fragment = String(source[begin.lowerBound..<end.lowerBound])
        let selection = try XCTUnwrap(fragment.split(separator: "\n").first { $0.contains("to set selectionResult to do JavaScript") })
        fragment = fragment.replacingOccurrences(of: String(selection), with: "set selectionResult to observedDelivery")
        let buttons = try XCTUnwrap(fragment.range(of: "set fileButtons to buttons of uploadPanel"))
        let title = try XCTUnwrap(fragment.range(of: "set confirmationTitle to title of confirmationButton", range: buttons.lowerBound..<fragment.endIndex))
        fragment.replaceSubrange(buttons.lowerBound..<title.upperBound, with: "set confirmationTitle to \"Open\"")
        fragment = fragment
            .replacingOccurrences(of: "tell application \"System Events\" to tell process \"Safari\"", with: "tell me")
            .replacingOccurrences(of: "(exists sheet 1 of front window)", with: "true")
            .replacingOccurrences(of: "perform action \"AXPress\" of confirmationButton", with: "set dispatchCount to dispatchCount + 1")
            .replacingOccurrences(of: "current application's SBNativeUploadBridge's logConfirmation:confirmationTitle", with: "my recordConfirmation(confirmationTitle)")
        XCTAssertFalse(fragment.contains("tell application"))
        for (delivery, evidence, clipboardChangesAtRead, expectedDispatch, minimumReads) in [
            ("PENDING", "MATCH", 0, 1, 1),
            ("PENDING", "UNKNOWN", 0, 0, 1),
            ("PENDING", "MISMATCH", 0, 0, 1),
            ("PENDING", "AMBIGUOUS", 0, 0, 1),
            ("PENDING", "MATCH", 1, 0, 1),
            ("PENDING", "MATCH", 2, 0, 2),
            ("OK", "UNKNOWN", 0, 0, 0)
        ] {
            let isolated = """
            property observedDelivery : "\(delivery)"
            property dispatchCount : 0
            property reads : 0
            property staleClipboard : false
            on checkUploadDeadline()
            end checkUploadDeadline
            on checkUploadClipboard()
                if staleClipboard then error "clipboard changed"
            end checkUploadClipboard
            on verifyUploadCompletionTarget()
                my checkUploadClipboard()
            end verifyUploadCompletionTarget
            on verifyUploadPanel()
                my checkUploadClipboard()
            end verifyUploadPanel
            on readUploadSelection()
                set reads to reads + 1
                if reads is \(clipboardChangesAtRead) then set staleClipboard to true
                return "\(evidence)"
            end readUploadSelection
            on recordConfirmation(t)
            end recordConfirmation
            try
                \(fragment)
            end try
            return (dispatchCount as text) & ":" & reads
            """
            let outcome = try await SafariBridge.runShell("/usr/bin/osascript", ["-e", isolated], timeout: 3)
            print("native evidence adapter: \(delivery)/\(evidence)/\(clipboardChangesAtRead) -> \(outcome)")
            let fields = outcome.split(separator: ":")
            XCTAssertEqual(fields.first, Substring(String(expectedDispatch)), "\(delivery)/\(evidence)/\(clipboardChangesAtRead): \(outcome)")
            XCTAssertGreaterThanOrEqual(Int(fields.last ?? "") ?? -1, minimumReads)
        }
    }

}
