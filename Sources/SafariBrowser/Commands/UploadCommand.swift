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

        // Read file, transfer base64 in chunks to avoid E2BIG on osascript args
        let fileData = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
        let base64 = fileData.base64EncodedString()
        let fileName = URL(fileURLWithPath: expandedPath).lastPathComponent
        let mimeType = guessMimeType(for: fileName)

        // Transfer base64 in 200KB chunks via window variable
        _ = try await SafariBridge.doJavaScript("window.__sbUpload = ''")
        let chunkSize = 200_000
        var offset = base64.startIndex
        while offset < base64.endIndex {
            let end = base64.index(offset, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            let chunk = String(base64[offset..<end])
            _ = try await SafariBridge.doJavaScript("window.__sbUpload += '\(chunk.escapedForJS)'")
            offset = end
        }

        // Inject file via DataTransfer
        let jsResult = try await SafariBridge.doJavaScript("""
            (function(){
                var el = \(selector.resolveRefJS);
                if (!el) return 'NOT_FOUND';
                try {
                    var bin = atob(window.__sbUpload);
                    delete window.__sbUpload;
                    var bytes = new Uint8Array(bin.length);
                    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                    var blob = new Blob([bytes], {type: '\(mimeType)'});
                    var file = new File([blob], '\(fileName.escapedForJS)', {type: '\(mimeType)'});
                    var dt = new DataTransfer();
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
                    keystroke "\(expandedPath.escapedForAppleScript)"
                    keystroke return
                    delay 1
                    keystroke return
                end tell
            end tell
            """])
    }

    private func guessMimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        case "wav": return "audio/wav"
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "doc", "docx": return "application/msword"
        case "txt": return "text/plain"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
        }
    }
}
