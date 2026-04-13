import ApplicationServices
import CoreGraphics
import Foundation

enum SafariBridge {
    // MARK: - Document Targeting (#17/#18/#21)

    /// Selects which Safari document a command should operate on. Every case
    /// resolves to a concrete AppleScript document reference via
    /// `resolveDocumentReference(_:)`, which is safe to interpolate into a
    /// `tell application "Safari"` block.
    ///
    /// The default `.frontWindow` resolves to `document 1` rather than
    /// `current tab of front window` so that read-only queries bypass
    /// modal-sheet blocks on the front window (#21).
    enum TargetDocument: Sendable {
        case frontWindow
        case windowIndex(Int)
        case urlContains(String)
        case documentIndex(Int)

        /// Map a `--window N` integer to the correct targeting case
        /// (`.windowIndex(N)` → "document of window N"). Critical for
        /// window-scoped commands: do NOT use `.documentIndex(N)` here —
        /// that resolves to Safari's global `document N` collection
        /// index, which is NOT window N's current tab in multi-window
        /// sessions (#23 verify R1 finding). Passing `nil` preserves
        /// legacy `.frontWindow` behavior.
        static func forWindow(_ n: Int?) -> TargetDocument {
            n.map { .windowIndex($0) } ?? .frontWindow
        }
    }

    /// Translate a `TargetDocument` into a Safari AppleScript document
    /// reference expression. The returned string is designed to replace
    /// `document 1` (or equivalently `current tab of front window`) inside
    /// any `tell application "Safari" to ...` block.
    ///
    /// URL patterns are escaped via `escapedForAppleScript` so that quotes
    /// and backslashes in user input cannot break out of the AppleScript
    /// string literal.
    static func resolveDocumentReference(_ target: TargetDocument) -> String {
        switch target {
        case .frontWindow:
            return "document 1"
        case .windowIndex(let n):
            return "document of window \(n)"
        case .urlContains(let pattern):
            let escaped = pattern.escapedForAppleScript
            return "(first document whose URL contains \"\(escaped)\")"
        case .documentIndex(let n):
            return "document \(n)"
        }
    }

    /// Run an AppleScript against a target document, translating "not found"
    /// errors from `.urlContains` / `.windowIndex` / `.documentIndex` into
    /// the user-friendly `documentNotFound` error that lists all available
    /// Safari documents. Without this wrapper, the user would see a raw
    /// AppleScript error like "Can't get first document whose URL contains...".
    private static func runTargetedAppleScript(
        _ script: String,
        target: TargetDocument,
        timeout: TimeInterval = SafariBridge.defaultProcessTimeout
    ) async throws -> String {
        do {
            return try await runAppleScript(script, timeout: timeout)
        } catch let error as SafariBrowserError {
            // Only translate when the error is plausibly "document not found"
            // from a non-default target. AppleScript uses error codes -1719
            // (invalid index) and -1728 (object not found) for missing
            // documents. We also match localized error strings.
            if case .frontWindow = target {
                // Default target: propagate as-is (backward compat).
                throw error
            }
            if case .appleScriptFailed(let msg) = error,
               msg.contains("-1719") || msg.contains("-1728") || msg.contains("Can't get") || msg.contains("無法取得") {
                let docs = (try? await listAllDocuments()) ?? []
                throw SafariBrowserError.documentNotFound(
                    pattern: targetDescription(target),
                    availableDocuments: docs.map { $0.url }
                )
            }
            throw error
        }
    }

    /// Human-readable description of a target for error messages.
    private static func targetDescription(_ target: TargetDocument) -> String {
        switch target {
        case .frontWindow: return "document 1 (default)"
        case .windowIndex(let n): return "window \(n)"
        case .urlContains(let pattern): return pattern
        case .documentIndex(let n): return "document \(n)"
        }
    }

    // MARK: - Navigation

    /// Navigate the target document to `url`. Uses `do JavaScript` against a
    /// document-scoped reference (bypasses #21 modal block), falling back to
    /// `set URL of <docRef>` if the script fails. When Safari has no windows,
    /// a new document is always created regardless of target.
    static func openURL(_ url: String, target: TargetDocument = .frontWindow) async throws {
        // #9: Use do JavaScript for navigation to avoid race with page's own JS redirects.
        // Fallback to set URL when do JavaScript fails (e.g., about:blank, no open tabs).
        let jsCode = "window.location.href=\(url.jsStringLiteral)"
        let docRef = resolveDocumentReference(target)
        // Route through runTargetedAppleScript so `--url typo open ...` also
        // gets the user-friendly documentNotFound error with available docs
        // listed, matching the read-only getter behavior.
        _ = try await runTargetedAppleScript("""
            tell application "Safari"
                activate
                if (count of windows) = 0 then
                    make new document with properties {URL:"\(url.escapedForAppleScript)"}
                else
                    try
                        do JavaScript "\(jsCode.escapedForAppleScript)" in \(docRef)
                    on error
                        set URL of \(docRef) to "\(url.escapedForAppleScript)"
                    end try
                end if
            end tell
            """, target: target)
    }

    /// Open `url` in a new tab of the target window. Only window-level
    /// targeting makes sense here; document-level flags (`--url`, `--tab`,
    /// `--document`) should be rejected by the caller via
    /// `TargetOptions.validate()` before reaching this function.
    static func openURLInNewTab(_ url: String, window: Int? = nil) async throws {
        let windowRef = window.map { "window \($0)" } ?? "front window"
        try await runAppleScript("""
            tell application "Safari"
                activate
                if (count of windows) = 0 then
                    make new document with properties {URL:"\(url.escapedForAppleScript)"}
                else
                    tell \(windowRef)
                        set newTab to make new tab with properties {URL:"\(url.escapedForAppleScript)"}
                        set current tab to newTab
                    end tell
                end if
            end tell
            """)
    }

    static func openURLInNewWindow(_ url: String) async throws {
        try await runAppleScript("""
            tell application "Safari"
                activate
                make new document with properties {URL:"\(url.escapedForAppleScript)"}
            end tell
            """)
    }

    /// Close the current tab of the target window (#23). `nil` preserves
    /// the legacy `front window` behavior; an explicit index targets
    /// `window N`. This is window-scoped — there is no AppleScript
    /// primitive for "close current tab of document N" — so `--url`,
    /// `--tab`, `--document` are rejected at the CLI layer via
    /// `WindowOnlyTargetOptions`.
    ///
    /// When `window` is supplied the call routes through
    /// `runTargetedAppleScript` so `--window 99` surfaces a user-friendly
    /// `documentNotFound` error listing every open document, matching the
    /// error contract of all other targeted commands (#23 verify R1).
    static func closeCurrentTab(window: Int? = nil) async throws {
        let windowRef = window.map { "window \($0)" } ?? "front window"
        let script = """
            tell application "Safari"
                close current tab of \(windowRef)
            end tell
            """
        if let window {
            _ = try await runTargetedAppleScript(script, target: .windowIndex(window))
        } else {
            try await runAppleScript(script)
        }
    }

    // MARK: - JavaScript

    static func doJavaScript(
        _ code: String,
        target: TargetDocument = .frontWindow
    ) async throws -> String {
        let docRef = resolveDocumentReference(target)
        return try await runTargetedAppleScript("""
            tell application "Safari"
                do JavaScript "\(code.escapedForAppleScript)" in \(docRef)
            end tell
            """, target: target)
    }

    /// Execute JS and read large results via chunked transfer.
    /// Stores result in window.__sbResult, then reads back in 256KB chunks.
    /// All chunks are read from the same target document so results stay
    /// consistent across multi-document Safari sessions.
    static func doJavaScriptLarge(
        _ code: String,
        target: TargetDocument = .frontWindow
    ) async throws -> String {
        // Store result in window variable
        _ = try await doJavaScript(
            "(function(){ window.__sbResult = '' + (\(code)); window.__sbResultLen = window.__sbResult.length; })()",
            target: target
        )

        // Get total length
        let lenStr = try await doJavaScript("window.__sbResultLen", target: target)
        guard let totalLen = Int(lenStr.trimmingCharacters(in: .whitespacesAndNewlines)), totalLen > 0 else {
            return ""
        }

        // Read in chunks
        let chunkSize = 262144 // 256KB
        var result = ""
        var offset = 0
        while offset < totalLen {
            let end = min(offset + chunkSize, totalLen)
            let chunk = try await doJavaScript(
                "window.__sbResult.substring(\(offset), \(end))",
                target: target
            )
            result += chunk
            offset = end
        }

        // Cleanup
        _ = try await doJavaScript("delete window.__sbResult; delete window.__sbResultLen", target: target)

        return result
    }

    // MARK: - Page Info

    /// Read the URL of the target document. Uses a document-scoped
    /// AppleScript reference (via `resolveDocumentReference`) so the query
    /// bypasses any modal file dialog sheet blocking Safari's front window
    /// (#21).
    static func getCurrentURL(target: TargetDocument = .frontWindow) async throws -> String {
        let docRef = resolveDocumentReference(target)
        return try await runTargetedAppleScript("""
            tell application "Safari"
                get URL of \(docRef)
            end tell
            """, target: target)
    }

    /// Read the title of the target document. Document-scoped for modal bypass (#21).
    static func getCurrentTitle(target: TargetDocument = .frontWindow) async throws -> String {
        let docRef = resolveDocumentReference(target)
        return try await runTargetedAppleScript("""
            tell application "Safari"
                get name of \(docRef)
            end tell
            """, target: target)
    }

    /// Read the plain-text content of the target document. Document-scoped for modal bypass (#21).
    static func getCurrentText(target: TargetDocument = .frontWindow) async throws -> String {
        let docRef = resolveDocumentReference(target)
        return try await runTargetedAppleScript("""
            tell application "Safari"
                get text of \(docRef)
            end tell
            """, target: target)
    }

    /// Read the HTML source of the target document. Document-scoped for modal bypass (#21).
    static func getCurrentSource(target: TargetDocument = .frontWindow) async throws -> String {
        let docRef = resolveDocumentReference(target)
        return try await runTargetedAppleScript("""
            tell application "Safari"
                get source of \(docRef)
            end tell
            """, target: target)
    }

    // MARK: - Document / Tab Management

    struct TabInfo: Sendable {
        let index: Int
        let title: String
        let url: String
    }

    /// Metadata for a Safari document, used by `listAllDocuments()` and
    /// `DocumentsCommand` to surface targeting candidates for `--url`,
    /// `--document`, etc. Index is 1-based and matches the AppleScript
    /// `document N` order, which is what `TargetDocument.documentIndex`
    /// expects.
    struct DocumentInfo: Sendable {
        let index: Int
        let title: String
        let url: String
    }

    /// List every Safari document across all windows in document-collection
    /// order. The index each entry carries is the value users pass to
    /// `--document N` / `TargetDocument.documentIndex(n)` (#17/#18/#21).
    static func listAllDocuments() async throws -> [DocumentInfo] {
        let countStr = try await runAppleScript("""
            tell application "Safari"
                if (count of documents) = 0 then
                    return "0"
                end if
                count of documents
            end tell
            """)

        guard let count = Int(countStr.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 else {
            return []
        }

        var docs: [DocumentInfo] = []
        for i in 1...count {
            let title = try await runAppleScript("""
                tell application "Safari"
                    get name of document \(i)
                end tell
                """)
            let url = try await runAppleScript("""
                tell application "Safari"
                    get URL of document \(i)
                end tell
                """)
            docs.append(DocumentInfo(
                index: i,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                url: url.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return docs
    }

    /// List all tabs of the target window. `window: nil` means the front
    /// window (backward-compatible default). `tabs` / `switch-tab` only
    /// support window-level targeting because listing tabs at document
    /// granularity doesn't make sense.
    static func listTabs(window: Int? = nil) async throws -> [TabInfo] {
        let windowRef = window.map { "window \($0)" } ?? "front window"
        let countStr = try await runAppleScript("""
            tell application "Safari"
                if (count of windows) = 0 then
                    return "0"
                end if
                count of tabs of \(windowRef)
            end tell
            """)

        guard let count = Int(countStr.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 else {
            return []
        }

        var tabs: [TabInfo] = []
        for i in 1...count {
            let title = try await runAppleScript("""
                tell application "Safari"
                    get name of tab \(i) of \(windowRef)
                end tell
                """)
            let url = try await runAppleScript("""
                tell application "Safari"
                    get URL of tab \(i) of \(windowRef)
                end tell
                """)
            tabs.append(TabInfo(
                index: i,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                url: url.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return tabs
    }

    /// Switch the target window's current tab to tab `index`. `window: nil`
    /// means the front window.
    static func switchToTab(_ index: Int, window: Int? = nil) async throws {
        let windowRef = window.map { "window \($0)" } ?? "front window"
        try await runAppleScript("""
            tell application "Safari"
                set current tab of \(windowRef) to tab \(index) of \(windowRef)
            end tell
            """)
    }

    /// Open a new empty tab in the target window. `window: nil` means the
    /// front window.
    static func openNewTab(window: Int? = nil) async throws {
        let windowRef = window.map { "window \($0)" } ?? "front window"
        try await runAppleScript("""
            tell application "Safari"
                activate
                if (count of windows) = 0 then
                    make new document
                else
                    tell \(windowRef)
                        set newTab to make new tab
                        set current tab to newTab
                    end tell
                end if
            end tell
            """)
    }

    // MARK: - Screenshot

    /// Resolve a Core Graphics window ID for the target Safari browser
    /// window. `nil` preserves the legacy front-window behavior; an
    /// explicit index targets `window N`, used by `screenshot --window`
    /// and `pdf --window` (#23). Settings/Preferences windows are filtered
    /// out by requiring the window to have a current tab.
    ///
    /// When `window` is set, the resolver **raises `window N` to the
    /// front** and then delegates to the front-window resolver. This
    /// is the cleanest unambiguous identity strategy — bounds+title
    /// matching (tried in R1 / R2) had multiple fail modes (duplicate
    /// maximized bounds in R1, title drift on auth callbacks / empty
    /// CG names in R2/R3). Once the window is front, there is exactly
    /// one CG candidate. Side effect: window Z-order is mutated.
    /// Consistent with `pdf --window N` and `upload --native --window N`
    /// which already raise via `raisePrelude`.
    static func getWindowID(window: Int? = nil) async throws -> String {
        if let window {
            return try await getWindowIDByRaise(windowIndex: window)
        }
        return try getFrontWindowID()
    }

    /// #23 verify R1→R2→R3→R4: raise-then-front resolver for `--window N`.
    ///
    /// Earlier rounds tried bounds matching (R1), bounds+title (R2), and
    /// various refinements — all eventually hit failure modes in real
    /// Safari:
    ///   - Two+ maximized windows share identical bounds (R1 bug)
    ///   - CG `kCGWindowName` drifts from AS `name of window N` on
    ///     auth callbacks, bidi URLs, stale page titles (R3 Logic+DA)
    ///   - CG entries occasionally have empty names (R3 DA)
    ///   - `trimmingCharacters` corrupts trailing-whitespace titles (R3 Codex+DA)
    ///
    /// The R4 approach abandons title-based identity entirely. `set
    /// index of window N to 1` via AppleScript raises the target window
    /// to the front, which is unambiguous by definition. We then delegate
    /// to the legacy front-window resolver.
    ///
    /// **Side effect**: window Z-order is mutated. `PdfCommand --window N`
    /// and `UploadCommand --native --window N` already do this via
    /// `raisePrelude`, so extending the pattern to `ScreenshotCommand`
    /// keeps CLI-wide behavior consistent.
    ///
    /// Routes through `runTargetedAppleScript` so a bad `--window 99`
    /// surfaces `documentNotFound` with the available-docs listing,
    /// matching the error contract of every other targeted command.
    private static func getWindowIDByRaise(windowIndex: Int) async throws -> String {
        _ = try await runTargetedAppleScript("""
            tell application "Safari"
                -- Verify browser window (has a tab) so Settings / Preferences error out early
                set t to current tab of window \(windowIndex)
                -- Raise to front so the subsequent CG resolution is unambiguous
                set index of window \(windowIndex) to 1
            end tell
            """, target: .windowIndex(windowIndex))

        // Give Safari's window server a moment to reflect the z-order
        // change before CG scans — 100ms is empirically enough and
        // consistent with the delays used elsewhere in this file.
        try await Task.sleep(nanoseconds: 100_000_000)

        return try getFrontWindowID()
    }

    /// Legacy front-window resolver (used when `--window` is not set).
    /// Matches by exact title equality (not `hasPrefix`) because the old
    /// prefix match would mis-identify `"Example"` against
    /// `"Example — Extra"` — that was a latent bug surfaced by #23 verify.
    private static func getFrontWindowID() throws -> String {
        let frontBrowserWindowName: String? = {
            let proc = Process()
            proc.executableURL = URL(filePath: "/usr/bin/osascript")
            proc.arguments = ["-e", """
                tell application "Safari"
                    try
                        set t to current tab of front window
                        return name of front window
                    end try
                end tell
                """]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            throw SafariBrowserError.noSafariWindow
        }

        // First pass: exact title match (no fuzzy prefix).
        if let name = frontBrowserWindowName, !name.isEmpty {
            for w in windows {
                guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "Safari",
                      let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                      let wName = w[kCGWindowName as String] as? String,
                      wName == name,
                      let num = w[kCGWindowNumber as String] as? Int else { continue }
                return String(num)
            }
        }

        // Fallback: first Safari window with height > 100 (legacy behavior
        // preserved for the no-target case; --window N never lands here).
        for w in windows {
            guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "Safari",
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let height = bounds["Height"] as? Int, height > 100,
                  let num = w[kCGWindowNumber as String] as? Int else { continue }
            return String(num)
        }
        throw SafariBrowserError.noSafariWindow
    }

    // MARK: - Shell Runner

    /// Default timeout for AppleScript / shell subprocesses. Prevents infinite hangs
    /// when Safari's Apple Event dispatcher or System Events is blocked (see #19).
    static let defaultProcessTimeout: TimeInterval = 30.0

    @discardableResult
    static func runShell(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = SafariBridge.defaultProcessTimeout
    ) async throws -> String {
        try await runProcessWithTimeout(executable, arguments, timeout: timeout)
    }

    /// Thread-safe boolean flag used by `runProcessWithTimeout` to distinguish
    /// "watchdog killed the child" from "child died for any other reason".
    /// Prevents external signals (Ctrl+C, OOM killer, crash) being misreported as timeouts (#19 F2).
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        func set() {
            lock.lock()
            _value = true
            lock.unlock()
        }
        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
    }

    /// Minimum allowed timeout. Values below this round to 0 nanoseconds,
    /// which would make the watchdog fire before the subprocess could complete.
    private static let minimumProcessTimeout: TimeInterval = 0.001
    /// Maximum allowed timeout. One day is well beyond any legitimate Safari
    /// automation subprocess and keeps `timeout * 1e9` far below UInt64.max,
    /// so neither the Double multiply nor the UInt64 cast can trap (#19 R2-F1').
    private static let maximumProcessTimeout: TimeInterval = 86_400

    /// Run a subprocess with a wall-clock timeout.
    /// On timeout: SIGTERM → 1s grace → SIGKILL → throws `.processTimedOut`.
    /// Prevents `process.waitUntilExit()` from hanging forever when the child
    /// (osascript, /bin/sh) is blocked on Safari / System Events (see #19).
    private static func runProcessWithTimeout(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
        // #19 F1 + R2-F1' + R2-F1'': reject any timeout that can't survive the
        // UInt64(timeout * 1e9) conversion or that rounds to 0 nanoseconds.
        // Double.greatestFiniteMagnitude is finite but * 1e9 overflows to Inf,
        // which is why the old `isFinite && > 0` guard was insufficient.
        guard
            timeout.isFinite,
            timeout >= SafariBridge.minimumProcessTimeout,
            timeout <= SafariBridge.maximumProcessTimeout
        else {
            throw SafariBrowserError.invalidTimeout(timeout)
        }

        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Watchdog: terminate subprocess if timeout expires.
        // Killing the process causes its stdout/stderr pipes to close, which unblocks
        // the readDataToEndOfFile() calls below.
        // #19 F2: set didTimeout BEFORE terminate() so the main thread can distinguish
        // our kill from external signals.
        let didTimeout = TimeoutFlag()
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            if process.isRunning {
                didTimeout.set()
                process.terminate() // SIGTERM
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s grace
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        // Read pipes BEFORE waitUntilExit to prevent deadlock when output > 64KB
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        // Only report processTimedOut when the watchdog actually fired AND the
        // subprocess didn't exit cleanly. The extra terminationStatus check
        // closes the μs-wide race (#19 R2-F2') where the child exits naturally
        // in the window between the watchdog's isRunning check and the main
        // thread observing termination — in that case terminationStatus is 0
        // and we should treat the run as successful, not a timeout.
        if didTimeout.value && process.terminationStatus != 0 {
            let cmdStr = ([executable] + arguments).joined(separator: " ")
            // Use ceil so sub-second timeouts don't render as "0 seconds".
            throw SafariBrowserError.processTimedOut(
                command: cmdStr,
                seconds: max(1, Int(timeout.rounded(.up)))
            )
        }

        if process.terminationStatus != 0 {
            let errorMessage = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw SafariBrowserError.appleScriptFailed(errorMessage)
        }

        return String(data: outputData, encoding: .utf8)?
            .replacingOccurrences(of: "\\n$", with: "", options: .regularExpression) ?? ""
    }

    // MARK: - Accessibility Permission

    /// Check if the current process has Accessibility (System Events) permission.
    static func isAccessibilityPermitted() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - System Events Liveness (#20)

    /// Probe whether `System Events` is responsive. Runs a short AppleScript
    /// inside `runShell(timeout:)` so the probe itself cannot hang — the
    /// watchdog from #19 bounds the worst case.
    /// Any failure (timeout, non-zero exit, syntax error, missing executable,
    /// etc.) is wrapped as `SafariBrowserError.systemEventsNotResponding` so
    /// callers get one actionable error type regardless of the underlying
    /// failure mode.
    static func probeSystemEvents(timeout: TimeInterval = 2.0) async throws {
        // The canonical liveness check: ask System Events for its own name.
        // If System Events is up, this returns instantly with "System Events".
        try await probeSystemEvents(
            script: #"tell application "System Events" to return name"#,
            timeout: timeout
        )
    }

    /// Internal seam for tests: run an arbitrary AppleScript under the probe's
    /// error-wrapping semantics so tests can exercise timeout, failure, and
    /// executable-missing paths without depending on the real System Events
    /// process state.
    static func probeSystemEvents(
        executable: String = "/usr/bin/osascript",
        script: String,
        timeout: TimeInterval
    ) async throws {
        do {
            _ = try await runShell(executable, ["-e", script], timeout: timeout)
        } catch {
            // #20 F1: generic catch. runShell can throw non-SafariBrowserError
            // (e.g. CocoaError when the executable doesn't exist). Wrap every
            // failure so the "one actionable error type" contract holds.
            throw SafariBrowserError.systemEventsNotResponding(
                underlying: error.localizedDescription
            )
        }
    }

    /// Best-effort restart: `killall "System Events"` (ignoring failure since
    /// the process may already be down) and then re-probe. Relies on launchd
    /// to relaunch System Events on the next Apple Event (it's an on-demand
    /// LaunchAgent, not a KeepAlive process) — so the relaunch actually
    /// happens inside the re-probe itself, not during the sleep. We keep a
    /// short sleep to let launchd reap the killed PID before we talk to
    /// the new one. `launchctl kickstart` is avoided because it requires
    /// permissions that aren't always available and is flaky across macOS
    /// versions.
    /// Throws `.systemEventsNotResponding` if the post-kill probe still
    /// fails, so callers can propagate the underlying detail without doing
    /// a redundant extra probe themselves.
    static func restartSystemEvents() async throws {
        // #20 F3: loudly warn before interfering with other users of System
        // Events. This violates the "don't interrupt unrelated automation"
        // spirit of the non-interference spec unless we explicitly name the
        // side effect, so the user at least sees what's happening.
        FileHandle.standardError.write(Data("""
            ⚠️  Restarting System Events. This will interrupt any other active
               System Events automation (Keyboard Maestro, Alfred, Shortcuts, etc.).

            """.utf8))

        // killall is best effort — if System Events is already dead, it will
        // exit non-zero and runShell will throw. We want to continue regardless.
        _ = try? await runShell("/usr/bin/killall", ["System Events"], timeout: 2.0)
        // Short pause so launchd can reap the killed process before we talk to
        // the (on-demand) new instance via the re-probe below.
        try? await Task.sleep(nanoseconds: 500_000_000)
        // #20 F6: propagate the probe error instead of swallowing to Bool so
        // callers don't need a redundant third probe to recover it.
        try await probeSystemEvents()
    }

    /// Probe → (on failure) restart → re-probe chain used by any command
    /// that sends keystrokes through System Events. Throws
    /// `.systemEventsNotResponding` if the process cannot be recovered, so
    /// callers can surface a single actionable error instead of hanging
    /// inside the real AppleScript (#20).
    static func ensureSystemEventsLive() async throws {
        // #20 F2: deferred "waiting" message. If the first probe finishes
        // quickly (normal path) the user sees nothing; if it takes more than
        // 500 ms (System Events struggling) we print a status line so the
        // user never faces a silent hang — issue requirement 3.
        let waitingMessage = Task.detached {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            FileHandle.standardError.write(
                Data("⏳ Waiting for System Events...\n".utf8)
            )
        }
        defer { waitingMessage.cancel() }

        do {
            try await probeSystemEvents()
            return
        } catch {
            FileHandle.standardError.write(
                Data("⚠️  System Events not responding, attempting restart...\n".utf8)
            )
        }

        // #20 F6: restartSystemEvents now throws, so the underlying error is
        // propagated directly. No redundant third probe.
        try await restartSystemEvents()
        FileHandle.standardError.write(Data("✓ System Events recovered\n".utf8))
    }

    // MARK: - File Dialog Navigation

    /// Navigate a macOS file dialog using System Events.
    /// Uses clipboard paste (Cmd+V) for path input instead of keystroke.
    /// Saves and restores the user's clipboard content.
    /// Requires: a file dialog sheet to be already open on Safari's front window.
    /// Note: uploadViaNativeDialog uses its own combined osascript (see #15).
    /// This function is kept for other callers but now includes a frontmost safety check.
    static func navigateFileDialog(path: String) async throws {
        // #20: probe/restart System Events before touching the keyboard. Same
        // rationale as `UploadCommand.uploadViaNativeDialog`.
        try await ensureSystemEventsLive()

        try await runShell("/usr/bin/osascript", ["-e", """
            tell application "Safari" to activate
            tell application "System Events"
                tell process "Safari"
                    -- Verify Safari is frontmost before sending any keystrokes
                    if not frontmost then
                        error "Safari is not frontmost — aborting to avoid sending keystrokes to wrong application"
                    end if

                    -- Save user's clipboard
                    set oldClip to the clipboard

                    try
                        -- Open "Go to Folder" panel
                        keystroke "g" using {command down, shift down}

                        -- Wait for Go to Folder nested sheet to appear
                        set maxWait to 10
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
            """])
    }

    // MARK: - AppleScript Runner

    @discardableResult
    private static func runAppleScript(
        _ script: String,
        timeout: TimeInterval = SafariBridge.defaultProcessTimeout
    ) async throws -> String {
        try await runProcessWithTimeout("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }
}

// MARK: - String Escaping

extension String {
    var escapedForAppleScript: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    var escapedForJS: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\0", with: "\\0")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Returns a JS double-quoted string literal (with proper escaping for multi-line content)
    var jsStringLiteral: String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\0", with: "\\0")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }

    /// Returns JS expression that resolves to a DOM element.
    /// If self starts with @eN, resolves from window.__sbRefs.
    /// Otherwise, uses document.querySelector.
    var resolveRefJS: String {
        if let match = self.wholeMatch(of: /^@e([1-9]\d*)$/) {
            let index = Int(match.1)! - 1
            return "(function(){ if (!window.__sbRefs) return null; return window.__sbRefs[\(index)] || null; })()"
        } else {
            return "document.querySelector('\(self.escapedForJS)')"
        }
    }

    /// Whether this string is a @ref pattern
    var isRef: Bool {
        self.wholeMatch(of: /^@e([1-9]\d*)$/) != nil
    }

    /// Error message for when a ref is invalid
    var refErrorMessage: String {
        if isRef {
            return "Invalid ref: \(self) (run safari-browser snapshot first)"
        }
        return "Element not found: \(self)"
    }
}
