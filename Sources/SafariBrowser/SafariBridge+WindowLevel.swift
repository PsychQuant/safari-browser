import Foundation

/// #353: how the window-level commands (`close`, `pdf`, `screenshot`, the native `upload` paths, and `open`
/// when it reveals an existing tab) name the window they resolved in every AppleScript they send afterwards.
///
/// Before this, each of them resolved a target and then acted through `ResolvedWindowTarget.windowIndex`, a
/// position in the window order, so a window raised between two Apple events redirected the later ones. The
/// resolution already carried the window's stable id; these helpers are where it is finally used.
extension SafariBridge {

    /// The window a window-level command acts on, as its scripts name it.
    enum ActingWindow: Sendable, Equatable {
        /// `window id W`: the id the resolution read.
        case id(Int)
        /// `window N`: no targeting flag was given (safari-browser#287), `--window N` stayed a position at
        /// command start (#354's note was written), or the enumeration record carries no id.
        case position(Int)

        var reference: String {
            switch self {
            case .id(let id): return "window id \(id)"
            case .position(let n): return "window \(n)"
            }
        }

        var windowID: Int? {
            if case .id(let id) = self { return id }
            return nil
        }
    }

    /// The one place that decides between the id and the position.
    ///
    /// - `named` is what `TargetOptions.resolve()` returned after `pinWindowAtStart()`.
    /// - A target that is still `.windowIndex` / `.windowTab` means the pin could not read an id: the command
    ///   stays positional for all of its steps, as the note it printed says, even when the resolver's own id
    ///   read answered afterwards.
    /// - No flag and no `--profile` keeps the position, so those scripts are the ones sent before #353.
    static func actingWindow(for resolved: ResolvedWindowTarget, named: TargetDocument, profile: String?) -> ActingWindow {
        let scoped = !(profile ?? "").isEmpty
        switch named {
        case .windowIndex, .windowTab:
            return .position(resolved.windowIndex)
        case .frontWindow where !scoped:
            return .position(resolved.windowIndex)
        default:
            if let id = resolved.windowID, id > 0 { return .id(id) }
            return .position(resolved.windowIndex)
        }
    }

    /// The target later bridge calls and miss wording use for a resolved window-level target.
    ///
    /// A `.windowID` the user typed, or that `pinWindowAtStart` wrote, is kept as it is: its `pinnedFrom` is what
    /// lets a miss say `window 2 (window id 5822 at command start)`.
    static func actedTarget(for resolved: ResolvedWindowTarget, named: TargetDocument, profile: String?) -> TargetDocument {
        switch actingWindow(for: resolved, named: named, profile: profile) {
        case .position(let n):
            if let tab = resolved.anchorTabIndex { return .windowTab(window: n, tabInWindow: tab) }
            return .windowIndex(n)
        case .id(let id):
            if case .windowID = named { return named }
            if let tab = resolved.anchorTabIndex {
                var rematch: UrlMatcher?
                if case .urlMatch(let matcher) = named { rematch = matcher }
                return .resolvedTab(windowID: id, tabInWindow: tab, rematch: rematch, profile: profile)
            }
            return .windowID(id)
        }
    }

    /// The profile a resolution still has to check. `pinWindowAtStart` checked a pinned id against `--profile`
    /// in the one enumeration it made; resolving that id again must not enumerate to check it a second time
    /// (document-targeting, "Window number resolved to its id at command start").
    static func profileStillToCheck(for named: TargetDocument, profile: String?) -> String? {
        if case .windowID(let windowID, _, let pinnedFrom?) = named,
           pinnedFrom.wasChecked(windowID: windowID, against: profile) {
            return nil
        }
        return profile
    }

    /// Resolve the target of a window-level command (#353): `resolveNativeTarget`, without checking a pinned
    /// id against `--profile` a second time, and with a miss worded for the profile all the same.
    ///
    /// A pinned `--window N` under `--profile` resolves through one small query that knows nothing of the
    /// profile. When the window closed since the pin, that query's miss is a bare note; the commands that carry
    /// the profile to their later calls list that profile's tabs instead (document-targeting, "Document not
    /// found surfaces discoverable error", item 8), so the miss is worded again here with the profile.
    static func resolveWindowLevelTarget(
        named: TargetDocument,
        firstMatch: Bool,
        warnWriter: ((String) -> Void)?,
        profile: String?
    ) async throws -> ResolvedWindowTarget {
        let stillToCheck = profileStillToCheck(for: named, profile: profile)
        do {
            return try await resolveNativeTarget(
                from: named, firstMatch: firstMatch, warnWriter: warnWriter, profile: stillToCheck)
        } catch SafariBrowserError.documentNotFound where stillToCheck == nil && !(profile ?? "").isEmpty {
            throw try await notFoundError(for: named, profile: profile)
        }
    }

    // MARK: - The URL check before acting

    /// How many characters of a URL the `--url-regex` check compares. A `data:` URL can be megabytes long, and
    /// the script that carries it is one `osascript` argument.
    static let tabGuardURLPrefixLength = 2_000

    /// AppleScript lines that stop a script, before it acts on the tab bound to `_t`, when that tab is no longer
    /// the one the resolution matched. `nil` when the tab was not found by its URL: a tab named by its position
    /// (`--tab`, `--document`, `--tab-in-window`) has nothing to compare.
    ///
    /// `--url`, `--url-exact` and `--url-endswith` reuse #79's clause: the tab still satisfies the flag.
    /// AppleScript has no regular expressions, so `--url-regex` compares with the URL the resolution read.
    static func tabGuardClause(named: TargetDocument, matchedURL: String?) -> String? {
        guard case .urlMatch(let matcher) = named else { return nil }
        if let clause = urlGuardClause(for: matcher) { return clause }
        guard let matchedURL else {
            // Nothing to compare with: refuse rather than act unchecked.
            return "error \"SB_TARGET_CHANGED\" number 9001"
        }
        return exactURLGuardClause(matchedURL)
    }

    /// The tab bound to `_t` still shows `url` (case-sensitively); a longer URL is compared by its first
    /// `tabGuardURLPrefixLength` characters.
    static func exactURLGuardClause(_ url: String) -> String {
        let comparison: String
        if url.count > tabGuardURLPrefixLength {
            comparison = "(URL of _t) does not start with \"\(String(url.prefix(tabGuardURLPrefixLength)).escapedForAppleScript)\""
        } else {
            comparison = "(URL of _t) is not equal to \"\(url.escapedForAppleScript)\""
        }
        return [
            "considering case",
            "if \(comparison) then error \"SB_TARGET_CHANGED\" number 9001",
            "end considering",
        ].joined(separator: "\n")
    }

    /// Runs `body`, turning the two markers a window-level script ends with into the errors a caller reads:
    /// `SB_TARGET_CHANGED` (9001), the URL check failed, and `SB_WINDOW_GONE` (9002), the window a
    /// file-dialog script was to act on is no longer open. The file-dialog scripts go straight to `osascript`
    /// and never pass through `runTargetedAppleScript`, which is why they announce a missing window themselves.
    static func translatingWindowLevelMarkers<T>(
        target: TargetDocument,
        profile: String?,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch SafariBrowserError.appleScriptFailed(let message) where message.contains("SB_TARGET_CHANGED") {
            throw SafariBrowserError.targetChangedBeforeActing(expected: targetDescription(target))
        } catch SafariBrowserError.appleScriptFailed(let message) where message.contains("SB_WINDOW_GONE") {
            throw try await notFoundError(for: target, profile: profile)
        }
    }

    /// The first statement of a script that acts on `window id W` outside `runTargetedAppleScript`.
    static func windowGoneCheck(windowID: Int) -> String {
        "if not (exists window id \(windowID)) then error \"SB_WINDOW_GONE\" number 9002"
    }

    // MARK: - close

    /// The one script `close` sends. With a tab it closes that tab, after the URL check when there is one;
    /// without, the window's current tab (`closeCurrentTabScript`, whose text is unchanged).
    ///
    /// No statement makes a tab current: closing a background tab leaves the visible tab alone (#348).
    static func closeTabScript(windowReference: String, tab: Int?, guardClause: String?) -> String {
        guard let tab else { return closeCurrentTabScript(windowRef: windowReference) }
        var lines = [
            "tell application \"Safari\"",
            "if (count of windows) = 0 then",
            "error \"Safari has no windows — nothing to close\"",
            "end if",
            "if (count of tabs of \(windowReference)) = 0 then",
            "error \"\(windowReference) has no tabs — nothing to close\"",
            "end if",
            "set _t to tab \(tab) of \(windowReference)",
        ]
        if let guardClause { lines.append(guardClause) }
        lines += ["close _t", "end tell"]
        return lines.joined(separator: "\n")
    }

    /// Close the tab a window-level resolution named (#353, #348): one Apple event, by window id when one was
    /// read, and never a tab switch first.
    static func closeResolvedTab(_ resolved: ResolvedWindowTarget, named: TargetDocument, profile: String?) async throws {
        let window = actingWindow(for: resolved, named: named, profile: profile)
        let target = actedTarget(for: resolved, named: named, profile: profile)
        let script = closeTabScript(
            windowReference: window.reference,
            tab: resolved.anchorTabIndex,
            guardClause: tabGuardClause(named: named, matchedURL: resolved.matchedURL))
        try await translatingWindowLevelMarkers(target: target, profile: profile) {
            _ = try await runTargetedAppleScript(script, target: target, profile: profile)
        }
    }

    // MARK: - Tab switch

    /// Make tab `tab` the current tab of the window, after the URL check when there is one, in one script.
    static func tabSwitchScript(windowReference: String, tab: Int, guardClause: String?) -> String {
        var lines = ["tell application \"Safari\"", "set _t to tab \(tab) of \(windowReference)"]
        if let guardClause { lines.append(guardClause) }
        lines += ["set current tab of \(windowReference) to _t", "end tell"]
        return lines.joined(separator: "\n")
    }

    /// Switch the resolved window to the resolved tab when it is a background tab; nothing is sent when it is
    /// already current or the target names no tab. Used by the native `upload` paths, whose file-input click
    /// has to come between the switch and the dialog script. The switch is a passively interfering side effect
    /// that `--native` / `--allow-hid` authorize (non-interference).
    static func switchToResolvedTab(_ resolved: ResolvedWindowTarget, named: TargetDocument, profile: String?) async throws {
        guard let tab = resolved.tabIndexInWindow else { return }
        let window = actingWindow(for: resolved, named: named, profile: profile)
        let target = actedTarget(for: resolved, named: named, profile: profile)
        let script = tabSwitchScript(
            windowReference: window.reference,
            tab: tab,
            guardClause: tabGuardClause(named: named, matchedURL: resolved.matchedURL))
        try await translatingWindowLevelMarkers(target: target, profile: profile) {
            _ = try await runTargetedAppleScript(script, target: target, profile: profile)
        }
    }

    // MARK: - screenshot

    /// Reads the bounds and the title of a window: `x1,y1,x2,y2` + U+001F + title. A title can contain a comma,
    /// hence the unit separator (#91).
    static func captureGeometryScript(windowReference: String) -> String {
        """
        tell application "Safari"
            set b to bounds of \(windowReference)
            set n to ""
            try
                set n to name of \(windowReference)
                if n is missing value then set n to ""
            end try
            return ((item 1 of b) as string) & "," & ((item 2 of b) as string) & "," & ((item 3 of b) as string) & "," & ((item 4 of b) as string) & (character id 31) & n
        end tell
        """
    }

    /// The AppleScript half of finding the window to capture. By id it is one script, and a window that is gone
    /// is `documentNotFound`; by position it is the two scripts sent before #353 (an existence probe that does
    /// not depend on the window having a tab, #86, then the read).
    static func readCaptureGeometry(window: ActingWindow, missTarget: TargetDocument, profile: String?) async throws -> String {
        switch window {
        case .id:
            return try await runTargetedAppleScript(
                captureGeometryScript(windowReference: window.reference), target: missTarget, profile: profile)
        case .position(let index):
            _ = try await runTargetedAppleScript(
                windowExistenceValidationScript(windowIndex: index), target: .windowIndex(index))
            return try await runAppleScript(captureGeometryScript(windowReference: window.reference))
        }
    }

    // MARK: - open: reveal an existing tab

    /// Where `focusExistingTab` reads Spaces from. Injectable so a test never asks the running Safari.
    struct SpaceProbe: Sendable {
        var current: @Sendable () -> UInt64?
        var ofWindow: @Sendable (_ windowIndex: Int) -> UInt64?

        static let live = SpaceProbe(
            current: { SafariBridge.getCurrentSpace() },
            ofWindow: { SafariBridge.detectWindowSpace(windowIndex: $0) })
    }

    /// Layers 2 and 3 of the spatial gradient, by window id, in one script: check that the tab still shows
    /// `url`, make it current when it is not, and for another window raise it and activate Safari.
    static func focusExistingScript(windowID: Int, tab: Int, url: String, switchTab: Bool, raise: Bool) -> String {
        let reference = ActingWindow.id(windowID).reference
        var lines = ["tell application \"Safari\"", "set _t to tab \(tab) of \(reference)",
                     urlGuardClause(for: .exact(url)) ?? exactURLGuardClause(url)]
        if switchTab { lines.append("set current tab of \(reference) to _t") }
        if raise { lines += ["set index of \(reference) to 1", "activate"] }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }
}
