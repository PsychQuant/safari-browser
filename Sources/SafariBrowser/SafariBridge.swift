import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

// MARK: - Private AX SPI (#23 verify R5→R6)
//
// Apple's public AX API does not expose the CGWindowID for a given
// AXUIElement. The private SPI `_AXUIElementGetWindow` does, and has
// been stable since macOS 10.6 — used by Hammerspoon, yabai, Rectangle,
// Magnet, and most macOS window-management tools. We declare it via
// `@_silgen_name` because Swift does not export the symbol publicly.
//
// This is what lets us map AppleScript `window N` → CG window ID
// without RAISING the window. Bounds and title matching (R1-R5) all
// have failure modes; AX is the only API that talks to Safari's
// internal window table directly.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ outID: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Private CGS SPI (Group 9: Spatial gradient Space detection)
//
// Space detection needs the CGSServices ("SkyLight") private SPI. Apple
// does not expose Space membership through any public API — NSWorkspace
// lacks it, CGWindow dicts don't include it. The CGS SPI has been used
// by yabai, Witch, Contexts, and every serious window manager for
// ~15 years and is stable across macOS 10.x → 15.
//
// `CGSMainConnectionID()` returns the default GUI connection ID.
// `CGSGetActiveSpace(cid)` returns the Space ID of the active Space.
// `CGSGetWindowWorkspace(cid, wid, &space)` returns the Space ID of a
// given window (0 == success; non-zero == failure).
//
// Space IDs are opaque UInt64 — we never interpret them, just compare
// equality to decide same-Space vs cross-Space in the spatial gradient.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: Int32) -> UInt64

@_silgen_name("CGSGetWindowWorkspace")
private func CGSGetWindowWorkspace(_ cid: Int32, _ wid: CGWindowID, _ space: UnsafeMutablePointer<UInt64>) -> Int32

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
        /// Select document by URL via a `UrlMatcher` sum-type. Variance
        /// in matching mode (substring, exact, endsWith, regex) is
        /// encapsulated in `UrlMatcher` so downstream switches on
        /// `TargetDocument` stay flat. All matcher cases resolve through
        /// the native-path resolver (`resolveNativeTarget` →
        /// `pickNativeTarget`) for uniform fail-closed semantics.
        case urlMatch(UrlMatcher)
        case documentIndex(Int)
        /// Composite target: the tab-in-window-th tab of the window-th
        /// window. Addresses same-URL duplicate tabs that `.urlMatch`
        /// cannot disambiguate (issue #28 gap #2). Always requires both
        /// coordinates — `TargetOptions.validate()` rejects solo
        /// `--tab-in-window` at the CLI boundary, and `pickNativeTarget`
        /// rejects out-of-range values.
        case windowTab(window: Int, tabInWindow: Int)

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
        case .urlMatch:
            // Per document-targeting spec delta: .urlMatch resolves through
            // the native-path resolver (resolveNativeTarget → pickNativeTarget)
            // so every matcher kind (contains/exact/endsWith/regex) obeys the
            // unified fail-closed policy uniformly. This branch is unreachable
            // in production because resolveToAppleScript dispatches .urlMatch
            // exclusively through resolveNativeTarget; defensive guard below.
            preconditionFailure(
                "TargetDocument.urlMatch SHALL be resolved through the native-path "
                + "resolver (resolveNativeTarget), not resolveDocumentReference"
            )
        case .documentIndex(let n):
            return "document \(n)"
        case .windowTab(let w, let t):
            return "tab \(t) of window \(w)"
        }
    }

    /// Produce an AppleScript document reference from a
    /// `ResolvedWindowTarget`. Pure — used by `resolveToAppleScript`
    /// after Native-path resolution. When `tabIndexInWindow` is set,
    /// the reference points at that specific tab; otherwise it points
    /// at the current tab's document via `document of window N`.
    static func docRefFromResolved(_ resolved: ResolvedWindowTarget) -> String {
        if let tab = resolved.tabIndexInWindow {
            return "tab \(tab) of window \(resolved.windowIndex)"
        }
        return "document of window \(resolved.windowIndex)"
    }

    /// Async dispatch: produce an AppleScript document reference after
    /// (when needed) running the Native-path resolver. This is the
    /// unified entry point for `.urlContains` / `.documentIndex` /
    /// `.windowTab` targets — they go through `resolveNativeTarget`
    /// first so multi-match `.urlContains` fails closed with
    /// `ambiguousWindowMatch` (per the `human-emulation` fail-closed
    /// requirement) instead of silently picking the first match as
    /// `(first document whose URL contains ...)` would.
    ///
    /// `.frontWindow` / `.windowIndex` bypass enumeration and use the
    /// sync mapping directly — no resolution needed.
    /// `firstMatch` / `warnWriter` plumb the CLI's `--first-match` intent
    /// through to `resolveNativeTarget` so read-path commands (`js`,
    /// `get`, `snapshot`, `storage`, `wait`, …) honor multi-match
    /// fallback identically to native-path commands (#33 plumb-through
    /// fix). Defaults keep the parameter additive for existing callers.
    static func resolveToAppleScript(
        _ target: TargetDocument,
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) async throws -> String {
        switch target {
        case .frontWindow, .windowIndex:
            return resolveDocumentReference(target)
        case .urlMatch, .documentIndex, .windowTab:
            let resolved = try await resolveNativeTarget(
                from: target,
                firstMatch: firstMatch,
                warnWriter: warnWriter
            )
            return docRefFromResolved(resolved)
        }
    }

    /// Resolve a `TargetDocument` to a **concrete** (window, tab) target
    /// and return it as a `.windowTab` / `.windowIndex` / `.frontWindow`
    /// that downstream calls can reuse without re-resolving. Intended for
    /// commands that issue multiple bridge calls per invocation (e.g.
    /// `JSCommand` which does store / read-length / read-result / delete
    /// sequentially): resolve once, pass the concrete target to every
    /// subsequent call so the `--first-match` warning fires **at most
    /// once per command** and subsequent calls cannot race on tab list
    /// changes (#33 R1 regression found during manual QA —
    /// `js --url-endswith /play --first-match` emitted the warning twice
    /// because every internal `doJavaScript` re-invoked the resolver).
    ///
    /// - `.frontWindow` / `.windowIndex` / `.windowTab` return unchanged
    ///   (already concrete).
    /// - `.urlMatch` / `.documentIndex` resolve via `resolveNativeTarget`
    ///   (fires `warnWriter` at most once) and collapse to `.windowTab`
    ///   when a specific tab-in-window is known, or `.windowIndex` when
    ///   only the window is known (tab defaults to current-of-window).
    static func resolveToConcreteTarget(
        _ target: TargetDocument,
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) async throws -> TargetDocument {
        switch target {
        case .frontWindow, .windowIndex, .windowTab:
            return target
        case .urlMatch, .documentIndex:
            let resolved = try await resolveNativeTarget(
                from: target,
                firstMatch: firstMatch,
                warnWriter: warnWriter
            )
            if let tab = resolved.tabIndexInWindow {
                return .windowTab(window: resolved.windowIndex, tabInWindow: tab)
            }
            return .windowIndex(resolved.windowIndex)
        }
    }

    // MARK: - Focus-existing (Group 8: open default)

    /// Pure helper: given an enumeration of windows, find the first tab
    /// whose URL exactly matches `url`. Returns `(windowIndex,
    /// tabInWindow, isCurrent)` or `nil`. Exact match (not substring)
    /// so `open` does not focus unrelated pages that share a prefix.
    static func findExactMatch(url: String, in windows: [WindowInfo]) -> (window: Int, tabInWindow: Int, isCurrent: Bool)? {
        for window in windows {
            for tab in window.tabs where tab.url == url {
                return (window.windowIndex, tab.tabIndex, tab.isCurrent)
            }
        }
        return nil
    }

    /// Async wrapper: enumerate Safari windows and search for an exact
    /// URL match. Used by `open` default dispatch (focus-existing) to
    /// decide between revealing the existing tab and opening a new one.
    static func findExactMatchingTab(url: String) async throws -> (window: Int, tabInWindow: Int, isCurrent: Bool)? {
        let windows = try await listAllWindows()
        return findExactMatch(url: url, in: windows)
    }

    /// One of four spatial-gradient outcomes for `open` focus-existing
    /// per the `human-emulation` principle and `non-interference` spec
    /// spatial-gradient requirement. The mapping:
    ///
    /// | Action | Spatial relationship | Interference class |
    /// |---|---|---|
    /// | `noop` | Target is the front tab of the front window | non-interfering |
    /// | `sameWindowTabSwitch` | Target is a background tab of the front window | passively interfering (no warning) |
    /// | `sameSpaceRaise` | Target is in a different window on the current Space | passively interfering (stderr warning) |
    /// | `crossSpaceNewTab` | Target is on a different macOS Space | non-interfering (new tab in current Space) |
    enum FocusAction: Sendable, Equatable {
        case noop
        case sameWindowTabSwitch
        case sameSpaceRaise
        case crossSpaceNewTab
    }

    /// Pure policy function for the spatial-interference gradient.
    /// Decides which of the four `FocusAction` cases applies given the
    /// target tab's position (window + isCurrent) and Space context.
    ///
    /// - Parameters:
    ///   - targetWindow: AppleScript window index of the matching tab (1-indexed).
    ///   - targetIsCurrent: whether the match is its window's current tab.
    ///   - frontWindowIndex: AppleScript's current front window index
    ///     (typically `1`, but parameterized so tests can exercise edge cases).
    ///   - currentSpace: opaque Space ID of the caller's active Space, or
    ///     `nil` when Space detection is unavailable (missing permission,
    ///     SPI failure, etc.).
    ///   - targetSpace: opaque Space ID of the target window's Space, or
    ///     `nil` when Space detection is unavailable.
    ///
    /// Fallback policy: when either Space ID is `nil`, the policy treats
    /// the target as same-Space (Layer 3 raise). This is the conservative
    /// direction — it matches legacy "always raise" behavior rather than
    /// silently skipping the raise because we couldn't detect Spaces.
    static func selectFocusAction(
        targetWindow: Int,
        targetIsCurrent: Bool,
        frontWindowIndex: Int = 1,
        currentSpace: UInt64? = nil,
        targetSpace: UInt64? = nil
    ) -> FocusAction {
        if targetWindow == frontWindowIndex && targetIsCurrent {
            return .noop
        }
        if targetWindow == frontWindowIndex {
            return .sameWindowTabSwitch
        }
        if let cur = currentSpace, let tgt = targetSpace, cur != tgt {
            return .crossSpaceNewTab
        }
        return .sameSpaceRaise
    }

    // MARK: - Space detection (Group 9: CGS SPI)

    /// Return the active macOS Space ID via the private CGS SPI
    /// `CGSGetActiveSpace`. Returns `nil` when the SPI returns 0 (which
    /// the SPI uses for error conditions — e.g., WindowServer not
    /// reachable). This function is synchronous and does not require
    /// Accessibility permission.
    static func getCurrentSpace() -> UInt64? {
        let cid = CGSMainConnectionID()
        let space = CGSGetActiveSpace(cid)
        return space == 0 ? nil : space
    }

    /// Return the Space ID of a given CGWindow, or `nil` on failure.
    static func detectSpace(cgWindowID: CGWindowID) -> UInt64? {
        let cid = CGSMainConnectionID()
        var space: UInt64 = 0
        let err = CGSGetWindowWorkspace(cid, cgWindowID, &space)
        guard err == 0, space != 0 else { return nil }
        return space
    }

    /// Best-effort: map AppleScript `window N` to its CGWindowID via
    /// the AX bridge. Requires Accessibility permission. Returns `nil`
    /// when permission is unavailable, when Safari is not running, or
    /// when the index is out of range for the AX window list.
    ///
    /// The returned CGWindowID can be passed to `detectSpace` to obtain
    /// the target window's Space ID. If this function returns `nil`,
    /// `selectFocusAction`'s `targetSpace` parameter should be `nil`
    /// and the policy falls back to Layer 3 (same-Space raise).
    static func detectWindowSpace(windowIndex: Int) -> UInt64? {
        guard AXIsProcessTrusted() else { return nil }
        guard let safari = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.Safari" })
        else { return nil }
        let axApp = AXUIElementCreateApplication(safari.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 2.0)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement],
              windowIndex >= 1, windowIndex <= axWindows.count
        else { return nil }
        var cgID: CGWindowID = 0
        guard _AXUIElementGetWindow(axWindows[windowIndex - 1], &cgID) == .success, cgID != 0 else {
            return nil
        }
        return detectSpace(cgWindowID: cgID)
    }

    /// Raise (activate) AppleScript `window N` so it becomes the
    /// frontmost Safari window. Used by spatial gradient Layer 3.
    /// AppleScript `set index of window N to 1` reorders windows; the
    /// subsequent `activate` of the application brings Safari to the
    /// foreground if it isn't already.
    static func activateWindow(_ n: Int) async throws {
        try await runAppleScript("""
            tell application "Safari"
                set index of window \(n) to 1
                activate
            end tell
            """)
    }

    /// Focus an existing tab by applying the spatial-interference
    /// gradient (Layers 1–4). Calls `selectFocusAction` to decide,
    /// then executes the chosen action:
    /// - `.noop`: return immediately.
    /// - `.sameWindowTabSwitch`: `performTabSwitchIfNeeded`.
    /// - `.sameSpaceRaise`: activate target window, then tab-switch;
    ///   emits a stderr warning via `warnWriter`.
    /// - `.crossSpaceNewTab`: open a new tab in the caller's current
    ///   Space front window; emits a stderr note.
    ///
    /// The `url` parameter is used only by the `.crossSpaceNewTab`
    /// branch to open a new tab with the requested URL. For the other
    /// three branches it can be the empty string but callers typically
    /// pass the match URL for consistency.
    static func focusExistingTab(
        window: Int,
        tabInWindow: Int,
        isCurrent: Bool,
        url: String = "",
        warnWriter: ((String) -> Void)? = nil
    ) async throws {
        let action = selectFocusAction(
            targetWindow: window,
            targetIsCurrent: isCurrent,
            frontWindowIndex: 1,
            currentSpace: getCurrentSpace(),
            targetSpace: detectWindowSpace(windowIndex: window)
        )
        switch action {
        case .noop:
            return
        case .sameWindowTabSwitch:
            try await performTabSwitchIfNeeded(window: window, tab: tabInWindow)
        case .sameSpaceRaise:
            warnWriter?("warning: open --focus-existing raised window \(window) to front (the matching tab lives in a background window).\n")
            try await activateWindow(window)
            try await performTabSwitchIfNeeded(window: window, tab: tabInWindow)
        case .crossSpaceNewTab:
            warnWriter?("note: open --focus-existing found a match in a different macOS Space — leaving that tab undisturbed and opening a new tab in the current Space.\n")
            try await openURLInNewTab(url, window: nil)
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
        case .urlMatch(let matcher): return matcher.description
        case .documentIndex(let n): return "document \(n)"
        case .windowTab(let w, let t): return "window \(w) tab \(t)"
        }
    }

    // MARK: - Navigation

    /// Navigate the target document to `url`. Uses `do JavaScript` against a
    /// document-scoped reference (bypasses #21 modal block), falling back to
    /// `set URL of <docRef>` if the script fails. When Safari has no windows,
    /// a new document is always created regardless of target.
    static func openURL(
        _ url: String,
        target: TargetDocument = .frontWindow,
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) async throws {
        // #9: Use do JavaScript for navigation to avoid race with page's own JS redirects.
        // Fallback to set URL when do JavaScript fails (e.g., about:blank, no open tabs).
        let jsCode = "window.location.href=\(url.jsStringLiteral)"
        let docRef = try await resolveToAppleScript(
            target,
            firstMatch: firstMatch,
            warnWriter: warnWriter
        )
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

    // MARK: - DOM element bounds (#30)

    /// #30: successful return from `getElementBoundsInViewport`.
    /// The element's viewport-relative bounds are returned alongside
    /// viewport size and match count so callers have the context
    /// needed to convert to window-relative coordinates and to emit
    /// informative logs.
    struct ElementBoundsResult: Equatable {
        /// Viewport-relative bounds in points (from `getBoundingClientRect`).
        let rectInViewport: CGRect
        /// `window.innerWidth` / `window.innerHeight` at eval time.
        let viewportSize: CGSize
        /// How many elements matched the selector (always >= 1 for
        /// successful return). Exposed for logging / observability.
        let matchCount: Int
        /// Chosen element's compact attribute description: `tag.class#id`.
        let attributes: String
        /// First 60 chars of textContent, whitespace-trimmed, nil if empty.
        let textSnippet: String?
    }

    /// #30: locate a DOM element by CSS selector and return its
    /// viewport-relative bounding rect and contextual info.
    ///
    /// Enforces the fail-closed semantics required by the screenshot
    /// `--element` spec:
    ///   - zero matches → `.elementNotFound(selector:)`
    ///   - multi-match without `elementIndex` → `.elementAmbiguous(selector:, matches:)`
    ///     (the `matches` array includes every candidate's rect + attrs + text snippet
    ///     so the caller can present a rich disambiguation error)
    ///   - `elementIndex` > matchCount or < 1 → `.elementIndexOutOfRange`
    ///   - chosen element with width or height ≤ 0 → `.elementZeroSize`
    ///   - chosen element extending beyond `window.innerWidth/Height` →
    ///     `.elementOutsideViewport` (caller decides whether to scroll or resize)
    ///   - invalid CSS selector (JS `SyntaxError`) → `.elementSelectorInvalid`
    ///
    /// Light DOM only — Shadow DOM and iframe traversal are out of scope
    /// per the #30 Non-Goals.
    ///
    /// - Parameters:
    ///   - selector: CSS selector; JSON-escaped before injection so
    ///     users can pass quotes, backslashes, and Unicode safely.
    ///   - target: document to evaluate against.
    ///   - elementIndex: 1-indexed position among matches. When nil
    ///     and the selector matches more than one element, the call
    ///     throws `.elementAmbiguous` rather than silently picking the
    ///     first match. A value of 1 on a unique match is accepted as
    ///     a valid assertion (no error).
    static func getElementBoundsInViewport(
        selector: String,
        target: TargetDocument = .frontWindow,
        elementIndex: Int? = nil
    ) async throws -> ElementBoundsResult {
        // JSON-encode the selector so backslashes/quotes/Unicode survive
        // injection into the JS source. Wrap in an array because
        // JSONSerialization requires a container at the root, then
        // strip the `[ ]` to get just the encoded string literal.
        let selectorJSON: String
        guard let data = try? JSONSerialization.data(withJSONObject: [selector]),
              let s = String(data: data, encoding: .utf8),
              s.hasPrefix("["), s.hasSuffix("]") else {
            throw SafariBrowserError.elementSelectorInvalid(
                selector: selector,
                reason: "could not JSON-encode selector for injection"
            )
        }
        selectorJSON = String(s.dropFirst().dropLast())

        // 1-indexed public API → 0-indexed internal; nil → null
        let indexJS: String
        if let idx = elementIndex {
            indexJS = String(idx - 1)
        } else {
            indexJS = "null"
        }

        let js = """
        JSON.stringify((() => {
          const selector = \(selectorJSON);
          const targetIndex = \(indexJS);
          let nodes;
          try { nodes = document.querySelectorAll(selector); }
          catch (e) { return { error: 'selector_invalid', reason: (e && e.message) || String(e) }; }
          if (nodes.length === 0) return { error: 'not_found' };
          function describe(el) {
            const r = el.getBoundingClientRect();
            let attrs = el.tagName.toLowerCase();
            if (el.id) attrs += '#' + el.id;
            if (el.className && typeof el.className === 'string') {
              const classes = el.className.split(/\\s+/).filter(c => c);
              if (classes.length > 0) attrs += '.' + classes.join('.');
            }
            const txt = (el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 60);
            return { x: r.x, y: r.y, w: r.width, h: r.height, attrs, text: txt || null };
          }
          let chosenIndex;
          if (nodes.length > 1) {
            if (targetIndex === null) return { error: 'ambiguous', matches: Array.from(nodes).map(describe) };
            if (targetIndex < 0 || targetIndex >= nodes.length) return { error: 'index_out_of_range', index: targetIndex + 1, matchCount: nodes.length };
            chosenIndex = targetIndex;
          } else {
            if (targetIndex !== null && targetIndex !== 0) return { error: 'index_out_of_range', index: targetIndex + 1, matchCount: 1 };
            chosenIndex = 0;
          }
          const el = nodes[chosenIndex];
          const r = el.getBoundingClientRect();
          if (r.width <= 0 || r.height <= 0) return { error: 'zero_size' };
          const iw = window.innerWidth, ih = window.innerHeight;
          if (r.x < 0 || r.y < 0 || r.x + r.width > iw || r.y + r.height > ih) {
            return { error: 'outside_viewport', x: r.x, y: r.y, w: r.width, h: r.height, iw: iw, ih: ih };
          }
          const d = describe(el);
          return { ok: { x: d.x, y: d.y, w: d.w, h: d.h, iw: iw, ih: ih, matchCount: nodes.length, attributes: d.attrs, textSnippet: d.text } };
        })())
        """

        let jsonString = try await doJavaScript(js, target: target)
        return try parseElementBoundsResponse(jsonString, selector: selector)
    }

    /// Internal helper: parse the JSON response from the element-bounds
    /// JS into either a success `ElementBoundsResult` or a thrown
    /// `SafariBrowserError`. Extracted so tests can exercise the
    /// parse / error-mapping logic without a live Safari window.
    static func parseElementBoundsResponse(
        _ jsonString: String,
        selector: String
    ) throws -> ElementBoundsResult {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SafariBrowserError.elementSelectorInvalid(
                selector: selector,
                reason: "could not parse element bounds response as JSON"
            )
        }

        if let errorKind = obj["error"] as? String {
            switch errorKind {
            case "not_found":
                throw SafariBrowserError.elementNotFound(selector)
            case "ambiguous":
                let rawMatches = (obj["matches"] as? [[String: Any]]) ?? []
                let matches = rawMatches.map { m in
                    ElementMatch(
                        rect: CGRect(
                            x: doubleValue(m["x"]),
                            y: doubleValue(m["y"]),
                            width: doubleValue(m["w"]),
                            height: doubleValue(m["h"])
                        ),
                        attributes: (m["attrs"] as? String) ?? "",
                        textSnippet: m["text"] as? String
                    )
                }
                throw SafariBrowserError.elementAmbiguous(selector: selector, matches: matches)
            case "index_out_of_range":
                throw SafariBrowserError.elementIndexOutOfRange(
                    selector: selector,
                    index: (obj["index"] as? Int) ?? 0,
                    matchCount: (obj["matchCount"] as? Int) ?? 0
                )
            case "zero_size":
                throw SafariBrowserError.elementZeroSize(selector: selector)
            case "outside_viewport":
                throw SafariBrowserError.elementOutsideViewport(
                    selector: selector,
                    rect: CGRect(
                        x: doubleValue(obj["x"]),
                        y: doubleValue(obj["y"]),
                        width: doubleValue(obj["w"]),
                        height: doubleValue(obj["h"])
                    ),
                    viewport: CGSize(
                        width: doubleValue(obj["iw"]),
                        height: doubleValue(obj["ih"])
                    )
                )
            case "selector_invalid":
                throw SafariBrowserError.elementSelectorInvalid(
                    selector: selector,
                    reason: (obj["reason"] as? String) ?? "invalid selector"
                )
            default:
                throw SafariBrowserError.elementSelectorInvalid(
                    selector: selector,
                    reason: "unknown error kind from JS bridge: \(errorKind)"
                )
            }
        }

        guard let ok = obj["ok"] as? [String: Any] else {
            throw SafariBrowserError.elementSelectorInvalid(
                selector: selector,
                reason: "element bounds response missing both 'ok' and 'error' keys"
            )
        }
        return ElementBoundsResult(
            rectInViewport: CGRect(
                x: doubleValue(ok["x"]),
                y: doubleValue(ok["y"]),
                width: doubleValue(ok["w"]),
                height: doubleValue(ok["h"])
            ),
            viewportSize: CGSize(
                width: doubleValue(ok["iw"]),
                height: doubleValue(ok["ih"])
            ),
            matchCount: (ok["matchCount"] as? Int) ?? 1,
            attributes: (ok["attributes"] as? String) ?? "",
            textSnippet: ok["textSnippet"] as? String
        )
    }

    // MARK: - DOM element resource (#31)

    /// #31: which resource attribute to read for video/audio/img elements.
    /// `currentSrc` is the responsive-image actually-loaded URL and is
    /// the sensible default for most captures. `src` is the raw HTML
    /// attribute (pre-responsive-resolution), occasionally useful. `poster`
    /// is specific to `<video>` / `<audio>` and fetches the poster image.
    enum ResourceTrack: String, Equatable {
        case currentSrc
        case src
        case poster
    }

    /// #31: successful return from `resolveElementResource`.
    /// Either the resolved resource URL (for img/source/picture/video/audio)
    /// or the serialized outerHTML (for inline svg). Caller dispatches
    /// download based on the case.
    enum ElementResource: Equatable {
        /// URL string as resolved by the element (may be `http://`,
        /// `https://`, `data:`, or any other scheme — caller validates).
        case url(String)
        /// Inline SVG `outerHTML` serialized as a UTF-8 string. Caller
        /// writes directly to the output path; no HTTP request needed.
        case inlineSVG(String)
    }

    /// #31: locate a DOM element by CSS selector and return either its
    /// resource URL or its serialized SVG outerHTML.
    ///
    /// Fail-closed semantics (mirrors #30 for multi-match + invalid selector;
    /// adds resource-specific errors):
    ///   - zero matches → `.elementNotFound`
    ///   - multi-match without `elementIndex` → `.elementAmbiguous`
    ///   - `elementIndex` out of range → `.elementIndexOutOfRange`
    ///   - invalid CSS selector (JS `SyntaxError`) → `.elementSelectorInvalid`
    ///   - chosen element has empty src/currentSrc/poster → `.elementHasNoSrc`
    ///   - chosen element's tagName is not in {img, source, picture, video, audio, svg} → `.unsupportedElement`
    ///
    /// Light DOM only — Shadow DOM and iframe traversal are out of scope.
    /// Uses `doJavaScriptLarge` because inline SVG outerHTML can exceed
    /// the normal doJavaScript size limit for complex vector content.
    static func resolveElementResource(
        selector: String,
        target: TargetDocument = .frontWindow,
        track: ResourceTrack = .currentSrc,
        elementIndex: Int? = nil
    ) async throws -> ElementResource {
        // JSON-encode selector to survive injection — same pattern as #30
        guard let data = try? JSONSerialization.data(withJSONObject: [selector]),
              let s = String(data: data, encoding: .utf8),
              s.hasPrefix("["), s.hasSuffix("]") else {
            throw SafariBrowserError.elementSelectorInvalid(
                selector: selector,
                reason: "could not JSON-encode selector for injection"
            )
        }
        let selectorJSON = String(s.dropFirst().dropLast())

        let indexJS: String
        if let idx = elementIndex {
            indexJS = String(idx - 1)
        } else {
            indexJS = "null"
        }

        let trackJS = "\"\(track.rawValue)\""

        let js = """
        JSON.stringify((() => {
          const selector = \(selectorJSON);
          const targetIndex = \(indexJS);
          const track = \(trackJS);
          let nodes;
          try { nodes = document.querySelectorAll(selector); }
          catch (e) { return { error: 'selector_invalid', reason: (e && e.message) || String(e) }; }
          if (nodes.length === 0) return { error: 'not_found' };
          function describe(el) {
            const r = el.getBoundingClientRect();
            let attrs = el.tagName.toLowerCase();
            if (el.id) attrs += '#' + el.id;
            if (el.className && typeof el.className === 'string') {
              const classes = el.className.split(/\\s+/).filter(c => c);
              if (classes.length > 0) attrs += '.' + classes.join('.');
            }
            const txt = (el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 60);
            return { x: r.x, y: r.y, w: r.width, h: r.height, attrs, text: txt || null };
          }
          let chosenIndex;
          if (nodes.length > 1) {
            if (targetIndex === null) return { error: 'ambiguous', matches: Array.from(nodes).map(describe) };
            if (targetIndex < 0 || targetIndex >= nodes.length) return { error: 'index_out_of_range', index: targetIndex + 1, matchCount: nodes.length };
            chosenIndex = targetIndex;
          } else {
            if (targetIndex !== null && targetIndex !== 0) return { error: 'index_out_of_range', index: targetIndex + 1, matchCount: 1 };
            chosenIndex = 0;
          }
          const el = nodes[chosenIndex];
          const tag = el.tagName.toLowerCase();
          if (tag === 'svg') return { kind: 'inline_svg', data: el.outerHTML };
          const supported = ['img', 'source', 'picture', 'video', 'audio'];
          if (!supported.includes(tag)) return { error: 'unsupported_element', tagName: tag };
          // Empty-attribute detection: el.src / el.currentSrc resolve
          // against document.baseURI so an empty src attribute returns
          // the page URL rather than "". Check the raw attribute first;
          // only fall through to currentSrc/src properties when the
          // attribute has non-empty content.
          let src;
          if (track === 'poster' && (tag === 'video' || tag === 'audio')) {
            const posterAttr = el.getAttribute('poster') || '';
            src = posterAttr ? el.poster : '';
          } else if (track === 'src') {
            const srcAttr = el.getAttribute('src') || '';
            src = srcAttr ? el.src : '';
          } else {
            // currentSrc (default): prefer the computed currentSrc for
            // responsive images, but only if the element declares some
            // form of source (src attribute OR srcset attribute). An
            // element with neither attribute has no real source.
            const hasDeclaredSrc = (el.getAttribute('src') || '').length > 0
              || (el.getAttribute('srcset') || '').length > 0;
            src = hasDeclaredSrc ? (el.currentSrc || el.src) : '';
          }
          if (!src) return { error: 'has_no_src', tagName: tag };
          return { kind: 'url', src: src };
        })())
        """

        // Most responses are small (<1KB for url kind, ~few KB for
        // typical inline SVG). Use plain doJavaScript which is well-
        // tested with multi-line JS. For pathologically large inline
        // SVG (megabyte-plus) the bridge may truncate — if that ever
        // happens, we can switch that specific code path to
        // doJavaScriptLarge. Keep the simple path until it breaks.
        let jsonString = try await doJavaScript(js, target: target)
        return try parseElementResourceResponse(jsonString, selector: selector)
    }

    /// Internal: parse the JSON response from `resolveElementResource`
    /// JS into either a success `ElementResource` or a thrown
    /// `SafariBrowserError`. Extracted as a pure function so tests can
    /// exercise the parse / error-mapping logic without a live Safari.
    static func parseElementResourceResponse(
        _ jsonString: String,
        selector: String
    ) throws -> ElementResource {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SafariBrowserError.elementSelectorInvalid(
                selector: selector,
                reason: "could not parse element resource response as JSON"
            )
        }

        if let errorKind = obj["error"] as? String {
            switch errorKind {
            case "not_found":
                throw SafariBrowserError.elementNotFound(selector)
            case "ambiguous":
                let rawMatches = (obj["matches"] as? [[String: Any]]) ?? []
                let matches = rawMatches.map { m in
                    ElementMatch(
                        rect: CGRect(
                            x: doubleValue(m["x"]),
                            y: doubleValue(m["y"]),
                            width: doubleValue(m["w"]),
                            height: doubleValue(m["h"])
                        ),
                        attributes: (m["attrs"] as? String) ?? "",
                        textSnippet: m["text"] as? String
                    )
                }
                throw SafariBrowserError.elementAmbiguous(selector: selector, matches: matches)
            case "index_out_of_range":
                throw SafariBrowserError.elementIndexOutOfRange(
                    selector: selector,
                    index: (obj["index"] as? Int) ?? 0,
                    matchCount: (obj["matchCount"] as? Int) ?? 0
                )
            case "selector_invalid":
                throw SafariBrowserError.elementSelectorInvalid(
                    selector: selector,
                    reason: (obj["reason"] as? String) ?? "invalid selector"
                )
            case "has_no_src":
                throw SafariBrowserError.elementHasNoSrc(
                    selector: selector,
                    tagName: (obj["tagName"] as? String) ?? "unknown"
                )
            case "unsupported_element":
                throw SafariBrowserError.unsupportedElement(
                    selector: selector,
                    tagName: (obj["tagName"] as? String) ?? "unknown"
                )
            default:
                throw SafariBrowserError.elementSelectorInvalid(
                    selector: selector,
                    reason: "unknown error kind from JS bridge: \(errorKind)"
                )
            }
        }

        guard let kind = obj["kind"] as? String else {
            throw SafariBrowserError.elementSelectorInvalid(
                selector: selector,
                reason: "element resource response missing both 'kind' and 'error' keys"
            )
        }

        switch kind {
        case "url":
            guard let src = obj["src"] as? String, !src.isEmpty else {
                throw SafariBrowserError.elementSelectorInvalid(
                    selector: selector,
                    reason: "url kind without valid src"
                )
            }
            return .url(src)
        case "inline_svg":
            guard let svgData = obj["data"] as? String else {
                throw SafariBrowserError.elementSelectorInvalid(
                    selector: selector,
                    reason: "inline_svg kind without data"
                )
            }
            return .inlineSVG(svgData)
        default:
            throw SafariBrowserError.elementSelectorInvalid(
                selector: selector,
                reason: "unknown kind from JS bridge: \(kind)"
            )
        }
    }

    /// #31: fetch a resource URL through Safari's own `fetch()` API so
    /// the request inherits the document's cookies, credentials, and
    /// session. Used by `save-image --with-cookies` for authenticated
    /// resources that URLSession cannot access (no cookie jar).
    ///
    /// Pipeline:
    ///   1. JS start: async fetch → blob → FileReader.readAsDataURL →
    ///      writes to `window.__sbResource`, sets `__sbResourceDone=true`
    ///   2. Swift poll: 100ms intervals until `__sbResourceDone` is true
    ///      (timeout at `timeoutSeconds`)
    ///   3. Swift size check: `__sbResourceActualBytes` vs hard cap;
    ///      throw `downloadSizeCapExceeded` if over
    ///   4. Swift chunked read: 256KB substring slices of `__sbResource`
    ///      (V8-safe; inverse of `upload --js`'s chunked write from #24)
    ///   5. Swift parse: split data URL on first comma, base64 decode
    ///
    /// Size cap enforced in JS before FileReader runs: `Content-Length`
    /// header checked first, then `blob.size` as fallback. Avoids
    /// loading 100 MB into Safari memory just to reject.
    ///
    /// - Parameters:
    ///   - url: resource URL; will be fetched with `credentials: 'include'`
    ///   - target: document to evaluate fetch from (cookie scope)
    ///   - sizeHardCapBytes: bytes above which `downloadSizeCapExceeded`
    ///     throws (default 10 MB, matches `upload --js` #24 safety)
    ///   - sizeSoftWarnBytes: stderr warning threshold (default 5 MB)
    ///   - timeoutSeconds: max wait for the async fetch to complete
    static func fetchResourceWithCookies(
        url: String,
        target: TargetDocument = .frontWindow,
        sizeHardCapBytes: Int = 10 * 1_048_576,
        sizeSoftWarnBytes: Int = 5 * 1_048_576,
        timeoutSeconds: Double = 30.0
    ) async throws -> Data {
        // JSON-encode URL to survive injection
        guard let urlJSONData = try? JSONSerialization.data(withJSONObject: [url]),
              let urlJSONFull = String(data: urlJSONData, encoding: .utf8),
              urlJSONFull.hasPrefix("["), urlJSONFull.hasSuffix("]") else {
            throw SafariBrowserError.downloadFailed(
                url: url, statusCode: nil, reason: "could not JSON-encode URL for JS fetch"
            )
        }
        let urlJS = String(urlJSONFull.dropFirst().dropLast())

        // Kick off async fetch. JS size check happens inside the promise
        // chain so we never read a >10 MB blob through the bridge.
        let startJS = """
        (function(){
          const HARD_CAP = \(sizeHardCapBytes);
          window.__sbResource = null;
          window.__sbResourceLen = 0;
          window.__sbResourceActualBytes = 0;
          window.__sbResourceDone = false;
          window.__sbResourceError = null;
          fetch(\(urlJS), { credentials: 'include' })
            .then(r => {
              if (!r.ok) throw new Error('HTTP:' + r.status);
              const cl = r.headers.get('content-length');
              const parsedCL = cl ? parseInt(cl, 10) : NaN;
              if (!isNaN(parsedCL) && parsedCL > HARD_CAP) {
                window.__sbResourceActualBytes = parsedCL;
                throw new Error('SIZE_CAP');
              }
              return r.blob();
            })
            .then(blob => {
              window.__sbResourceActualBytes = blob.size;
              if (blob.size > HARD_CAP) throw new Error('SIZE_CAP');
              return new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onloadend = () => resolve(reader.result);
                reader.onerror = () => reject(reader.error || new Error('FileReader failed'));
                reader.readAsDataURL(blob);
              });
            })
            .then(dataURL => {
              window.__sbResource = dataURL;
              window.__sbResourceLen = dataURL.length;
              window.__sbResourceDone = true;
            })
            .catch(e => {
              window.__sbResourceError = (e && e.message) || String(e);
              window.__sbResourceDone = true;
            });
        })()
        """
        _ = try await doJavaScript(startJS, target: target)

        // Poll for completion (100ms intervals, bounded by timeoutSeconds)
        let pollIntervalNs: UInt64 = 100_000_000
        let maxIterations = max(Int(timeoutSeconds * 10), 1)
        var iterations = 0
        while iterations < maxIterations {
            let doneStr = try await doJavaScript("window.__sbResourceDone", target: target)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if doneStr == "true" { break }
            try await Task.sleep(nanoseconds: pollIntervalNs)
            iterations += 1
        }
        if iterations >= maxIterations {
            try? await cleanupResourceState(target: target)
            throw SafariBrowserError.downloadFailed(
                url: url, statusCode: nil,
                reason: "fetch did not complete within \(Int(timeoutSeconds)) seconds"
            )
        }

        // Check for JS-side error
        let errorRaw = try await doJavaScript("window.__sbResourceError", target: target)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actualBytesStr = try await doJavaScript("window.__sbResourceActualBytes", target: target)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actualBytes = Int(actualBytesStr) ?? 0

        if errorRaw != "undefined" && errorRaw != "null" && !errorRaw.isEmpty {
            try? await cleanupResourceState(target: target)
            // Parse HTTP status from 'HTTP:404' prefix if present
            if errorRaw == "SIZE_CAP" {
                throw SafariBrowserError.downloadSizeCapExceeded(
                    url: url, capBytes: sizeHardCapBytes, actualBytes: actualBytes
                )
            }
            if let range = errorRaw.range(of: "HTTP:"),
               let code = Int(errorRaw[range.upperBound...].prefix(while: { $0.isNumber })) {
                throw SafariBrowserError.downloadFailed(url: url, statusCode: code, reason: errorRaw)
            }
            throw SafariBrowserError.downloadFailed(url: url, statusCode: nil, reason: errorRaw)
        }

        // Soft warn if over 5 MB
        if actualBytes > sizeSoftWarnBytes {
            let actualMB = Double(actualBytes) / 1_048_576.0
            FileHandle.standardError.write(Data(
                "⚠️  Resource \(String(format: "%.1f", actualMB)) MB via --with-cookies; JS bridge overhead may be significant\n".utf8
            ))
        }

        // Read the data URL from JS in 256 KB chunks
        let lenStr = try await doJavaScript("window.__sbResourceLen", target: target)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dataURLLen = Int(lenStr), dataURLLen > 0 else {
            try? await cleanupResourceState(target: target)
            throw SafariBrowserError.downloadFailed(
                url: url, statusCode: nil, reason: "empty or malformed data URL response"
            )
        }

        let chunkSize = 262_144
        var dataURL = ""
        dataURL.reserveCapacity(dataURLLen)
        var offset = 0
        while offset < dataURLLen {
            let end = min(offset + chunkSize, dataURLLen)
            let chunk = try await doJavaScript(
                "window.__sbResource.substring(\(offset), \(end))",
                target: target
            )
            dataURL += chunk
            offset = end
        }

        try? await cleanupResourceState(target: target)

        // Parse data URL: data:<mime>;base64,<payload>
        guard let commaRange = dataURL.range(of: ",") else {
            throw SafariBrowserError.downloadFailed(
                url: url, statusCode: nil,
                reason: "malformed data URL (no comma separator between prefix and payload)"
            )
        }
        let payload = String(dataURL[commaRange.upperBound...])
        guard let decoded = Data(base64Encoded: payload) else {
            throw SafariBrowserError.downloadFailed(
                url: url, statusCode: nil,
                reason: "could not base64-decode fetched data URL payload"
            )
        }
        return decoded
    }

    /// #31: clean up `window.__sbResource*` globals after a
    /// `fetchResourceWithCookies` completes (success, error, or timeout).
    /// Best-effort — a failed cleanup does not block the outer call.
    private static func cleanupResourceState(target: TargetDocument) async throws {
        _ = try await doJavaScript(
            "delete window.__sbResource; delete window.__sbResourceLen; delete window.__sbResourceActualBytes; delete window.__sbResourceDone; delete window.__sbResourceError",
            target: target
        )
    }

    /// NSNumber-safe double extraction — JSONSerialization returns
    /// numeric values as NSNumber which may lose precision if cast
    /// directly to Double for integer representations.
    private static func doubleValue(_ any: Any?) -> Double {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return 0
    }

    // MARK: - JavaScript

    static func doJavaScript(
        _ code: String,
        target: TargetDocument = .frontWindow,
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) async throws -> String {
        let docRef = try await resolveToAppleScript(
            target,
            firstMatch: firstMatch,
            warnWriter: warnWriter
        )
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
        target: TargetDocument = .frontWindow,
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) async throws -> String {
        // Store result in window variable. Only the first doJavaScript
        // call forwards the warnWriter — subsequent chunked reads reuse
        // the already-resolved tab, so re-emitting the multi-match
        // warning each chunk would spam the caller.
        _ = try await doJavaScript(
            "(function(){ window.__sbResult = '' + (\(code)); window.__sbResultLen = window.__sbResult.length; })()",
            target: target,
            firstMatch: firstMatch,
            warnWriter: warnWriter
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
    static func getCurrentURL(
        target: TargetDocument = .frontWindow,
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) async throws -> String {
        let docRef = try await resolveToAppleScript(
            target,
            firstMatch: firstMatch,
            warnWriter: warnWriter
        )
        return try await runTargetedAppleScript("""
            tell application "Safari"
                get URL of \(docRef)
            end tell
            """, target: target)
    }

    /// Read the title of the target document. Document-scoped for modal bypass (#21).
    static func getCurrentTitle(
        target: TargetDocument = .frontWindow,
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) async throws -> String {
        let docRef = try await resolveToAppleScript(
            target,
            firstMatch: firstMatch,
            warnWriter: warnWriter
        )
        return try await runTargetedAppleScript("""
            tell application "Safari"
                get name of \(docRef)
            end tell
            """, target: target)
    }

    /// Read the plain-text content of the target document. Document-scoped for modal bypass (#21).
    static func getCurrentText(
        target: TargetDocument = .frontWindow,
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) async throws -> String {
        let docRef = try await resolveToAppleScript(
            target,
            firstMatch: firstMatch,
            warnWriter: warnWriter
        )
        return try await runTargetedAppleScript("""
            tell application "Safari"
                get text of \(docRef)
            end tell
            """, target: target)
    }

    /// Read the HTML source of the target document. Document-scoped for modal bypass (#21).
    static func getCurrentSource(
        target: TargetDocument = .frontWindow,
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) async throws -> String {
        let docRef = try await resolveToAppleScript(
            target,
            firstMatch: firstMatch,
            warnWriter: warnWriter
        )
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

    /// Metadata for a Safari tab, used by `listAllDocuments()` and
    /// `DocumentsCommand` to surface targeting candidates for `--url`,
    /// `--window + --tab-in-window`, and `--document`. Tab-level source
    /// of truth per the `human-emulation` principle (tab bar is ground
    /// truth — every tab in every window is individually addressable).
    ///
    /// - `index`: 1-based global counter across all windows in (window,
    ///   tab-in-window) enumeration order. Accepted by `--document N`.
    /// - `window`: AppleScript `window N` index (1-based).
    /// - `tabInWindow`: AppleScript `tab T of window N` index (1-based).
    ///   Accepted by `--window N --tab-in-window M`.
    /// - `isCurrent`: true when this tab is the current (frontmost) tab
    ///   of its window.
    struct DocumentInfo: Sendable {
        let index: Int
        let window: Int
        let tabInWindow: Int
        let title: String
        let url: String
        let isCurrent: Bool
    }

    /// Flatten a `[WindowInfo]` enumeration into `[DocumentInfo]` with
    /// stable global indices. Pure function — unit-testable without
    /// Safari. Respects window-then-tab ordering: window 1's tabs come
    /// before window 2's tabs. Global `index` is a 1-based counter over
    /// the flattened sequence.
    static func flattenWindowsToDocuments(_ windows: [WindowInfo]) -> [DocumentInfo] {
        var docs: [DocumentInfo] = []
        var globalIndex = 1
        for window in windows {
            for tab in window.tabs {
                docs.append(DocumentInfo(
                    index: globalIndex,
                    window: window.windowIndex,
                    tabInWindow: tab.tabIndex,
                    title: tab.title,
                    url: tab.url,
                    isCurrent: tab.isCurrent
                ))
                globalIndex += 1
            }
        }
        return docs
    }

    /// List every Safari tab across all windows. Ordering is stable:
    /// windows by ascending index, tabs within a window by ascending
    /// tab-in-window index. Backed by `listAllWindows` so that
    /// enumeration is consistent with the native-path resolver (per the
    /// `human-emulation` ground-truth requirement — `documents`
    /// subcommand and `upload --native` see the same universe of tabs).
    static func listAllDocuments() async throws -> [DocumentInfo] {
        let windows = try await listAllWindows()
        return flattenWindowsToDocuments(windows)
    }

    // MARK: - Native Path Resolver (#26)

    /// A tab within a window. Used only by `listAllWindows` /
    /// `pickNativeTarget` — distinct from the public `TabInfo` so the
    /// native-path resolver owns its own shape and `isCurrent` flag.
    struct TabInWindow: Sendable, Equatable {
        let tabIndex: Int
        let url: String
        let title: String
        let isCurrent: Bool
    }

    /// All tabs of a single Safari window, with the current-tab pointer
    /// already resolved. Produced by `listAllWindows` and consumed by
    /// `pickNativeTarget`.
    struct WindowInfo: Sendable, Equatable {
        let windowIndex: Int
        let currentTabIndex: Int
        let tabs: [TabInWindow]
    }

    /// Output of the native-path resolver. `windowIndex` is the Safari
    /// AppleScript `window N` index. `tabIndexInWindow` is `nil` when no
    /// tab switch is needed — either the target is already the current
    /// tab, or the target request didn't specify a tab (`.frontWindow` /
    /// `.windowIndex`). Native commands call `performTabSwitchIfNeeded`
    /// with both fields before raising / keystroking.
    struct ResolvedWindowTarget: Sendable, Equatable {
        let windowIndex: Int
        let tabIndexInWindow: Int?
    }

    /// Pure resolver core. Maps a `TargetDocument` to a concrete
    /// `ResolvedWindowTarget` given a pre-enumerated list of Safari
    /// windows. All AppleScript I/O happens in `listAllWindows`; this
    /// function is fully unit-testable without a live Safari
    /// (WindowIndexResolverTests).
    ///
    /// Fail-closed on ambiguity: `.urlContains` matches > 1 window throw
    /// `ambiguousWindowMatch` rather than silently picking one (#26
    /// design decision: Multi-match fail-closed with `ambiguousWindowMatch`
    /// error — deterministic behavior is worth more to automation than
    /// convenience of first-match).
    ///
    /// - Throws: `SafariBrowserError.documentNotFound` for zero matches
    ///   or out-of-range index. `SafariBrowserError.ambiguousWindowMatch`
    ///   for multi-match URL patterns.
    static func pickNativeTarget(
        _ target: TargetDocument,
        in windows: [WindowInfo]
    ) throws -> ResolvedWindowTarget {
        switch target {
        case .frontWindow:
            // Trivial case — skipped by the async orchestrator anyway,
            // but covered here so the pure function is total over all
            // TargetDocument cases.
            return ResolvedWindowTarget(windowIndex: 1, tabIndexInWindow: nil)

        case .windowIndex(let n):
            if n < 1 || n > windows.count {
                let availableSummary = windows.map { w -> String in
                    let cur = w.tabs.first(where: { $0.isCurrent })?.url ?? "(unknown)"
                    return "window \(w.windowIndex): \(cur)"
                }
                throw SafariBrowserError.documentNotFound(
                    pattern: "window \(n)",
                    availableDocuments: availableSummary
                )
            }
            return ResolvedWindowTarget(windowIndex: n, tabIndexInWindow: nil)

        case .documentIndex(let n):
            // Guard against .documentIndex(0) / negative — would land on
            // tabs[-1] once `remaining <= window.tabs.count` was trivially
            // true. `TargetOptions.validate()` already rejects <= 0 at the
            // CLI layer, but this function is a public pure entry point
            // that tests and future callers can exercise directly, so
            // surface a clean `documentNotFound` here rather than
            // trapping.
            if n < 1 {
                throw SafariBrowserError.documentNotFound(
                    pattern: "document \(n)",
                    availableDocuments: windows.flatMap { w in
                        w.tabs.map { "window \(w.windowIndex) tab \($0.tabIndex): \($0.url)" }
                    }
                )
            }
            // Map flat document index → (window, tab in window) by
            // walking windows in index order and counting tabs. We treat
            // `--document N` as "the N-th tab across all windows in
            // spatial/window-index order", which is more predictable
            // for automation than Safari's MRU-ordered document
            // collection. For users who need Safari's exact document-
            // index semantics, the JS path (document-scoped AppleScript
            // via TargetOptions.resolve) retains the original behavior.
            var remaining = n
            for window in windows {
                if remaining <= window.tabs.count {
                    let tab = window.tabs[remaining - 1]
                    return ResolvedWindowTarget(
                        windowIndex: window.windowIndex,
                        tabIndexInWindow: tab.isCurrent ? nil : tab.tabIndex
                    )
                }
                remaining -= window.tabs.count
            }
            let totalTabs = windows.reduce(0) { $0 + $1.tabs.count }
            let availableSummary = windows.map { w -> String in
                let cur = w.tabs.first(where: { $0.isCurrent })?.url ?? "(unknown)"
                return "window \(w.windowIndex): \(cur) (\(w.tabs.count) tab(s))"
            }
            throw SafariBrowserError.documentNotFound(
                pattern: "document \(n) (only \(totalTabs) tab(s) available)",
                availableDocuments: availableSummary
            )

        case .urlMatch(let matcher):
            var matches: [(windowIndex: Int, tabIndex: Int, url: String, isCurrent: Bool)] = []
            for window in windows {
                for tab in window.tabs where matcher.matches(tab.url) {
                    matches.append((
                        windowIndex: window.windowIndex,
                        tabIndex: tab.tabIndex,
                        url: tab.url,
                        isCurrent: tab.isCurrent
                    ))
                }
            }

            if matches.isEmpty {
                let allUrls = windows.flatMap { w in
                    w.tabs.map { "window \(w.windowIndex) tab \($0.tabIndex): \($0.url)" }
                }
                throw SafariBrowserError.documentNotFound(
                    pattern: matcher.description,
                    availableDocuments: allUrls
                )
            }

            if matches.count > 1 {
                throw SafariBrowserError.ambiguousWindowMatch(
                    pattern: matcher.description,
                    matches: matches.map { (windowIndex: $0.windowIndex, url: $0.url) }
                )
            }

            let match = matches[0]
            return ResolvedWindowTarget(
                windowIndex: match.windowIndex,
                tabIndexInWindow: match.isCurrent ? nil : match.tabIndex
            )

        case .windowTab(let w, let t):
            // Composite (window, tab-in-window) — same-URL escape hatch
            // (issue #28 gap #2). TargetOptions.validate() rejects
            // solo --tab-in-window and non-positive indices at the CLI,
            // but this pure function is a public entry point so it
            // still defends against bad inputs.
            if w < 1 || w > windows.count {
                let availableSummary = windows.map { win -> String in
                    let cur = win.tabs.first(where: { $0.isCurrent })?.url ?? "(unknown)"
                    return "window \(win.windowIndex): \(cur)"
                }
                throw SafariBrowserError.documentNotFound(
                    pattern: "window \(w) tab \(t)",
                    availableDocuments: availableSummary
                )
            }
            let window = windows[w - 1]
            if t < 1 || t > window.tabs.count {
                let availableSummary = window.tabs.map { tab in
                    "window \(window.windowIndex) tab \(tab.tabIndex): \(tab.url)"
                }
                throw SafariBrowserError.documentNotFound(
                    pattern: "window \(w) tab \(t) (window has \(window.tabs.count) tab(s))",
                    availableDocuments: availableSummary
                )
            }
            let tab = window.tabs[t - 1]
            return ResolvedWindowTarget(
                windowIndex: w,
                tabIndexInWindow: tab.isCurrent ? nil : t
            )
        }
    }

    /// Async orchestrator. Resolves `.frontWindow` / `.windowIndex`
    /// synchronously without touching AppleScript; falls through to a
    /// single `listAllWindows` enumeration for `.urlContains` /
    /// `.documentIndex`.
    ///
    /// Stateless — no caching between calls (#26 design decision:
    /// Stateless resolver — no cache). Safari's window state may change
    /// between invocations, and the AppleScript enumeration cost is
    /// dominated by roundtrip fixed overhead, not work, so caching
    /// trades very little for a real correctness risk.
    static func resolveNativeTarget(
        from target: TargetDocument,
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) async throws -> ResolvedWindowTarget {
        switch target {
        case .frontWindow:
            return ResolvedWindowTarget(windowIndex: 1, tabIndexInWindow: nil)
        case .windowIndex(let n):
            return ResolvedWindowTarget(windowIndex: n, tabIndexInWindow: nil)
        case .urlMatch, .documentIndex, .windowTab:
            let windows = try await listAllWindows()
            return try resolveNativeTargetInWindows(
                target,
                windows: windows,
                firstMatch: firstMatch,
                warnWriter: warnWriter
            )
        }
    }

    /// Pure extraction of the post-enumeration branch in
    /// `resolveNativeTarget`. Exposed so tests can exercise the
    /// `pickNativeTarget` + `pickFirstMatchFallback` dispatch on a
    /// stubbed `[WindowInfo]` without touching AppleScript. Real code
    /// should call `resolveNativeTarget`; this helper exists for the
    /// `url-matching-pipeline` plumbing integration test.
    static func resolveNativeTargetInWindows(
        _ target: TargetDocument,
        windows: [WindowInfo],
        firstMatch: Bool = false,
        warnWriter: ((String) -> Void)? = nil
    ) throws -> ResolvedWindowTarget {
        do {
            return try pickNativeTarget(target, in: windows)
        } catch let error as SafariBrowserError {
            // --first-match opt-in: recover from ambiguousWindowMatch
            // on `.urlMatch` by selecting the first match in
            // (window, tab) order, emitting a stderr warning that
            // lists all candidates. Only urlMatch supports this
            // fallback — documentIndex / windowTab ambiguity is a
            // structural bug, not user-chosen disambiguation.
            if firstMatch,
               case .urlMatch(let matcher) = target,
               case .ambiguousWindowMatch = error {
                return try pickFirstMatchFallback(
                    matcher: matcher,
                    in: windows,
                    warnWriter: warnWriter
                )
            }
            throw error
        }
    }

    /// First-match opt-in helper. Scans windows in (windowIndex,
    /// tabIndex) order, returns the first tab whose URL satisfies
    /// `matcher`. When more than one match exists, emits a stderr
    /// warning via `warnWriter` listing every candidate so the user
    /// can audit which tab was chosen. Pure — the warning emission is
    /// injected so tests can capture without touching stderr.
    static func pickFirstMatchFallback(
        matcher: UrlMatcher,
        in windows: [WindowInfo],
        warnWriter: ((String) -> Void)? = nil
    ) throws -> ResolvedWindowTarget {
        var matches: [(windowIndex: Int, tab: TabInWindow)] = []
        for window in windows {
            for tab in window.tabs where matcher.matches(tab.url) {
                matches.append((window.windowIndex, tab))
            }
        }
        guard let first = matches.first else {
            let allUrls = windows.flatMap { w in
                w.tabs.map { "window \(w.windowIndex) tab \($0.tabIndex): \($0.url)" }
            }
            throw SafariBrowserError.documentNotFound(
                pattern: matcher.description,
                availableDocuments: allUrls
            )
        }
        if matches.count > 1 {
            let summary = matches.map { m in
                "  window \(m.windowIndex) tab \(m.tab.tabIndex): \(m.tab.url)"
            }.joined(separator: "\n")
            let msg = "warning: --first-match resolved '\(matcher.description)' to "
                + "window \(first.windowIndex) tab \(first.tab.tabIndex) "
                + "(of \(matches.count) matches):\n\(summary)\n"
            warnWriter?(msg)
        }
        return ResolvedWindowTarget(
            windowIndex: first.windowIndex,
            tabIndexInWindow: first.tab.isCurrent ? nil : first.tab.tabIndex
        )
    }

    /// Enumerate every Safari window with its tabs in a single
    /// AppleScript roundtrip. URLs are emitted between ASCII group
    /// separators (GS, U+001D) and records terminated with the ASCII
    /// record separator (RS, U+001E). These bytes do not appear in
    /// percent-encoded URLs, so the parser needs no escape handling.
    ///
    /// Performance: O(1) AppleScript roundtrips regardless of window /
    /// tab count, vs. the naive per-tab query approach which would
    /// dominate upload latency (10 windows × 5 tabs ≈ 70 roundtrips).
    static func listAllWindows() async throws -> [WindowInfo] {
        let script = """
            tell application "Safari"
                set windowCount to count of windows
                if windowCount = 0 then
                    return ""
                end if
                set output to ""
                set GS to (character id 29)
                set RS to (character id 30)
                repeat with w from 1 to windowCount
                    set currentIdx to index of current tab of window w
                    set tabCount to count of tabs of window w
                    repeat with t from 1 to tabCount
                        set tabUrl to URL of tab t of window w
                        if tabUrl is missing value then set tabUrl to ""
                        set tabName to name of tab t of window w
                        if tabName is missing value then set tabName to ""
                        if t = currentIdx then
                            set isCur to "1"
                        else
                            set isCur to "0"
                        end if
                        set output to output & w & GS & t & GS & isCur & GS & tabUrl & GS & tabName & RS
                    end repeat
                end repeat
                return output
            end tell
            """
        let raw = try await runAppleScript(script)
        return parseWindowEnumeration(raw)
    }

    /// Parse the `listAllWindows` output format. Exposed for unit
    /// testing the parser independently of Safari. Record layout (5
    /// fields separated by GS, terminated by RS):
    /// `window_idx GS tab_idx GS is_current GS url GS title RS`
    ///
    /// Backward compatibility: if a record only has 4 fields (legacy
    /// pre-title format), the title defaults to empty string so tests
    /// and callers that don't care about title still work.
    static func parseWindowEnumeration(_ raw: String) -> [WindowInfo] {
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        var byWindow: [Int: [TabInWindow]] = [:]
        var currentTabByWindow: [Int: Int] = [:]

        for record in trimmed.components(separatedBy: rs) where !record.isEmpty {
            let fields = record.components(separatedBy: gs)
            guard fields.count >= 4,
                  let winIdx = Int(fields[0]),
                  let tabIdx = Int(fields[1]) else {
                continue
            }
            let isCurrent = fields[2] == "1"
            let url = fields[3]
            let title = fields.count >= 5 ? fields[4] : ""
            byWindow[winIdx, default: []].append(TabInWindow(
                tabIndex: tabIdx,
                url: url,
                title: title,
                isCurrent: isCurrent
            ))
            if isCurrent {
                currentTabByWindow[winIdx] = tabIdx
            }
        }

        return byWindow.keys.sorted().map { w in
            let tabs = (byWindow[w] ?? []).sorted(by: { $0.tabIndex < $1.tabIndex })
            return WindowInfo(
                windowIndex: w,
                currentTabIndex: currentTabByWindow[w] ?? 1,
                tabs: tabs
            )
        }
    }

    /// Switch window N's current tab to tab T if T is non-nil and
    /// different from the current tab. Called by native-path commands
    /// after `resolveNativeTarget` identifies a target tab. The tab
    /// switch is classified as a passively interfering side effect
    /// transitively authorized by `--native` / `--allow-hid` (#26
    /// non-interference spec delta).
    static func performTabSwitchIfNeeded(window: Int, tab: Int?) async throws {
        guard let tab = tab else { return }
        try await runAppleScript("""
            tell application "Safari"
                set current tab of window \(window) to tab \(tab) of window \(window)
            end tell
            """)
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
    /// window, plus the optional `AXUIElement` handle for downstream AX
    /// operations (bounds read/write for `screenshot --full`).
    ///
    /// **R7 architecture (#23 verify R6 → R7 C)**: both the `--window N`
    /// path and the default (no flag) path use AX when Accessibility is
    /// granted. Without Accessibility, the default path falls back to
    /// the legacy CG name-match resolver; `--window N` errors with
    /// `accessibilityNotGranted` (no safe legacy for targeted case).
    ///
    /// AX-based resolution eliminates the R1-R5 silent-wrong-window
    /// failure modes (bounds collision, title drift, raise races,
    /// cross-Space filter gaps) on BOTH paths when AX is available.
    ///
    /// Returns a tuple so `ScreenshotCommand --full` can use AX bounds
    /// ops on the same window it's about to capture — eliminating the
    /// R6 F42 cross-API window mismatch (resize AS `window N` while
    /// capturing AX's different CG ID). The axWindow is nil only when
    /// the legacy front-window fallback path is taken (no Accessibility
    /// + no explicit `--window`).
    static func resolveWindowForCapture(window: Int? = nil) async throws -> (cgID: String, axWindow: AXUIElement?) {
        if let window {
            return try await getWindowIDViaAX(windowIndex: window)
        }
        // Default path (no --window): prefer AX if granted, else legacy.
        if AXIsProcessTrusted() {
            return try getFrontWindowIDViaAX()
        }
        return (try getFrontWindowID(), nil)
    }


    /// #23 verify R6→R7: AXUIElement SPI resolver for `--window N`.
    /// Returns both the CG window ID and the AX element handle so
    /// callers can do downstream AX operations (bounds read/write).
    ///
    /// **R7 fail-closed** (#23 verify R6 F41 + Codex P1): when bounds
    /// match against AX windows fails, the function throws
    /// `noSafariWindow` instead of silently falling back to "guess by
    /// AX-index = AS-index". The earlier fallback was susceptible to
    /// AS↔AX ordering drift and re-introduced the R5 silent-wrong-
    /// window class. R7 is strict: either bounds prove identity, or
    /// the call fails loudly.
    ///
    /// **R7 AX messaging timeout** (#23 verify R6 Codex P2): explicitly
    /// caps per-call AX messaging at 2 seconds (default is 6s). With
    /// up to ~10 AX calls per resolution, this bounds total hang at
    /// ~20s for pathological Safari states.
    private static func getWindowIDViaAX(windowIndex: Int) async throws -> (cgID: String, axWindow: AXUIElement?) {
        guard AXIsProcessTrusted() else {
            throw SafariBrowserError.accessibilityNotGranted
        }

        // Validate window N exists. Routes through runTargetedAppleScript so
        // a bad `--window 99` surfaces `documentNotFound` with available-docs.
        _ = try await runTargetedAppleScript("""
            tell application "Safari"
                set t to current tab of window \(windowIndex)
            end tell
            """, target: .windowIndex(windowIndex))

        // Read bounds of window N (AS). Used to match against AX windows below.
        let asBoundsRaw = try await runAppleScript("""
            tell application "Safari"
                set b to bounds of window \(windowIndex)
                return ((item 1 of b) as string) & "," & ((item 2 of b) as string) & "," & ((item 3 of b) as string) & "," & ((item 4 of b) as string)
            end tell
            """)
        let parts = asBoundsRaw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else {
            throw SafariBrowserError.noSafariWindow
        }
        let asX = parts[0], asY = parts[1], asW = parts[2] - parts[0], asH = parts[3] - parts[1]

        // Resolve Safari's AX application.
        let axApp = try safariAXApplication()

        // Enumerate AX windows.
        var windowsValue: CFTypeRef?
        let windowsErr = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)
        guard windowsErr == .success, let axWindows = windowsValue as? [AXUIElement], !axWindows.isEmpty else {
            throw SafariBrowserError.noSafariWindow
        }

        // Collect (axWindow, bounds, cgID) for every AX window.
        let candidates: [(ax: AXUIElement, x: Double, y: Double, w: Double, h: Double, cgID: CGWindowID)] =
            axWindows.compactMap { axWin in
                guard let (px, py) = axPoint(axWin, attribute: kAXPositionAttribute as CFString),
                      let (sw, sh) = axSize(axWin, attribute: kAXSizeAttribute as CFString) else {
                    return nil
                }
                var cgID: CGWindowID = 0
                let err = _AXUIElementGetWindow(axWin, &cgID)
                guard err == .success, cgID != 0 else { return nil }
                return (axWin, px, py, sw, sh, cgID)
            }

        if candidates.isEmpty {
            throw SafariBrowserError.noSafariWindow
        }

        let tolerance = 1.0
        let boundsMatches = candidates.filter {
            abs($0.x - asX) <= tolerance && abs($0.y - asY) <= tolerance &&
            abs($0.w - asW) <= tolerance && abs($0.h - asH) <= tolerance
        }

        // Single bounds match → unambiguous.
        if boundsMatches.count == 1 {
            return (String(boundsMatches[0].cgID), boundsMatches[0].ax)
        }

        // R8 strict fail-closed (#23 verify R7 F53 + DA + Codex):
        // Multiple bounds matches means several Safari windows share
        // identical bounds (e.g., maximized). R7 tried to break the tie
        // by looking for `axWindows[windowIndex - 1]` in the match set —
        // but that silently assumes AS-index = AX-index, which DA and
        // Codex showed could return wrong window under ordering drift.
        // R8 removes the tiebreak entirely and throws a specific
        // `windowIdentityAmbiguous` error so the user knows the failure
        // mode and can work around (rearrange windows or use document-
        // scoped commands).
        if boundsMatches.count > 1 {
            throw SafariBrowserError.windowIdentityAmbiguous(
                reason: "\(boundsMatches.count) Safari windows share bounds {\(asX),\(asY),\(asX + asW),\(asY + asH)}"
            )
        }

        // Zero bounds match → AS and AX disagree. Fail loudly.
        throw SafariBrowserError.noSafariWindow
    }

    /// #23 verify R7→R9: AX-based front-window resolver with strict
    /// fail-closed semantics on the fallback path.
    ///
    /// Algorithm:
    ///   1. Try `kAXMainWindowAttribute` + filter (reject minimized,
    ///      zero-size) → return if valid
    ///   2. Enumerate `kAXWindowsAttribute`, filter each for validity
    ///   3. Zero valid candidates → `noSafariWindow`
    ///   4. Exactly one valid candidate → return it
    ///   5. Multiple valid candidates AND main-window failed to
    ///      resolve → `windowIdentityAmbiguous` (R9 fix for Codex F56)
    ///
    /// The R8 version iterated and returned the FIRST qualifying
    /// window — which assumed `axWindows[0]` is frontmost. That's
    /// established Hammerspoon/yabai/Rectangle convention but NOT
    /// Apple-documented. Codex R8 correctly flagged this as the last
    /// remaining silent heuristic in the `--window N` ecosystem. R9
    /// removes it: when main-window attribute can't disambiguate AND
    /// multiple candidates are visible, throw instead of guess.
    private static func getFrontWindowIDViaAX() throws -> (cgID: String, axWindow: AXUIElement?) {
        guard AXIsProcessTrusted() else {
            throw SafariBrowserError.accessibilityNotGranted
        }
        let axApp = try safariAXApplication()

        // Prefer main window. R9 now validates it passes the
        // non-minimized + non-zero-size filter BEFORE accepting (R8
        // DA F57 was that the mainWindow early return skipped the
        // filter that the fallback applied).
        var mainValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainValue) == .success,
           let mainWin = mainValue,
           CFGetTypeID(mainWin) == AXUIElementGetTypeID() {
            // swiftlint:disable:next force_cast
            let axElement = mainWin as! AXUIElement
            if isValidFrontCandidate(axElement) {
                var cgID: CGWindowID = 0
                if _AXUIElementGetWindow(axElement, &cgID) == .success, cgID != 0 {
                    return (String(cgID), axElement)
                }
            }
        }

        // Fallback: enumerate kAXWindowsAttribute, filter, and require
        // EXACTLY one valid candidate. Multiple visible candidates with
        // mainWindow unavailable means we can't prove which is frontmost
        // — throw ambiguous instead of silently guessing.
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let axWindows = windowsValue as? [AXUIElement], !axWindows.isEmpty else {
            throw SafariBrowserError.noSafariWindow
        }

        let validCandidates = axWindows.filter(isValidFrontCandidate)

        switch validCandidates.count {
        case 0:
            throw SafariBrowserError.noSafariWindow
        case 1:
            let axWin = validCandidates[0]
            var cgID: CGWindowID = 0
            if _AXUIElementGetWindow(axWin, &cgID) == .success, cgID != 0 {
                return (String(cgID), axWin)
            }
            throw SafariBrowserError.noSafariWindow
        default:
            throw SafariBrowserError.windowIdentityAmbiguous(
                reason: "\(validCandidates.count) visible Safari windows exist and no unique frontmost candidate could be identified — cannot pick one without an unverified iteration-order assumption"
            )
        }
    }

    /// Filter helper for `getFrontWindowIDViaAX`: returns true if the
    /// AX window is a viable "front window" candidate — not minimized,
    /// not zero-size. Extracted to a single place so the mainWindow
    /// path and the fallback iteration apply identical validation.
    private static func isValidFrontCandidate(_ axWindow: AXUIElement) -> Bool {
        // Reject minimized windows.
        var minimizedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
           let minimized = minimizedValue as? Bool, minimized {
            return false
        }
        // Reject zero-size / placeholder windows.
        guard let (w, h) = axSize(axWindow, attribute: kAXSizeAttribute as CFString), w > 0, h > 0 else {
            return false
        }
        return true
    }

    /// Find Safari's running process and return its AX application
    /// element, with a 2-second per-call messaging timeout applied.
    /// Throws `noSafariWindow` if Safari is not running.
    private static func safariAXApplication() throws -> AXUIElement {
        guard let safariApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) else {
            throw SafariBrowserError.noSafariWindow
        }
        let axApp = AXUIElementCreateApplication(safariApp.processIdentifier)
        // #23 verify R6 Codex P2: explicit timeout so pathological
        // Safari hangs don't block the CLI for the 6s default per call.
        AXUIElementSetMessagingTimeout(axApp, 2.0)
        return axApp
    }

    /// Map an `AXError` to its Swift case name (e.g. `cannotComplete`,
    /// `attributeUnsupported`). `String(describing: AXError.foo)` does
    /// NOT produce the case name — it produces `"AXError(rawValue: -25204)"`
    /// because `AXError` is a C-bridged struct with `RawRepresentable<Int32>`,
    /// not a Swift enum. R9 commit message wrongly claimed `\(posErr)`
    /// emits the case name; this helper actually does (#23 verify R9 F60).
    private static func axErrorName(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "AXError(rawValue: \(error.rawValue))"
        }
    }

    /// Set `kAXPositionAttribute` and `kAXSizeAttribute` on an AX
    /// window element. Used by `screenshot --full` to resize the
    /// captured window to its full content size (#23 verify R6 F42).
    /// Operating directly on the AX element we resolved avoids the
    /// cross-API window-identity mismatch that plagued R1-R6 when
    /// bounds ops went through AS while captures went through CG.
    ///
    /// **R8 strict error propagation** (#23 verify R7 F54 + DA +
    /// Logic + Security + Codex convergent P1): previously discarded
    /// the AXError return. On fullscreen / minimized / split-view
    /// Safari windows, the AX setter rejects with `.cannotComplete`
    /// and the caller silently proceeds, producing a mis-sized
    /// `screenshot --full` capture. R8 checks both return codes and
    /// throws `axOperationFailed` with a descriptive error message so
    /// the user gets a clear failure instead of a wrong-dimensions
    /// file.
    static func setAXWindowBounds(_ element: AXUIElement, x: Double, y: Double, width: Double, height: Double) throws {
        var position = CGPoint(x: x, y: y)
        var size = CGSize(width: width, height: height)
        guard let posValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw SafariBrowserError.axOperationFailed("AXValueCreate returned nil for CGPoint/CGSize")
        }
        // Position first, then size — setting both in that order is the
        // standard AX pattern (some window servers may ignore size if
        // position is pending).
        let posErr = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        guard posErr == .success else {
            throw SafariBrowserError.axOperationFailed("set kAXPositionAttribute → \(axErrorName(posErr))")
        }
        let sizeErr = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        guard sizeErr == .success else {
            throw SafariBrowserError.axOperationFailed("set kAXSizeAttribute → \(axErrorName(sizeErr))")
        }
    }

    /// Maximum tree depth to search for AXWebArea. Empirically Safari
    /// 15+ places it at depth 6 from the window root:
    ///   Window → SplitGroup → TabGroup → Group → Group → ScrollArea → WebArea
    /// The limit is set to 10 as a buffer for future Safari tree
    /// shape changes and to avoid scanning the entire tree.
    private static let axWebAreaSearchDepthLimit = 10

    /// #29: locate the Safari web content area (the `AXWebArea`
    /// element) inside a window's AX tree and return its bounds in
    /// screen-coordinate points. Used by `screenshot --content-only`
    /// to compute the crop rectangle that excludes Safari chrome.
    ///
    /// The AXWebArea role is a WebKit convention, not a standard AX
    /// role constant — the comparison is against the literal string
    /// `"AXWebArea"` rather than a public `kAX...Role` symbol.
    ///
    /// Search strategy: shallowest-first within the first
    /// `axWebAreaSearchDepthLimit` levels. A depth limit contains
    /// worst-case recursion (malformed trees, deeply nested iframes)
    /// and matches observed Safari tree shape.
    ///
    /// **Sub-frame guard**: a found `AXWebArea` whose y-origin sits
    /// below the midpoint of the owning window is rejected. In normal
    /// Safari layouts chrome occupies <50% of window height; an
    /// AXWebArea origin below the midpoint almost certainly means we
    /// grabbed a sub-frame (iframe) rather than the main viewport,
    /// which would produce a silently wrong crop. Failing closed here
    /// is safer than emitting a wrong-dimensions PNG.
    static func getAXWebAreaBounds(_ axWindow: AXUIElement) throws -> CGRect {
        guard let webArea = findAXWebArea(axWindow, depth: axWebAreaSearchDepthLimit) else {
            throw SafariBrowserError.webAreaNotFound(
                reason: "no AXWebArea within depth \(axWebAreaSearchDepthLimit) of window AX tree"
            )
        }
        guard let (x, y) = axPoint(webArea, attribute: kAXPositionAttribute as CFString),
              let (w, h) = axSize(webArea, attribute: kAXSizeAttribute as CFString) else {
            throw SafariBrowserError.webAreaNotFound(reason: "AXWebArea located but position/size unreadable")
        }

        // Sub-frame guard: the AXWebArea must sit in the upper half of
        // the owning window. If its origin is below the window
        // midpoint, we almost certainly grabbed an iframe.
        if let (_, winY) = axPoint(axWindow, attribute: kAXPositionAttribute as CFString),
           let (_, winH) = axSize(axWindow, attribute: kAXSizeAttribute as CFString) {
            let offsetFromTop = y - winY
            if winH > 0, offsetFromTop > winH / 2 {
                throw SafariBrowserError.webAreaNotFound(
                    reason: "AXWebArea at \(Int(offsetFromTop))pt from window top (> 50% of \(Int(winH))pt height); likely a sub-frame, not the main viewport"
                )
            }
        }

        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Depth-limited search for an `AXWebArea` element. Checks direct
    /// children first (prefer shallowest match), then recurses.
    /// Returns nil when no match exists within the depth limit.
    private static func findAXWebArea(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth <= 0 { return nil }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }
        // Shallowest-first: scan direct children before recursing so
        // the main webArea (usually 2–3 levels deep) wins over any
        // iframe webArea nested deeper.
        for child in children {
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String, role == "AXWebArea" {
                return child
            }
        }
        for child in children {
            if let found = findAXWebArea(child, depth: depth - 1) {
                return found
            }
        }
        return nil
    }

    /// Read the current `kAXPositionAttribute` and `kAXSizeAttribute`
    /// of an AX window element as a single CGRect. Used by
    /// `screenshot --full` to save the original bounds before resizing
    /// for capture, then restore them after.
    static func getAXWindowBounds(_ element: AXUIElement) throws -> CGRect {
        guard let (x, y) = axPoint(element, attribute: kAXPositionAttribute as CFString),
              let (w, h) = axSize(element, attribute: kAXSizeAttribute as CFString) else {
            throw SafariBrowserError.noSafariWindow
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Read an AX point attribute (kAXPositionAttribute) into (x, y).
    /// Returns nil on any failure (missing attribute, wrong type).
    /// R7 hardening (#23 verify R6 logic+security P2): the
    /// `as! AXValue` cast is now gated by an explicit
    /// `CFGetTypeID(value) == AXValueGetTypeID()` check so corrupt AX
    /// state doesn't trap the process — the cast is provably safe.
    private static func axPoint(_ element: AXUIElement, attribute: CFString) -> (Double, Double)? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue  // safe: CFGetTypeID verified
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return (Double(point.x), Double(point.y))
    }

    /// Read an AX size attribute (kAXSizeAttribute) into (width, height).
    private static func axSize(_ element: AXUIElement, attribute: CFString) -> (Double, Double)? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue  // safe: CFGetTypeID verified
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return (Double(size.width), Double(size.height))
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
        // Task 7.1 routing: if daemon mode is opted in AND the daemon is
        // reachable, send the AppleScript source through the
        // `applescript.execute` method so a warm pre-compiled handle
        // serves the request. Any daemon-transport failure falls back
        // silently to the stateless `osascript` subprocess path with a
        // single `[daemon fallback: <reason>]` stderr line.
        try await runViaRouter(
            source: script,
            daemonOptIn: SafariBridge.shouldUseDaemonAuto(),
            daemonFn: { src in
                try await SafariBridge.executeAppleScriptViaDaemon(
                    source: src, timeout: timeout
                )
            },
            statelessFn: { src in
                try await runProcessWithTimeout(
                    "/usr/bin/osascript", ["-e", src], timeout: timeout
                )
            },
            warnWriter: { msg in
                FileHandle.standardError.write(Data(msg.utf8))
            }
        )
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
