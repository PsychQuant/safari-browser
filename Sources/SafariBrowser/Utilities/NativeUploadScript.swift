import Foundation

/// One bounded native chooser transaction. The clipboard lease belongs to the
/// Swift caller; this script only verifies that its file URL is still owned.
/// AX acknowledgments never count as upload completion.
enum NativeUploadScript {
    private static func stateKey(_ nonce: String) -> String { "__sbNativeUpload_" + nonce }

    /// The receipt literal occurs only in this initializer's private scope. No
    /// later query embeds it and exposed function source cannot reveal it.
    static func initializeJS(selector: String, nonce: String, fileName: String, fileSize: Int64,
                             modificationTimeMilliseconds: Int64, receiptToken: String, lifetimeMilliseconds: Double = 30_000) -> String {
        """
        (function(){
            var key='\(stateKey(nonce).escapedForJS)';
            var call=Function.prototype.call.bind(Function.prototype.call);
            var own=Object.prototype.hasOwnProperty, descriptor=Object.getOwnPropertyDescriptor;
            var define=Object.defineProperty, freeze=Object.freeze;
            if(call(own,window,key)) return 'STATE_COLLISION';
            var el=\(selector.resolveRefJS);
            if(!el) return 'NOT_FOUND';
            if(el.tagName!=='INPUT' || el.type!=='file' || el.webkitdirectory || el.hasAttribute('webkitdirectory') || el.disabled || !el.isConnected || el.ownerDocument!==document) return 'INVALID_INPUT';
            var receipt='\(receiptToken.escapedForJS)', expectedName='\(fileName.escapedForJS)';
            var expectedSize=\(fileSize), expectedModified=\(modificationTimeMilliseconds);
            var doc=document, pageURL=window.location.href, status=null, disposed=false, timer=null, api;
            var schedule=window.setTimeout, cancel=window.clearTimeout;
            var add=EventTarget.prototype.addEventListener, remove=EventTarget.prototype.removeEventListener;
            var target=descriptor(Event.prototype,'target').get;
            var files=descriptor(HTMLInputElement.prototype,'files').get;
            var length=descriptor(FileList.prototype,'length').get, item=FileList.prototype.item;
            var name=descriptor(File.prototype,'name').get, modified=descriptor(File.prototype,'lastModified').get;
            var size=descriptor(Blob.prototype,'size').get;
            var normalize=String.prototype.normalize, finite=Number.isFinite, abs=Math.abs, trunc=Math.trunc;
            function owner(){
                if(disposed || doc!==document || pageURL!==window.location.href || !el ||
                   !el.isConnected || el.disabled || el.ownerDocument!==document || el.type!=='file' ||
                   el.webkitdirectory || el.hasAttribute('webkitdirectory') || el!==\(selector.resolveRefJS)) return 'OWNER_CHANGED';
                return 'OK';
            }
            function validate(){
                var list=call(files,el);
                if(!list || call(length,list)!==1) return 'MISMATCH_COUNT';
                var f=call(item,list,0), n=call(name,f), s=call(size,f), m=call(modified,f);
                if(typeof n!=='string' || call(normalize,n,'NFC')!==call(normalize,expectedName,'NFC')) return 'MISMATCH_NAME';
                if(s!==expectedSize) return 'MISMATCH_SIZE';
                // WebKit can expose seconds truncated toward zero; accept only
                // that representation or the original millisecond value.
                if(!finite(m) || (abs(m-expectedModified)>1 && m!==trunc(expectedModified/1000)*1000)) return 'MISMATCH_TIME';
                return 'MATCH';
            }
            function listener(event){
                if(disposed || status!==null) return;
                try {
                    if(call(target,event)!==el || event.isTrusted!==true) return;
                    if(owner()!=='OK'){status='OWNER_CHANGED';return;}
                    status=validate();
                } catch (_) {status='OWNER_CHANGED';}
            }
            function read(){
                if(disposed) return 'OWNER_CHANGED';
                if(status==='MATCH') return receipt;
                if(status!==null) return status;
                return owner()==='OK' ? 'PENDING' : 'OWNER_CHANGED';
            }
            function open(){
                var result=owner();
                if(result!=='OK') return result;
                el.click();
                return 'OK';
            }
            function dispose(){
                if(disposed) return 'SKIPPED';
                disposed=true;
                if(timer!==null){call(cancel,window,timer);timer=null;}
                call(remove,window,'input',listener,true);
                call(remove,window,'change',listener,true);
                el=null; doc=null; receipt=null; status=null; expectedName=null;
                if(window[key]===api) delete window[key];
                return 'OK';
            }
            api=freeze({read:read,owner:owner,open:open,dispose:dispose});
            define(window,key,{value:api,configurable:true});
            call(add,window,'input',listener,true);
            call(add,window,'change',listener,true);
            // Best effort only: background pages may throttle timers.
            timer=call(schedule,window,dispose,\(lifetimeMilliseconds));
            return 'OK';
        })()
        """
    }

    static func ownerJS(selector: String, nonce: String) -> String {
        "(function(){var state=window['\(stateKey(nonce).escapedForJS)'];return state && typeof state.owner==='function' ? state.owner() : 'OWNER_CHANGED';})()"
    }

    static func openJS(selector: String, nonce: String) -> String {
        "(function(){var state=window['\(stateKey(nonce).escapedForJS)'];return state && typeof state.open==='function' ? state.open() : 'OWNER_CHANGED';})()"
    }

    /// Raw receipt or diagnostic only. The native caller must compare the receipt
    /// outside the page realm; an untrusted replacement returning OK is not proof.
    static func completionJS(selector: String, nonce: String) -> String {
        "(function(){var state=window['\(stateKey(nonce).escapedForJS)'];return state && typeof state.read==='function' ? state.read() : 'OWNER_CHANGED';})()"
    }

    static func cleanupJS(nonce: String) -> String {
        "(function(){var state=window['\(stateKey(nonce).escapedForJS)'];return state && typeof state.dispose==='function' ? state.dispose() : 'SKIPPED';})()"
    }

    /// Kept as a fragment so tests can execute the actual guard with private,
    /// deterministic clock/pasteboard/owner adapters and no Safari interaction.
    static func stateGuardScript() -> String {
        """
        my checkUploadDeadline()
        my checkUploadClipboard()
        my verifyUploadOwner()
        my checkUploadDeadline()
        my checkUploadClipboard()
        """
    }

    /// The token never occurs in a subsequent page query. A replaced page
    /// state can return status text, but only this exact private receipt succeeds.
    static func receiptValidationScript(receiptToken: String) -> String {
        """
        considering case
            if rawReceipt is "\(receiptToken.escapedForAppleScript)" then return "OK"
            if rawReceipt is in {"PENDING", "OWNER_CHANGED", "MISMATCH_COUNT", "MISMATCH_NAME", "MISMATCH_SIZE", "MISMATCH_TIME"} then return rawReceipt
        end considering
        return "INVALID_RECEIPT"
        """
    }

    static func make(selector: String, path: String, fileSize: Int64, modificationTimeMilliseconds: Int64, clipboardChangeCount: Int, window: Int?, timeout: Double, nonce: String, windowID: Int? = nil, tabIndex: Int? = nil, deadlineUptime: Double? = nil) -> String {
        let receiptToken = "SB_UPLOAD_RECEIPT:" + UUID().uuidString
        let initial = initializeJS(selector: selector, nonce: nonce,
            fileName: URL(fileURLWithPath: path).lastPathComponent, fileSize: fileSize,
            modificationTimeMilliseconds: modificationTimeMilliseconds,
            receiptToken: receiptToken, lifetimeMilliseconds: (timeout + 3) * 1000).escapedForAppleScript
        let owner = ownerJS(selector: selector, nonce: nonce).escapedForAppleScript
        let open = openJS(selector: selector, nonce: nonce).escapedForAppleScript
        let completion = completionJS(selector: selector, nonce: nonce).escapedForAppleScript
        let cleanup = cleanupJS(nonce: nonce).escapedForAppleScript
        let targetWindow = windowID.map { "window id \($0)" } ?? window.map { "window \($0)" } ?? "front window"
        let expectedTabGuard = tabIndex.map { "if uploadTabIndex is not \($0) then error \"Native upload target tab changed before capture\"" } ?? ""
        // Production provides an absolute monotonic deadline before spawning
        // osascript, reserving time within its unchanged watchdog for cleanup.
        let endTime = deadlineUptime.map(String.init(describing:))
            ?? "((current application's NSProcessInfo's processInfo()'s systemUptime()) as real) + \(timeout)"
        return """
        use framework "Foundation"
        use framework "AppKit"
        use scripting additions

        property uploadWindowID : missing value
        property uploadPageURL : missing value
        property uploadTabIndex : missing value
        property uploadEndTime : 0
        property uploadPanel : missing value
        property uploadAXWindow : missing value
        property uploadAXWindowName : missing value
        property uploadEditItem : missing value
        property uploadMenuTracking : false
        property uploadMenuCancelAttempted : false
        property uploadInitialized : false

        on checkUploadDeadline()
            if ((current application's NSProcessInfo's processInfo()'s systemUptime()) as real) >= uploadEndTime then error "Native upload deadline expired; no verified new file selection. Inspect and cancel any remaining chooser before retrying"
        end checkUploadDeadline

        on checkUploadClipboard()
            if ((current application's NSPasteboard's generalPasteboard()'s changeCount()) as integer) is not \(clipboardChangeCount) then error "Clipboard changed during native upload; no further file action was sent"
        end checkUploadClipboard

        on readUploadCompletion()
            tell application "Safari" to set rawReceipt to do JavaScript "\(completion)" in current tab of window id uploadWindowID
            \(receiptValidationScript(receiptToken: receiptToken))
        end readUploadCompletion

        on readUploadSelection()
            return (current application's SBNativeUploadBridge's selectionForWindow:uploadWindowID) as text
        end readUploadSelection

        on verifyUploadNativeTarget()
            tell application "Safari"
                if not (exists window id uploadWindowID) then error "Native upload target window disappeared"
                if index of current tab of window id uploadWindowID is not uploadTabIndex then error "Native upload target tab changed"
                if URL of current tab of window id uploadWindowID is not uploadPageURL then error "Native upload target page changed"
            end tell
        end verifyUploadNativeTarget

        on verifyUploadOwner()
            my verifyUploadNativeTarget()
            tell application "Safari"
                if id of front window is not uploadWindowID then error "Native upload target window changed"
                if (do JavaScript "\(owner)" in current tab of window id uploadWindowID) is not "OK" then error "Native upload target tab, document or input changed"
            end tell
            tell application "System Events" to tell process "Safari"
                if not frontmost then error "Safari lost focus during native upload"
            end tell
        end verifyUploadOwner

        on verifyUploadState()
            \(stateGuardScript())
        end verifyUploadState

        -- After delivery, page handlers can consume the input or change its
        -- same-document URL. This read-only phase still binds window/tab and
        -- foreground; completion JS checks the original document/event snapshot.
        on verifyUploadCompletionTarget()
            my checkUploadDeadline()
            my checkUploadClipboard()
            tell application "Safari"
                if not (exists window id uploadWindowID) then error "Native upload target window disappeared"
                if index of current tab of window id uploadWindowID is not uploadTabIndex then error "Native upload target tab changed"
                if id of front window is not uploadWindowID then error "Native upload target window changed"
            end tell
            tell application "System Events" to tell process "Safari"
                if not frontmost then error "Safari lost focus during native upload"
                if not (exists uploadAXWindow) then error "Native upload AX window disappeared"
                if front window is not uploadAXWindow then error "Native upload AX window changed"
            end tell
            my checkUploadDeadline()
            my checkUploadClipboard()
        end verifyUploadCompletionTarget

        -- A delivered file can trigger page handlers before AX removes the
        -- closing sheet. Waiting here never authorizes another file action.
        on verifyUploadCompletionPanel()
            my verifyUploadCompletionTarget()
            tell application "System Events" to tell process "Safari"
                if (count of sheets of uploadAXWindow) is 0 then return
                if (count of sheets of uploadAXWindow) is not 1 then error "The unique owned file dialog is unavailable"
                if not (exists uploadPanel) then error "Owned file dialog disappeared"
                if sheet 1 of uploadAXWindow is not uploadPanel then error "File dialog ownership changed"
                if exists sheet 1 of uploadPanel then error "Nested sheet appeared; no file confirmation was sent"
            end tell
        end verifyUploadCompletionPanel

        on verifyUploadAXOwner()
            tell application "System Events" to tell process "Safari"
                if not frontmost then error "Safari lost focus during native upload"
                if not (exists uploadAXWindow) then error "Native upload AX window disappeared"
                if front window is not uploadAXWindow then error "Native upload AX window changed"
                if name of uploadAXWindow is not uploadAXWindowName then error "Native upload AX window title changed"
            end tell
        end verifyUploadAXOwner

        on verifyUploadAXPanel()
            my verifyUploadAXOwner()
            tell application "System Events" to tell process "Safari"
                if (count of sheets of uploadAXWindow) is not 1 then error "The unique owned file dialog is unavailable"
                if not (exists uploadPanel) then error "Owned file dialog disappeared"
                if sheet 1 of uploadAXWindow is not uploadPanel then error "File dialog ownership changed"
                if exists sheet 1 of uploadPanel then error "Nested sheet appeared; no file confirmation was sent"
            end tell
        end verifyUploadAXPanel

        on verifyUploadPanel()
            my verifyUploadState()
            my verifyUploadAXPanel()
        end verifyUploadPanel

        -- Safari AppleEvents can block while its Edit menu tracks. Within that
        -- interval, use only the captured AX window/panel, clock and clipboard.
        on verifyUploadMenuState()
            my checkUploadDeadline()
            my checkUploadClipboard()
            my verifyUploadAXPanel()
            my checkUploadDeadline()
            my checkUploadClipboard()
        end verifyUploadMenuState

        -- Menu attributes remain unchanged after Paste on measured
        -- Safari builds. Explicit AXCancel ends this script's Edit tracking;
        -- it is never a file confirmation and is dispatched at most once.
        on closeOwnedUploadMenu()
            if not uploadMenuTracking then return
            if uploadMenuCancelAttempted then error "Edit menu close outcome is uncertain; no further upload action was sent"
            my verifyUploadAXOwner()
            tell application "System Events" to tell process "Safari"
                if exists sheet 1 of uploadAXWindow then my verifyUploadAXPanel()
            end tell
            set uploadMenuCancelAttempted to true
            tell application "System Events" to tell process "Safari"
                perform action "AXCancel" of menu 1 of uploadEditItem
            end tell
            set uploadMenuTracking to false
        end closeOwnedUploadMenu

        on cancelOwnedUploadMenu()
            if not uploadMenuTracking then return
            if uploadMenuCancelAttempted then return
            try
                with timeout of 1 second
                    my closeOwnedUploadMenu()
                end timeout
            end try
        end cancelOwnedUploadMenu

        on cleanupUploadPage()
            if uploadMenuTracking then return
            if not uploadInitialized then return
            -- Best effort only: each cleanup AppleEvent has a short timeout;
            -- the outer watchdog still bounds stalled IPC or process death.
            try
                with timeout of 1 second
                    tell application "Safari"
                        if exists window id uploadWindowID then
                            if index of current tab of window id uploadWindowID is uploadTabIndex then
                                do JavaScript "\(cleanup)" in current tab of window id uploadWindowID
                            end if
                        end if
                    end tell
                end timeout
            end try
        end cleanupUploadPage

        set uploadEndTime to \(endTime)
        my checkUploadDeadline()
        my checkUploadClipboard()
        tell application "Safari"
            set uploadWindowID to id of \(targetWindow)
            set uploadTabIndex to index of current tab of window id uploadWindowID
            \(expectedTabGuard)
            set uploadPageURL to URL of current tab of window id uploadWindowID
            my checkUploadDeadline()
            my checkUploadClipboard()
            my verifyUploadNativeTarget()
            set index of window id uploadWindowID to 1
            my checkUploadDeadline()
            my checkUploadClipboard()
            my verifyUploadNativeTarget()
            activate
        end tell
        try
            repeat
                my checkUploadDeadline()
                my checkUploadClipboard()
                tell application "System Events" to tell process "Safari" to set uploadFrontmost to frontmost
                if uploadFrontmost then exit repeat
                delay 0.05
            end repeat
            my verifyUploadNativeTarget()
            tell application "Safari"
                if id of front window is not uploadWindowID then error "Native upload target window changed before opening"
                if URL of current tab of window id uploadWindowID is not uploadPageURL then error "Native upload target page changed before opening"
            end tell
            tell application "System Events" to tell process "Safari"
                if exists sheet 1 of front window then error "Unexpected sheet before native upload; no chooser was opened"
                set uploadAXWindow to front window
                set uploadAXWindowName to name of uploadAXWindow
            end tell
            my checkUploadDeadline()
            my checkUploadClipboard()
            tell application "Safari" to set initialResult to do JavaScript "\(initial)" in current tab of window id uploadWindowID
            if initialResult is "NOT_FOUND" then error "SB_UPLOAD_INPUT_NOT_FOUND"
            if initialResult is "INVALID_INPUT" then error "SB_UPLOAD_INVALID_INPUT"
            if initialResult is not "OK" then error "Native upload input preparation failed: " & initialResult
            set uploadInitialized to true
            my verifyUploadState()
            tell application "System Events" to tell process "Safari"
                if exists sheet 1 of front window then error "Unexpected sheet before native upload; no chooser was opened"
            end tell
            my verifyUploadState()
            tell application "Safari" to set openResult to do JavaScript "\(open)" in current tab of window id uploadWindowID
            if openResult is not "OK" then error "Native upload input could not open its chooser: " & openResult

            repeat
                my verifyUploadState()
                tell application "System Events" to tell process "Safari"
                    if exists sheet 1 of front window then
                        if (count sheets of front window) is not 1 then error "Multiple native upload sheets appeared"
                        set uploadPanel to sheet 1 of front window
                        exit repeat
                    end if
                end tell
                delay 0.1
            end repeat
            my verifyUploadPanel()
            tell application "System Events" to tell process "Safari"
                set editMenus to menu bar items of menu bar 1 whose name is "Edit" or name is "編輯"
                if (count editMenus) is not 1 then error "A unique Edit menu is unavailable for native upload"
                set editItem to item 1 of editMenus
                if not (enabled of editItem) then error "Edit menu is disabled for native upload"
                my verifyUploadPanel()
                set uploadEditItem to editItem
                set uploadMenuTracking to true
                perform action "AXPress" of editItem
                set pasteItems to menu items of menu 1 of editItem whose name is "Paste" or name is "貼上"
                if (count pasteItems) is not 1 then error "A unique Paste menu item is unavailable for native upload"
                set pasteItem to item 1 of pasteItems
                if not (enabled of pasteItem) then error "Paste is disabled for native upload"
                my verifyUploadMenuState()
                perform action "AXPress" of pasteItem
            end tell

            my checkUploadDeadline()
            my checkUploadClipboard()
            my closeOwnedUploadMenu()

            -- Paste can accept directly or leave an initial confirmation.
            delay 0.1
            my verifyUploadCompletionTarget()
            set selectionResult to my readUploadCompletion()
            if selectionResult is not "OK" and selectionResult is not "PENDING" then error "Native upload selected file verification failed: " & selectionResult
            tell application "System Events" to tell process "Safari"
                if (exists sheet 1 of front window) and selectionResult is not "OK" then
                    my verifyUploadPanel()
                    if my readUploadSelection() is not "MATCH" then error "Native file selection is unavailable, ambiguous or does not match the requested file; no confirmation was sent"
                    my verifyUploadPanel()
                    set fileButtons to buttons of uploadPanel
                    repeat with panelGroup in splitter groups of uploadPanel
                        set fileButtons to fileButtons & (buttons of panelGroup)
                    end repeat
                    set confirmationButtons to {}
                    repeat with candidateButton in fileButtons
                        if (title of candidateButton) is in {"Open", "Upload", "打開", "開啟", "上傳"} then
                            set end of confirmationButtons to contents of candidateButton
                        end if
                    end repeat
                    if (count confirmationButtons) is not 1 then error "A unique named Open/Upload button is unavailable; no file confirmation was sent"
                    set confirmationButton to item 1 of confirmationButtons
                    if not (enabled of confirmationButton) then error "The named upload confirmation button is disabled; no confirmation was sent"
                    set confirmationTitle to title of confirmationButton
                    my verifyUploadPanel()
                    my verifyUploadPanel()
                    if my readUploadSelection() is not "MATCH" then error "Native file selection changed before confirmation; no confirmation was sent"
                    my checkUploadDeadline()
                    my checkUploadClipboard()
                    current application's SBNativeUploadBridge's logConfirmation:confirmationTitle
                    perform action "AXPress" of confirmationButton
                end if
            end tell

            repeat
                my verifyUploadCompletionTarget()
                tell application "System Events" to tell process "Safari" to set panelStillOpen to exists sheet 1 of front window
                if panelStillOpen then
                    my verifyUploadCompletionPanel()
                else
                    set selectionResult to my readUploadCompletion()
                    if selectionResult is "OK" then exit repeat
                    if selectionResult is not "PENDING" then error "Native upload selected file verification failed: " & selectionResult
                end if
                delay 0.1
            end repeat
            my verifyUploadCompletionTarget()
            my cleanupUploadPage()
        on error uploadError number uploadErrorNumber
            my cancelOwnedUploadMenu()
            my cleanupUploadPage()
            error uploadError number uploadErrorNumber
        end try
        """
    }
}
