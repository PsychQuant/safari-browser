import ArgumentParser
import Foundation

struct UploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload a file via file input element"
    )

    @Argument(help: "CSS selector of the file input element")
    var selector: String

    @Argument(help: "Path to the file to upload")
    var filePath: String

    @Flag(name: .long, help: "Allow keyboard/mouse simulation for file dialog (System Events)")
    var allowHid = false

    func run() async throws {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SafariBrowserError.fileNotFound(filePath)
        }

        // Try JS programmatic file injection first (no HID)
        let jsResult = try await SafariBridge.doJavaScript("""
            (function(){
                var el = \(selector.resolveRefJS);
                if (!el) return 'NOT_FOUND';
                try {
                    var dt = new DataTransfer();
                    var resp = await fetch('file://\(expandedPath.escapedForJS)');
                    if (!resp.ok) return 'FETCH_FAILED';
                    var blob = await resp.blob();
                    var name = '\(URL(fileURLWithPath: expandedPath).lastPathComponent.escapedForJS)';
                    var file = new File([blob], name, {type: blob.type || 'application/octet-stream'});
                    dt.items.add(file);
                    el.files = dt.files;
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                    return 'OK';
                } catch(e) {
                    return 'JS_FAILED:' + e.message;
                }
            })()
            """)

        if jsResult == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }

        if jsResult == "OK" {
            return // Success via JS — no HID needed
        }

        // JS method failed — need HID
        if !allowHid {
            FileHandle.standardError.write(Data("""
                JS file injection failed (\(jsResult)).
                To upload via keyboard simulation, re-run with --allow-hid:
                  safari-browser upload --allow-hid "\(selector)" "\(filePath)"
                ⚠️  --allow-hid will control your keyboard. Do not type until it completes.

                """.utf8))
            throw SafariBrowserError.appleScriptFailed("File upload requires --allow-hid flag for System Events fallback")
        }

        // HID fallback with explicit opt-in
        FileHandle.standardError.write(Data("⚠️  Controlling keyboard for file dialog. Do not type until complete.\n".utf8))

        // Click the file input to open dialog
        _ = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (el) el.click(); })()"
        )

        // Use System Events to navigate the file dialog
        try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
            tell application "System Events"
                tell process "Safari"
                    set maxWait to 10
                    set waited to 0
                    repeat until exists sheet 1 of front window
                        delay 0.5
                        set waited to waited + 0.5
                        if waited >= maxWait then
                            error "File dialog did not appear"
                        end if
                    end repeat
                    keystroke "g" using {command down, shift down}
                    delay 1
                    keystroke "\(expandedPath)"
                    keystroke return
                    delay 1
                    keystroke return
                end tell
            end tell
            """])
    }
}
