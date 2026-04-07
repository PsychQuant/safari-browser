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

    @Flag(name: .long, help: "Use JS DataTransfer injection instead of native file dialog (no Accessibility permission needed, but slow for large files)")
    var js = false

    @Flag(name: .long, help: "Use native file dialog (default behavior, kept for backward compatibility)")
    var native = false

    @Flag(name: .long, help: "Allow keyboard/mouse simulation (kept for backward compatibility)")
    var allowHid = false

    func run() async throws {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SafariBrowserError.fileNotFound(filePath)
        }

        // #14: --js explicitly selects JS DataTransfer path
        if js {
            try await uploadViaJSDataTransfer(selector: selector, path: expandedPath)
            return
        }

        // Default: native file dialog (also when --native or --allow-hid is passed)
        FileHandle.standardError.write(Data("⚠️  Controlling keyboard for file dialog (~1s). Do not type in Safari until complete.\n".utf8))
        try await clickFileInputAndNavigateDialog(selector: selector, path: expandedPath)
    }

    // MARK: - Native file dialog (default)

    /// Click file input to open dialog, then navigate via System Events with precise waits.
    private func clickFileInputAndNavigateDialog(selector: String, path: String) async throws {
        // Click the file input to open dialog
        let clickResult = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'NOT_FOUND'; el.click(); return 'OK'; })()"
        )
        if clickResult == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }

        // #14: Use precise waits instead of blind delays
        try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
            tell application "System Events"
                tell process "Safari"
                    -- Wait for file dialog sheet to appear
                    set maxWait to 10
                    set waited to 0
                    repeat until exists sheet 1 of front window
                        delay 0.3
                        set waited to waited + 0.3
                        if waited >= maxWait then
                            error "File dialog did not appear within " & maxWait & " seconds"
                        end if
                    end repeat

                    -- Open "Go to Folder" panel
                    keystroke "g" using {command down, shift down}

                    -- Wait for Go to Folder nested sheet to appear (not blind delay)
                    set waited to 0
                    repeat until exists sheet 1 of sheet 1 of front window
                        delay 0.2
                        set waited to waited + 0.2
                        if waited >= maxWait then
                            error "Go to Folder panel did not appear within " & maxWait & " seconds"
                        end if
                    end repeat

                    -- Type path and confirm
                    keystroke "\(path.escapedForAppleScript)"
                    keystroke return

                    -- Wait for Go to Folder sheet to close (file selected)
                    set waited to 0
                    repeat until not (exists sheet 1 of sheet 1 of front window)
                        delay 0.2
                        set waited to waited + 0.2
                        if waited >= maxWait then
                            error "Go to Folder did not close within " & maxWait & " seconds"
                        end if
                    end repeat

                    -- Click the default button (Upload/Open) — locale-independent
                    delay 0.3
                    click (first button of sheet 1 of front window whose value of attribute "AXDefault" is true)
                end tell
            end tell
            """])
    }

    // MARK: - JS DataTransfer (--js flag)

    /// Upload via JS base64 chunking + DataTransfer injection. Slow for large files, no permissions needed.
    private func uploadViaJSDataTransfer(selector: String, path: String) async throws {
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        let base64 = fileData.base64EncodedString()
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let mimeType = guessMimeType(for: fileName)

        // #14: Record initial URL to detect page navigation during chunking
        let initialURL = try await SafariBridge.doJavaScript("window.location.href")

        // Transfer base64 in 200KB chunks via window variable
        _ = try await SafariBridge.doJavaScript("window.__sbUpload = ''")
        let chunkSize = 200_000
        var offset = base64.startIndex
        var chunkCount = 0
        let totalChunks = (base64.count + chunkSize - 1) / chunkSize
        while offset < base64.endIndex {
            // #14: Check URL hasn't changed (page navigation detection)
            let currentURL = try await SafariBridge.doJavaScript("window.location.href")
            if currentURL != initialURL {
                throw SafariBrowserError.appleScriptFailed(
                    "Page navigated away during upload (was: \(initialURL), now: \(currentURL)). Upload aborted. Use default upload (without --js) to avoid this."
                )
            }

            let end = base64.index(offset, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            let chunk = String(base64[offset..<end])
            _ = try await SafariBridge.doJavaScript("window.__sbUpload += '\(chunk.escapedForJS)'")
            offset = end
            chunkCount += 1

            // Progress indicator for large files
            if totalChunks > 10 && chunkCount % 10 == 0 {
                FileHandle.standardError.write(Data("  uploading: \(chunkCount)/\(totalChunks) chunks\n".utf8))
            }
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

        if jsResult != "OK" {
            throw SafariBrowserError.appleScriptFailed("JS file injection failed: \(jsResult)")
        }
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
