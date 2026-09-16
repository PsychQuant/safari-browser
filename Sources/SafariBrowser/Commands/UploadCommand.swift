import AppKit
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

    @Flag(name: .long, help: "Compatibility alias for native file dialog upload; no keyboard/mouse simulation")
    var allowHid = false

    @Option(
        name: .long,
        help: """
            Seconds before the native file dialog subprocess is terminated (default: 60). \
            The same deadline bounds chooser opening, AX Paste/Upload and selected-file verification.
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

    /// Native upload still changes focus and temporarily owns the clipboard.
    /// The warning precedes both the clipboard write and the native chooser.
    static let nativeInterferenceWarning =
        "⚠️  Native file dialog upload changes Safari focus and temporarily uses the clipboard. Avoid interacting with Safari or copying until complete.\n"

    /// Preserve explicit flag routing and the upload Accessibility-grant exception.
    static func resolveNativeRouting(
        native: Bool, allowHid: Bool, accessibilityProbe: () -> Bool
    ) -> Bool {
        if native || allowHid { return true }
        return accessibilityProbe()
    }
    static func nativeModificationTimeMilliseconds(_ date: Date) throws -> Int64 {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.towardZero)
        guard milliseconds.isFinite, milliseconds > Double(Int64.min), milliseconds < Double(Int64.max) else {
            throw ValidationError("Native upload file metadata is outside the supported range")
        }
        return Int64(milliseconds)
    }

    /// Execute the actual clipboard/script lifecycle. Tests use a private
    /// pasteboard and replace only the external Safari subprocess boundary.
    @MainActor
    static func performNativeUpload(fileURL: URL, selector: String, window: Int?, timeout: Double,
                                    pasteboard: NSPasteboard = .general,
                                    windowID: Int? = nil, tabIndex: Int? = nil,
                                    prepareTarget: () async throws -> Void = {},
                                    warn: (String) -> Void,
                                    runScript: (String) async throws -> Void) async throws {
        guard fileURL.isFileURL else { throw ValidationError("Native upload requires a local file URL") }
        guard timeout.isFinite, timeout >= 0.001, timeout <= 86_400 else {
            throw ValidationError("Native upload timeout must be between 0.001 and 86400 seconds")
        }
        let resolvedURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            throw SafariBrowserError.fileNotFound(fileURL.path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw ValidationError("Native upload requires a readable regular file with size and modification time")
        }
        let milliseconds = try nativeModificationTimeMilliseconds(modified)
        guard size.int64Value >= 0 else {
            throw ValidationError("Native upload file metadata is outside the supported range")
        }

        warn(nativeInterferenceWarning)
        let clipboard = try FileURLClipboard(fileURL: resolvedURL, pasteboard: pasteboard)
        var operationError: Error?
        do {
            // Exclusion covers every cooperating native mutation, including
            // System Events recovery and target-tab preparation.
            try await prepareTarget()
            let cleanupReserve = min(3.0, timeout / 4)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout - cleanupReserve
            let script = NativeUploadScript.make(
                selector: selector, path: resolvedURL.path, fileSize: size.int64Value,
                modificationTimeMilliseconds: milliseconds,
                clipboardChangeCount: clipboard.ownedChangeCount, window: window,
                timeout: timeout, nonce: UUID().uuidString,
                windowID: windowID, tabIndex: tabIndex, deadlineUptime: deadline)
            try await runScript(script)
        } catch { operationError = error }

        do {
            if try clipboard.restore() == .preservedNewer {
                warn("ℹ️  Clipboard changed during upload; newer contents were preserved.\n")
            }
        } catch {
            if let operationError {
                throw SafariBrowserError.appleScriptFailed(
                    "\(operationError); clipboard restoration also failed: \(error.localizedDescription)")
            }
            throw error
        }
        if let operationError {
            if let safariError = operationError as? SafariBrowserError {
                switch safariError {
                case .appleScriptFailed(let message)
                    where message.hasSuffix(": execution error: SB_UPLOAD_INPUT_NOT_FOUND (-2700)"):
                    throw SafariBrowserError.elementNotFound(selector)
                case .processTimedOut(_, let seconds):
                    // The runner carries the entire generated script in command;
                    // it is diagnostic context, not an executed error marker.
                    throw SafariBrowserError.processTimedOut(command: "native file URL upload", seconds: seconds)
                default: break
                }
            }
            throw operationError
        }
    }
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
        // runtime and performs tab-switch + raise before native interaction.
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
            // #51: scope to --profile via a concrete target (10 MB JS path).
            let scoped = try await target.resolveProfileScoped()
            try await uploadViaJSDataTransfer(selector: selector, path: expandedPath, target: scoped, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
            return
        }

        // Decide whether to go native. Conditions:
        //   - Explicit --native / --allow-hid (user chose)
        //   - OR Accessibility permission is granted (smart default)
        // In both cases, #26 routes through the resolver so --url /
        // --tab / --document all land on a concrete (window, tab) pair
        // before native interaction.
        let wantNative = UploadCommand.resolveNativeRouting(
            native: native,
            allowHid: allowHid,
            accessibilityProbe: SafariBridge.isAccessibilityPermitted)
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
        let scoped = try await target.resolveProfileScoped()
        try await uploadViaJSDataTransfer(selector: selector, path: expandedPath, target: scoped, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
    }

    /// Resolve the target to a (windowIndex, tabIndexInWindow) pair via
    /// `SafariBridge.resolveNativeTarget`, perform the tab switch if
    /// needed, then dispatch the native file-dialog AX path to
    /// the resolved window.
    ///
    /// This is the #26 replacement for the old "native only accepts
    /// --window" path. `--url` / `--tab` / `--document` flags all flow
    /// through the resolver, eliminating the shell `documents | grep`
    /// workaround and restoring AI-agent autonomy in multi-window
    /// Safari sessions.
    private func runNativeWithResolver(expandedPath: String) async throws {
        let scoped = try await target.resolveProfileScoped()
        let resolved = try await SafariBridge.resolveNativeTarget(from: scoped, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)

        try await uploadViaNativeDialog(
            selector: selector, path: expandedPath, timeout: timeout, resolved: resolved)
    }

    // MARK: - Native file dialog

    /// Click file input to open dialog, then navigate via a single combined osascript.
    /// Preparation is inside the same exclusion lease as the chooser itself.
    private func uploadViaNativeDialog(selector: String, path: String, timeout: Double,
                                       resolved: SafariBridge.ResolvedWindowTarget) async throws {
        guard let windowID = resolved.windowID, windowID > 0 else {
            throw SafariBrowserError.appleScriptFailed("Native upload could not bind a stable target window; no chooser was opened")
        }
        try await Self.performNativeUpload(
            fileURL: URL(fileURLWithPath: path), selector: selector,
            window: resolved.windowIndex, timeout: timeout,
            windowID: windowID, tabIndex: resolved.anchorTabIndex,
            prepareTarget: {
                try await SafariBridge.ensureSystemEventsLive()
                if resolved.anchorTabIndex != nil {
                    FileHandle.standardError.write(Data("ℹ️  Target tab will be brought to the front of its window before upload.\n".utf8))
                }
                _ = try await SafariBridge.runAppleScript(Self.nativeTargetPreparationScript(
                    windowID: windowID, tabIndex: resolved.anchorTabIndex))
            },
            warn: { FileHandle.standardError.write(Data($0.utf8)) },
            runScript: { script in try await SafariBridge.runFileDialogScript(script, timeout: timeout) })
    }

    static func nativeTargetPreparationScript(windowID: Int, tabIndex: Int?) -> String {
        let selection = tabIndex.map { tab in
            """
            if \(tab) < 1 or \(tab) > (count tabs of window id \(windowID)) then error "Native upload target tab disappeared"
            if index of current tab of window id \(windowID) is not \(tab) then
                set current tab of window id \(windowID) to tab \(tab) of window id \(windowID)
            end if
            """
        } ?? ""
        return """
        tell application "Safari"
            if not (exists window id \(windowID)) then error "Native upload target window disappeared before preparation"
            \(selection)
        end tell
        """
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
