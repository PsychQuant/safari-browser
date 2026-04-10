import ApplicationServices
import CoreGraphics
import Foundation

enum SafariBridge {
    // MARK: - Navigation

    static func openURL(_ url: String) async throws {
        // #9: Use do JavaScript for navigation to avoid race with page's own JS redirects.
        // Fallback to set URL when do JavaScript fails (e.g., about:blank, no open tabs).
        let jsCode = "window.location.href=\(url.jsStringLiteral)"
        try await runAppleScript("""
            tell application "Safari"
                activate
                if (count of windows) = 0 then
                    make new document with properties {URL:"\(url.escapedForAppleScript)"}
                else
                    try
                        do JavaScript "\(jsCode.escapedForAppleScript)" in current tab of front window
                    on error
                        set URL of current tab of front window to "\(url.escapedForAppleScript)"
                    end try
                end if
            end tell
            """)
    }

    static func openURLInNewTab(_ url: String) async throws {
        try await runAppleScript("""
            tell application "Safari"
                activate
                if (count of windows) = 0 then
                    make new document with properties {URL:"\(url.escapedForAppleScript)"}
                else
                    tell front window
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

    static func closeCurrentTab() async throws {
        try await runAppleScript("""
            tell application "Safari"
                close current tab of front window
            end tell
            """)
    }

    // MARK: - JavaScript

    static func doJavaScript(_ code: String) async throws -> String {
        try await runAppleScript("""
            tell application "Safari"
                do JavaScript "\(code.escapedForAppleScript)" in current tab of front window
            end tell
            """)
    }

    /// Execute JS and read large results via chunked transfer.
    /// Stores result in window.__sbResult, then reads back in 256KB chunks.
    static func doJavaScriptLarge(_ code: String) async throws -> String {
        // Store result in window variable
        _ = try await doJavaScript(
            "(function(){ window.__sbResult = '' + (\(code)); window.__sbResultLen = window.__sbResult.length; })()"
        )

        // Get total length
        let lenStr = try await doJavaScript("window.__sbResultLen")
        guard let totalLen = Int(lenStr.trimmingCharacters(in: .whitespacesAndNewlines)), totalLen > 0 else {
            return ""
        }

        // Read in chunks
        let chunkSize = 262144 // 256KB
        var result = ""
        var offset = 0
        while offset < totalLen {
            let end = min(offset + chunkSize, totalLen)
            let chunk = try await doJavaScript("window.__sbResult.substring(\(offset), \(end))")
            result += chunk
            offset = end
        }

        // Cleanup
        _ = try await doJavaScript("delete window.__sbResult; delete window.__sbResultLen")

        return result
    }

    // MARK: - Page Info

    static func getCurrentURL() async throws -> String {
        try await runAppleScript("""
            tell application "Safari"
                get URL of current tab of front window
            end tell
            """)
    }

    static func getCurrentTitle() async throws -> String {
        try await runAppleScript("""
            tell application "Safari"
                get name of current tab of front window
            end tell
            """)
    }

    static func getCurrentText() async throws -> String {
        try await runAppleScript("""
            tell application "Safari"
                get text of current tab of front window
            end tell
            """)
    }

    static func getCurrentSource() async throws -> String {
        try await runAppleScript("""
            tell application "Safari"
                get source of current tab of front window
            end tell
            """)
    }

    // MARK: - Tab Management

    struct TabInfo: Sendable {
        let index: Int
        let title: String
        let url: String
    }

    static func listTabs() async throws -> [TabInfo] {
        let countStr = try await runAppleScript("""
            tell application "Safari"
                if (count of windows) = 0 then
                    return "0"
                end if
                count of tabs of front window
            end tell
            """)

        guard let count = Int(countStr.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 else {
            return []
        }

        var tabs: [TabInfo] = []
        for i in 1...count {
            let title = try await runAppleScript("""
                tell application "Safari"
                    get name of tab \(i) of front window
                end tell
                """)
            let url = try await runAppleScript("""
                tell application "Safari"
                    get URL of tab \(i) of front window
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

    static func switchToTab(_ index: Int) async throws {
        try await runAppleScript("""
            tell application "Safari"
                set current tab of front window to tab \(index) of front window
            end tell
            """)
    }

    static func openNewTab() async throws {
        try await runAppleScript("""
            tell application "Safari"
                activate
                if (count of windows) = 0 then
                    make new document
                else
                    tell front window
                        set newTab to make new tab
                        set current tab to newTab
                    end tell
                end if
            end tell
            """)
    }

    // MARK: - Screenshot

    static func getWindowID() throws -> String {
        // Use AppleScript to get front document window's name and verify it has a tab (= browser window)
        // Settings/Preferences windows have no tabs, so this filters them out
        let frontBrowserWindowName: String? = {
            let proc = Process()
            proc.executableURL = URL(filePath: "/usr/bin/osascript")
            proc.arguments = ["-e", """
                tell application "Safari"
                    try
                        -- front window is always the topmost; check if it's a browser window (has tabs)
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

        // First pass: match by browser window name
        if let name = frontBrowserWindowName, !name.isEmpty {
            for w in windows {
                guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "Safari",
                      let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                      let wName = w[kCGWindowName as String] as? String,
                      wName == name || name.hasPrefix(wName),
                      let num = w[kCGWindowNumber as String] as? Int else { continue }
                return String(num)
            }
        }

        // Fallback: first Safari window with height > 100 (original behavior)
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

    /// Run a subprocess with a wall-clock timeout.
    /// On timeout: SIGTERM → 1s grace → SIGKILL → throws `.processTimedOut`.
    /// Prevents `process.waitUntilExit()` from hanging forever when the child
    /// (osascript, /bin/sh) is blocked on Safari / System Events (see #19).
    private static func runProcessWithTimeout(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
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
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
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

        // A terminationReason of .uncaughtSignal means the process was killed
        // (SIGTERM/SIGKILL). In our code path the only source of signals is the
        // watchdog above, so this reliably indicates a timeout.
        if process.terminationReason == .uncaughtSignal {
            let cmdStr = ([executable] + arguments).joined(separator: " ")
            throw SafariBrowserError.processTimedOut(command: cmdStr, seconds: Int(timeout.rounded()))
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

    // MARK: - File Dialog Navigation

    /// Navigate a macOS file dialog using System Events.
    /// Uses clipboard paste (Cmd+V) for path input instead of keystroke.
    /// Saves and restores the user's clipboard content.
    /// Requires: a file dialog sheet to be already open on Safari's front window.
    /// Note: uploadViaNativeDialog uses its own combined osascript (see #15).
    /// This function is kept for other callers but now includes a frontmost safety check.
    static func navigateFileDialog(path: String) async throws {
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
