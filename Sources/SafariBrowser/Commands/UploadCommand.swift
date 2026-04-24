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

    @Option(
        name: .long,
        help: """
            Seconds before the native file dialog subprocess is terminated (default: 60). \
            Default 60 accommodates the inner AppleScript's three 10-second maxWait loops \
            (dialog-open, Go-to-Folder-open, Go-to-Folder-close).
            """
    )
    var timeout: Double = 60.0

    @OptionGroup var target: TargetOptions

    /// #24 fix: `--js` path hard cap. Above this size, the base64 + JS
    /// DataTransfer approach is fundamentally unsafe (V8 memory pressure,
    /// osascript roundtrip count) even with the R1 Array.push fix. Users
    /// MUST use `--native` for large files — it mimics human upload and
    /// is the canonical path.
    private static let jsHardCapBytes = 10 * 1_048_576   // 10 MB
    private static let jsSoftWarnBytes = 5 * 1_048_576   // 5 MB

    func validate() throws {
        // Mirror runProcessWithTimeout's bounds so invalid CLI input surfaces
        // with a user-friendly ArgumentParser usage error before reaching the
        // library layer (#19 R2-F1').
        guard timeout.isFinite, timeout >= 0.001, timeout <= 86_400 else {
            throw ValidationError("--timeout must be a finite number between 0.001 and 86400 seconds, got \(timeout)")
        }

        // #26: --native / --allow-hid no longer rejects --url / --tab /
        // --document. The native-path resolver (SafariBridge.resolveNativeTarget)
        // maps those targeting flags to a concrete (window, tab) pair at
        // runtime and performs tab-switch + raise before keystroke dispatch.
        // The previous #23 R5 reject was removed here; see proposal #26.

        // #24: hard cap --js at 10 MB. The cap fires for explicit --js
        // (where the user has definitely chosen the JS path) and for the
        // fallback JS path in run() when Accessibility permission is
        // absent. Smart-default routing with targeting flags can no
        // longer be assumed to force JS at validate time — under #26,
        // smart default with targeting routes through native when AX is
        // available. The runtime fallback check in run() handles the
        // no-AX-perm case; see checkJsSizeCapIfNeeded().
        if js {
            try checkJsSizeCap()
        }
    }

    /// Enforce the 10 MB hard cap on the JS DataTransfer path. Called
    /// from validate() for explicit `--js` and from run() when falling
    /// back to JS without Accessibility permission.
    internal func checkJsSizeCap() throws {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        // Missing file is a separate error thrown in run(); don't double-error.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expandedPath),
              let size = attrs[.size] as? Int else {
            return
        }
        if size > UploadCommand.jsHardCapBytes {
            let sizeMB = Double(size) / 1_048_576
            throw ValidationError("""
                --js mode is capped at 10 MB (file is \(String(format: "%.1f", sizeMB)) MB).
                Reason: --js uses JavaScript DataTransfer + base64 chunking which is fundamentally \
                memory-heavy and does not mimic human upload behavior. Previous attempts with large \
                files crashed Safari even on machines with 128 GB RAM (see #24).

                For larger files use --native (which now accepts --url / --tab / --document via the \
                native-path resolver, #26):
                  safari-browser upload --native "\(selector)" "\(filePath)" --url <pattern>

                --native requires Accessibility permission but is the canonical large-file path
                (mimics human "choose file" dialog exactly). Small files (<10 MB) can still use --js.
                """)
        }
        if size > UploadCommand.jsSoftWarnBytes {
            let sizeMB = Double(size) / 1_048_576
            FileHandle.standardError.write(Data(
                "⚠️  File is \(String(format: "%.1f", sizeMB)) MB — --js is slow for files >5 MB. Consider --native.\n".utf8
            ))
        }
    }

    func run() async throws {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SafariBrowserError.fileNotFound(filePath)
        }

        // --js explicitly selects JS DataTransfer path. Size cap already
        // enforced at validate() time.
        if js {
            try await uploadViaJSDataTransfer(selector: selector, path: expandedPath, target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
            return
        }

        // Decide whether to go native. Conditions:
        //   - Explicit --native / --allow-hid (user chose)
        //   - OR Accessibility permission is granted (smart default)
        // In both cases, #26 routes through the resolver so --url /
        // --tab / --document all land on a concrete (window, tab) pair
        // before keystroke dispatch.
        let wantNative = native || allowHid || SafariBridge.isAccessibilityPermitted()
        if wantNative {
            try await runNativeWithResolver(expandedPath: expandedPath)
            return
        }

        // No AX permission and no explicit --native → fall back to JS
        // with an informational stderr note. The size cap must be
        // enforced here because the validate-time check only fires for
        // explicit --js (we don't know at validate time which path the
        // runtime will pick).
        try checkJsSizeCap()
        FileHandle.standardError.write(Data("""
            ℹ️  Using JS DataTransfer (slower for large files).
                Grant Accessibility permission in System Settings → Privacy & Security → Accessibility
                to enable fast native file dialog upload.\n
            """.utf8))
        try await uploadViaJSDataTransfer(selector: selector, path: expandedPath, target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
    }

    /// Resolve the target to a (windowIndex, tabIndexInWindow) pair via
    /// `SafariBridge.resolveNativeTarget`, perform the tab switch if
    /// needed, then dispatch the native file-dialog keystroke path to
    /// the resolved window.
    ///
    /// This is the #26 replacement for the old "native only accepts
    /// --window" path. `--url` / `--tab` / `--document` flags all flow
    /// through the resolver, eliminating the shell `documents | grep`
    /// workaround and restoring AI-agent autonomy in multi-window
    /// Safari sessions.
    private func runNativeWithResolver(expandedPath: String) async throws {
        let resolved = try await SafariBridge.resolveNativeTarget(from: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)

        // Tab switch is a passively interfering side effect transitively
        // authorized by --native / --allow-hid. The stderr warning in
        // uploadViaNativeDialog covers keyboard control; here we add a
        // tab-switch addendum when applicable so the user knows what
        // extra interaction is about to happen.
        if resolved.tabIndexInWindow != nil {
            FileHandle.standardError.write(Data(
                "ℹ️  Target tab will be brought to the front of its window before upload.\n".utf8
            ))
        }
        try await SafariBridge.performTabSwitchIfNeeded(
            window: resolved.windowIndex,
            tab: resolved.tabIndexInWindow
        )

        try await uploadViaNativeDialog(
            selector: selector,
            path: expandedPath,
            timeout: timeout,
            window: resolved.windowIndex
        )
    }

    // MARK: - Native file dialog

    /// Click file input to open dialog, then navigate via a single combined osascript.
    /// Merges activate + wait + keystroke navigation into one osascript invocation
    /// to prevent focus-stealing race conditions between separate calls (fixes #15).
    ///
    /// `window` selects which Safari window the keystrokes target. `nil`
    /// preserves the legacy front-window behavior; an explicit index
    /// raises `window N` to the front before activating Safari (#23).
    private func uploadViaNativeDialog(selector: String, path: String, timeout: Double, window: Int? = nil) async throws {
        // #23 verify R1: preflight the window so a bad `--window 99`
        // surfaces `documentNotFound` with the available-docs listing
        // before we touch System Events. The subsequent doJavaScript call
        // on `.windowIndex(window)` would already error, but we want the
        // error BEFORE we warn the user about keyboard takeover below.
        if let window {
            _ = try await SafariBridge.getCurrentURL(target: .windowIndex(window))
        }

        // #20: probe System Events before sending any keystrokes. A silent hang
        // inside the combined osascript is the single worst failure mode of this
        // command, and System Events being down is by far the most common cause.
        try await SafariBridge.ensureSystemEventsLive()

        FileHandle.standardError.write(Data("⚠️  Controlling keyboard for file dialog (~1s). Do not type in Safari until complete.\n".utf8))

        // Click the file input to open dialog. When --window N is set, the
        // click must land on that window's current tab — thread the window
        // through doJavaScript via the centralized `.forWindow` helper
        // (enforces `--window N` → `.windowIndex(N)`, never
        // `.documentIndex(N)`). A single unit test guards this invariant
        // against regression (#23 verify R1→R2).
        let jsTarget = SafariBridge.TargetDocument.forWindow(window)
        let clickResult = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'NOT_FOUND'; el.click(); return 'OK'; })()",
            target: jsTarget
        )
        if clickResult == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }

        // #23: when targeting a specific window, raise it to the front
        // before activating Safari so the subsequent keystrokes land on
        // `front window` = the requested window.
        let raisePrelude = window.map { idx in
            "tell application \"Safari\" to set index of window \(idx) to 1\n"
        } ?? ""

        // Single combined osascript: activate, wait for dialog, navigate, click Upload.
        // Subprocess-level timeout (#19) bounds the whole osascript invocation in case
        // System Events or Safari's Apple Event dispatcher is blocked and the inner
        // `maxWait to 10` repeat loops never make progress.
        try await SafariBridge.runShell("/usr/bin/osascript", ["-e", """
            \(raisePrelude)tell application "Safari" to activate
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

    /// Upload via JS base64 chunking + DataTransfer injection. Bounded by
    /// a 10 MB hard cap (`validate()`) because the base64 + JS roundtrip
    /// path is fundamentally memory-heavy and **not** a "mimic human"
    /// upload path — it's an accessibility-free fallback only.
    ///
    /// #24 fix: chunking uses `Array.push` + `Array.join` instead of
    /// `String +=`. V8's `string += string` is O(n²) cumulative — for
    /// a 131 MB file (175 MB base64) with 200 KB chunks, the old
    /// pattern allocated ~83 GB of transient garbage strings and
    /// crashed Safari even on machines with 128 GB RAM. Array push is
    /// O(1) amortized and the final join is a single allocation.
    ///
    /// `target` selects which Safari document the upload lands in;
    /// defaults to `.frontWindow` for backward compatibility (#23).
    private func uploadViaJSDataTransfer(
        selector: String,
        path: String,
        target: SafariBridge.TargetDocument = .frontWindow,
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) async throws {
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        let base64 = fileData.base64EncodedString()
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let mimeType = guessMimeType(for: fileName)

        // Record initial URL (strip fragment) to detect page navigation during chunking
        let initialURL = try await SafariBridge.doJavaScript(
            "window.location.href.split('#')[0]",
            target: target
        )

        // #24: Transfer base64 in 200KB chunks via Array.push (NOT String +=).
        // String += triggers V8 O(n²) string concatenation which allocated
        // ~83 GB of transient garbage strings for a 131 MB file and crashed
        // Safari even on 128 GB RAM. Array.push is O(1) amortized; final
        // join is a single contiguous allocation.
        _ = try await SafariBridge.doJavaScript("window.__sbUploadChunks = []", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
        let chunkSize = 200_000
        var offset = base64.startIndex
        var chunkCount = 0
        let totalChunks = (base64.count + chunkSize - 1) / chunkSize
        while offset < base64.endIndex {
            let end = base64.index(offset, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            let chunk = String(base64[offset..<end])
            _ = try await SafariBridge.doJavaScript("window.__sbUploadChunks.push('\(chunk.escapedForJS)')", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
            offset = end
            chunkCount += 1

            // Check URL every 10 chunks (strip fragment for comparison)
            if chunkCount % 10 == 0 {
                let currentURL = try await SafariBridge.doJavaScript(
                    "window.location.href.split('#')[0]",
                    target: target
                )
                if currentURL != initialURL {
                    _ = try? await SafariBridge.doJavaScript("delete window.__sbUploadChunks", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
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

        // Inject file via DataTransfer — join chunks once, then decode + wrap.
        let jsResult = try await SafariBridge.doJavaScript("""
            (function(){
                var el = \(selector.resolveRefJS);
                if (!el) return 'NOT_FOUND';
                try {
                    var full = window.__sbUploadChunks.join('');
                    delete window.__sbUploadChunks;
                    var bin = atob(full);
                    full = null;
                    var bytes = new Uint8Array(bin.length);
                    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                    bin = null;
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
            """, target: target)

        if jsResult == "NOT_FOUND" {
            _ = try? await SafariBridge.doJavaScript("delete window.__sbUploadChunks", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
            throw SafariBrowserError.elementNotFound(selector)
        }

        if jsResult != "OK" {
            _ = try? await SafariBridge.doJavaScript("delete window.__sbUploadChunks", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
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
