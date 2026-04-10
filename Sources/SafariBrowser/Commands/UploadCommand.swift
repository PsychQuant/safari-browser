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

    @Option(name: .long, help: "Seconds before the native file dialog subprocess is terminated (default: 60)")
    var timeout: Double = 60.0

    func run() async throws {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SafariBrowserError.fileNotFound(filePath)
        }

        // --js explicitly selects JS DataTransfer path
        if js {
            try await uploadViaJSDataTransfer(selector: selector, path: expandedPath)
            return
        }

        // --native or --allow-hid explicitly selects native path
        if native || allowHid {
            try await uploadViaNativeDialog(selector: selector, path: expandedPath, timeout: timeout)
            return
        }

        // Smart default: native when Accessibility permission is granted, JS fallback otherwise
        if SafariBridge.isAccessibilityPermitted() {
            try await uploadViaNativeDialog(selector: selector, path: expandedPath, timeout: timeout)
        } else {
            FileHandle.standardError.write(Data("""
                ℹ️  Using JS DataTransfer (slower for large files).
                    Grant Accessibility permission in System Settings → Privacy & Security → Accessibility
                    to enable fast native file dialog upload.\n
                """.utf8))
            try await uploadViaJSDataTransfer(selector: selector, path: expandedPath)
        }
    }

    // MARK: - Native file dialog

    /// Click file input to open dialog, then navigate via a single combined osascript.
    /// Merges activate + wait + keystroke navigation into one osascript invocation
    /// to prevent focus-stealing race conditions between separate calls (fixes #15).
    private func uploadViaNativeDialog(selector: String, path: String, timeout: Double) async throws {
        FileHandle.standardError.write(Data("⚠️  Controlling keyboard for file dialog (~1s). Do not type in Safari until complete.\n".utf8))

        // Click the file input to open dialog
        let clickResult = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'NOT_FOUND'; el.click(); return 'OK'; })()"
        )
        if clickResult == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }

        // Single combined osascript: activate, wait for dialog, navigate, click Upload.
        // Subprocess-level timeout (#19) bounds the whole osascript invocation in case
        // System Events or Safari's Apple Event dispatcher is blocked and the inner
        // `maxWait to 10` repeat loops never make progress.
        try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
            tell application "Safari" to activate
            tell application "System Events"
                tell process "Safari"
                    -- Verify Safari is frontmost before sending any keystrokes
                    if not frontmost then
                        error "Safari lost focus after activate — aborting to avoid sending keystrokes to wrong application"
                    end if

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

                    -- Save user's clipboard
                    set oldClip to the clipboard

                    try
                        -- Re-check frontmost right before keystrokes
                        if not frontmost then
                            error "Safari lost focus before keystrokes — aborting to avoid sending keys to wrong application"
                        end if

                        -- Open "Go to Folder" panel
                        keystroke "g" using {command down, shift down}

                        -- Wait for Go to Folder nested sheet to appear
                        set waited to 0
                        repeat until exists sheet 1 of sheet 1 of front window
                            delay 0.2
                            set waited to waited + 0.2
                            if waited >= maxWait then
                                error "Go to Folder panel did not appear within " & maxWait & " seconds"
                            end if
                        end repeat

                        -- Paste path via clipboard (fast, supports all characters)
                        set the clipboard to "\(path.escapedForAppleScript)"
                        keystroke "v" using command down
                        delay 0.3
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

                        -- Click the default button (Upload/Open/Save) — locale-independent
                        delay 0.3
                        try
                            click (first button of sheet 1 of front window whose value of attribute "AXDefault" is true)
                        on error
                            keystroke return
                        end try

                        -- Restore user's clipboard
                        set the clipboard to oldClip
                    on error errMsg
                        -- Always restore clipboard, even on unexpected errors
                        set the clipboard to oldClip
                        error errMsg
                    end try
                end tell
            end tell
            """], timeout: timeout)
    }

    // MARK: - JS DataTransfer (--js flag)

    /// Upload via JS base64 chunking + DataTransfer injection. Slow for large files, no permissions needed.
    private func uploadViaJSDataTransfer(selector: String, path: String) async throws {
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        let base64 = fileData.base64EncodedString()
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let mimeType = guessMimeType(for: fileName)

        // Record initial URL (strip fragment) to detect page navigation during chunking
        let initialURL = try await SafariBridge.doJavaScript("window.location.href.split('#')[0]")

        // Transfer base64 in 200KB chunks via window variable
        _ = try await SafariBridge.doJavaScript("window.__sbUpload = ''")
        let chunkSize = 200_000
        var offset = base64.startIndex
        var chunkCount = 0
        let totalChunks = (base64.count + chunkSize - 1) / chunkSize
        while offset < base64.endIndex {
            let end = base64.index(offset, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            let chunk = String(base64[offset..<end])
            _ = try await SafariBridge.doJavaScript("window.__sbUpload += '\(chunk.escapedForJS)'")
            offset = end
            chunkCount += 1

            // Check URL every 10 chunks (strip fragment for comparison)
            if chunkCount % 10 == 0 {
                let currentURL = try await SafariBridge.doJavaScript("window.location.href.split('#')[0]")
                if currentURL != initialURL {
                    _ = try? await SafariBridge.doJavaScript("delete window.__sbUpload")
                    throw SafariBrowserError.appleScriptFailed(
                        "Page navigated away during upload (was: \(initialURL), now: \(currentURL)). Upload aborted."
                    )
                }
            }

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
            _ = try? await SafariBridge.doJavaScript("delete window.__sbUpload")
            throw SafariBrowserError.elementNotFound(selector)
        }

        if jsResult != "OK" {
            _ = try? await SafariBridge.doJavaScript("delete window.__sbUpload")
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
