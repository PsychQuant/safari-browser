import Foundation

enum SafariBrowserError: LocalizedError {
    case appleScriptFailed(String)
    case fileNotFound(String)
    case invalidTabIndex(Int)
    case timeout(seconds: Int)
    case processTimedOut(command: String, seconds: Int)
    case invalidTimeout(Double)
    case systemEventsNotResponding(underlying: String)
    case documentNotFound(pattern: String, availableDocuments: [String])
    case ambiguousWindowMatch(pattern: String, matches: [(windowIndex: Int, url: String)])
    case backgroundTabNotCapturable(windowIndex: Int, tabIndex: Int)
    case noSafariWindow
    case elementNotFound(String)
    case accessibilityNotGranted
    case accessibilityRequired(flag: String)
    case webAreaNotFound(reason: String)
    case imageCroppingFailed(reason: String)
    case axOperationFailed(String)
    case windowIdentityAmbiguous(reason: String)

    var errorDescription: String? {
        switch self {
        case .appleScriptFailed(let message):
            return "AppleScript error: \(message)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .invalidTabIndex(let index):
            return "Invalid tab index: \(index)"
        case .timeout(let seconds):
            return "Timeout after \(seconds) seconds"
        case .processTimedOut(let command, let seconds):
            return """
                Process timed out after \(seconds) seconds: \(command)
                Hint: if this recurs, check Console.app for System Events or Apple Event dispatcher issues.
                """
        case .invalidTimeout(let value):
            return "Invalid timeout value: \(value) (must be a finite number between 0.001 and 86400 seconds)"
        case .systemEventsNotResponding(let underlying):
            return """
                System Events is not responding. Keyboard-simulating commands (e.g. `upload --native`, `pdf`) cannot proceed.
                Try restarting it manually: killall "System Events" (launchd will relaunch it on the next Apple Event)
                Note: this will interrupt other active System Events automation (Keyboard Maestro, Alfred, Shortcuts, etc.).
                Underlying: \(underlying)
                """
        case .documentNotFound(let pattern, let availableDocuments):
            let listing: String
            if availableDocuments.isEmpty {
                listing = "  (no Safari documents are currently open)"
            } else {
                listing = availableDocuments.enumerated()
                    .map { "  [\($0.offset + 1)] \($0.element)" }
                    .joined(separator: "\n")
            }
            return """
                No Safari document matches "\(pattern)".
                Available documents:
                \(listing)
                Run `safari-browser documents` to list documents, or use a different --url / --window / --document value.
                """
        case .backgroundTabNotCapturable(let windowIndex, let tabIndex):
            return """
                Screenshot target resolves to a background tab (window \(windowIndex), tab \(tabIndex))
                but screenshot captures window-level visible pixels — it cannot render a tab that
                isn't currently visible in its window. Either bring the target tab to the front
                manually (Safari → click the tab, or `safari-browser tab \(tabIndex) --window \(windowIndex)`)
                then re-run the screenshot, or use a document-scoped command that reads DOM content
                instead of visible pixels:
                  `safari-browser snapshot --url <pattern>` / `get source --url <pattern>`

                Note: upload / pdf / close do switch tabs automatically because their keystroke
                path is interfering anyway; screenshot intentionally preserves non-interference
                and refuses to switch tabs for you (see #26 non-interference spec).
                """
        case .ambiguousWindowMatch(let pattern, let matches):
            let listing: String
            if matches.isEmpty {
                listing = "  (internal error: empty matches array)"
            } else {
                listing = matches
                    .map { "  [window \($0.windowIndex)] \($0.url)" }
                    .joined(separator: "\n")
            }
            return """
                Multiple Safari windows match "\(pattern)":
                \(listing)
                Disambiguate by:
                  1. Use a more specific --url substring (e.g., "plaud.ai/file/abc" instead of "plaud").
                  2. Use --window N --tab-in-window M to target a specific tab by position.
                  3. Pass --first-match to accept the first match (with a stderr warning listing all candidates).
                """
        case .noSafariWindow:
            return "No Safari window found"
        case .elementNotFound(let selector):
            return "Element not found: \(selector)"
        case .axOperationFailed(let message):
            return """
                Accessibility operation failed: \(message)
                This can happen when the target Safari window is in a state that
                rejects AX mutations (fullscreen, minimized, split-view, or in
                the middle of a Space transition). Workarounds:
                  - Exit fullscreen and unminimize the target window
                  - Use `safari-browser screenshot --window N` (without --full)
                    which does not require AX bounds mutation
                """
        case .windowIdentityAmbiguous(let reason):
            return """
                Could not uniquely identify the target Safari window: \(reason)
                This happens when multiple Safari windows cannot be distinguished
                by bounds (e.g., several maximized windows on the same display)
                and no unique frontmost candidate exists. The CLI fails loudly
                rather than silently guessing which window to act on.
                Workarounds:
                  - Resize one of the collision windows so bounds differ
                  - Unminimize or bring forward one of the candidates
                  - Use document-scoped commands instead: `snapshot --url`,
                    `get text --url`, `get source --url` — these bypass the
                    CG window-ID boundary entirely
                """
        case .accessibilityRequired(let flag):
            return """
                Accessibility permission required for `screenshot \(flag)`.
                The CLI reads the Safari web content area geometry via the
                Accessibility API (kAXWebAreaRole + kAXPositionAttribute +
                kAXSizeAttribute) to compute an exact crop rectangle. A
                JavaScript-based viewport measurement fallback was rejected
                during design because it silently errs on Reader Mode,
                sidebar, and zoom states — the `\(flag)` flag is precision-
                sensitive and only supports the AX path.

                Grant permission:
                  System Settings → Privacy & Security → Accessibility → enable
                  Terminal (or your shell) and re-run the command.

                Alternative (no permission needed):
                  Re-run without `\(flag)` to receive a chrome-included
                  screenshot that you can crop with an external tool.
                """
        case .imageCroppingFailed(let reason):
            return """
                Image cropping failed: \(reason)
                The screenshot was captured but the chrome-cropping step
                could not complete. The file on disk may be the original
                un-cropped capture or may not exist — check its presence
                before re-running.
                """
        case .webAreaNotFound(let reason):
            return """
                Could not locate the Safari web content area: \(reason)
                This happens when the AXWebArea element is unreachable within
                the first 3 levels of the window's AX tree — possible causes:
                  - Private window with restricted AX tree
                  - PDF preview, Reader Mode in an unusual state, or a page
                    that hasn't finished loading
                  - Extension toolbars or developer tools altering the tree

                Workaround: re-run `safari-browser screenshot` without
                `--content-only`. The capture will include Safari chrome but
                will succeed; crop externally if needed.
                """
        case .accessibilityNotGranted:
            return """
                Accessibility permission required for `screenshot --window N`.
                The CLI uses the AXUIElement private SPI (_AXUIElementGetWindow) to
                map AppleScript window indices to Core Graphics window IDs without
                raising the window — this avoids the silent wrong-window failure
                modes that bedevil bounds- and title-based matching (#23 verify R1-R5).

                Grant permission:
                  System Settings → Privacy & Security → Accessibility → enable
                  Terminal (or your shell) and re-run the command.

                Without permission, `screenshot` (no --window flag) still works
                — it captures the current front Safari window via the legacy CG
                name match path. `pdf --window N` and `upload --native --window N`
                also still work because they intentionally raise window N before
                their keystroke operations (keystrokes inherently target the
                front window).
                """
        }
    }
}
