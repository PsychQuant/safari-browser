import CoreGraphics
import Foundation

/// #30: payload for `elementAmbiguous` errors — one entry per match so
/// the error message can list rect + attrs + text snippet to help the
/// user pick the right disambiguation strategy (refine selector vs.
/// `--element-index N`).
struct ElementMatch: Equatable {
    /// Match's viewport-relative bounding rect in points (from
    /// `getBoundingClientRect`).
    let rect: CGRect
    /// Compact attribute description: `tag.class#id` form,
    /// constructed from the DOM element.
    let attributes: String
    /// First 60 characters of `textContent`, whitespace-trimmed.
    /// Nil when the element has no text content.
    let textSnippet: String?
}

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
    case elementAmbiguous(selector: String, matches: [ElementMatch])
    case elementIndexOutOfRange(selector: String, index: Int, matchCount: Int)
    case elementZeroSize(selector: String)
    case elementOutsideViewport(selector: String, rect: CGRect, viewport: CGSize)
    case elementSelectorInvalid(selector: String, reason: String)
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
            // #30 enriched: this case is shared by many commands
            // (click, fill, screenshot, etc.); the richer message helps
            // every caller, not just --element. Keeps command-agnostic
            // recovery hints — no mention of `--element` specifically.
            return """
                No element matches selector: \(selector)
                `document.querySelectorAll("\(selector)")` returned zero
                elements. Common causes:
                  - Page not fully loaded — try
                    `safari-browser wait --js "document.querySelector('...') !== null"`
                    before the command
                  - Selector targets Shadow DOM content (not reachable from
                    the top document's querySelectorAll)
                  - Element is inside an iframe — switch target to the
                    iframe's document first
                  - Selector typo (case-sensitivity, missing dot/hash, etc.)
                """
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
            // #30: alternative guidance varies by flag because the
            // fallback path differs. --content-only can fall back by
            // dropping the flag (still useful output). --element
            // cannot — without AX there's no way to know the web
            // area origin, so we steer users to a different
            // command shape (capture whole window + external crop).
            let alternative: String
            switch flag {
            case "--element":
                alternative = """
                    Alternative (no permission needed):
                      Re-run with explicit `--window N` or `--url <pattern>`
                      to capture the whole window, then crop externally to
                      the element's bounding box using ImageMagick's
                      `convert ... -crop` or `sips --cropOffset` + sizing.
                      You can read the element's bounds via
                      `safari-browser js "document.querySelector('...').getBoundingClientRect()"`
                      to find the crop coordinates.
                    """
            case "--content-only":
                alternative = """
                    Alternative (no permission needed):
                      Re-run without `--content-only` to receive a
                      chrome-included screenshot that you can crop with an
                      external tool.
                    """
            default:
                alternative = """
                    Alternative (no permission needed):
                      Re-run without `\(flag)` — the resulting screenshot
                      will skip the \(flag)-specific processing but the
                      capture itself still works.
                    """
            }
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

                \(alternative)
                """
        case .elementAmbiguous(let selector, let matches):
            let lines = matches.enumerated().map { (i, m) -> String in
                let text = m.textSnippet.map { "    text=\"\($0)\"" } ?? ""
                return "  [\(i + 1)] rect={x:\(Int(m.rect.origin.x)), y:\(Int(m.rect.origin.y)), w:\(Int(m.rect.size.width)), h:\(Int(m.rect.size.height))}    \(m.attributes)\(text)"
            }.joined(separator: "\n")
            return """
                Multiple elements match "\(selector)":
                \(lines)
                Disambiguate by either:
                  1. Refine selector: add a class/id (e.g. ".card.featured")
                     or structural pseudo-class (":nth-of-type(2)")
                  2. Add `--element-index N` to pick the Nth match above
                     (1-indexed, document order)
                """
        case .elementIndexOutOfRange(let selector, let index, let matchCount):
            return """
                --element-index \(index) is out of range for selector "\(selector)"
                (matches: \(matchCount)).
                Valid range is 1 to \(matchCount). Re-run without
                `--element-index` to see the rich ambiguous error listing
                all matches, or adjust the index to a valid value.
                """
        case .elementZeroSize(let selector):
            return """
                Element "\(selector)" has zero size (width or height is 0).
                Likely causes:
                  - The element has `display: none` or `visibility: hidden`
                  - Parent container has zero dimensions (collapsed flex
                    item, un-rendered tab panel, etc.)
                  - The element hasn't been inserted in the render tree yet

                A zero-size crop produces an empty PNG, so the command
                fails closed rather than silently emitting broken output.
                Verify the element is visible:
                  `safari-browser js "getComputedStyle(document.querySelector('\(selector)')).display"`
                """
        case .elementOutsideViewport(let selector, let rect, let viewport):
            return """
                Element "\(selector)" is outside the current viewport.
                Element rect: {x:\(Int(rect.origin.x)), y:\(Int(rect.origin.y)), w:\(Int(rect.size.width)), h:\(Int(rect.size.height))}
                Viewport:     {w:\(Int(viewport.width)), h:\(Int(viewport.height))}

                `--element` captures pixels from the window's visible
                region; an off-screen element cannot be rendered into
                the captured PNG. Options:
                  - Scroll the element into view first, then re-run
                    (`safari-browser js "document.querySelector('\(selector)').scrollIntoView()"`)
                  - Use `--full` to resize the window to the scrollable
                    page dimensions — if the element fits inside the
                    post-resize viewport it can be cropped in one shot
                  - Automatic scroll-into-view is out of scope for this
                    release; see the follow-up issue for `--scroll-into-view`
                """
        case .elementSelectorInvalid(let selector, let reason):
            return """
                Invalid CSS selector "\(selector)": \(reason)
                `querySelectorAll` rejected the selector with a SyntaxError.
                Common causes:
                  - Unescaped special characters (use backslash or CSS.escape)
                  - Unclosed attribute brackets or quotes
                  - CSS4-only syntax not yet supported by WebKit (e.g. `:is()`
                    nesting beyond one level, `:has()` in older Safari)
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
