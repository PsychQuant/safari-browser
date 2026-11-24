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
    /// - A window id the user typed, or that the pin wrote, is the id: `--window-id` never falls back to a
    ///   position, whatever the resolution carried.
    static func actingWindow(for resolved: ResolvedWindowTarget, named: TargetDocument, profile: String?) -> ActingWindow {
        let scoped = !(profile ?? "").isEmpty
        switch named {
        case .windowIndex, .windowTab:
            return .position(resolved.windowIndex)
        case .frontWindow where !scoped:
            return .position(resolved.windowIndex)
        case .windowID(let id, _, _) where id > 0:
            return .id(id)
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

    /// The error numbers a window-level script ends with. `translatingWindowLevelMarkers` reads the number at
    /// the end of the error text, never the text itself (#218): the scripts it wraps include System Events
    /// blocks, whose error text can carry a window name, which is a page title.
    enum WindowLevelMarker {
        /// `SB_TARGET_CHANGED`: the URL check, or the check that a named tab is still its window's current tab.
        static let targetChanged = 9001
        /// `SB_WINDOW_GONE`: the window a script was to act on is no longer open.
        static let windowGone = 9002
        /// `SB_TAB_GONE`: the window is open but has no tab at the position the resolution named.
        static let tabGone = 9003
    }

    /// Runs `body`, turning the markers a window-level script ends with into the errors a caller reads:
    /// `SB_TARGET_CHANGED` (9001) becomes `targetChangedBeforeActing`, and `SB_WINDOW_GONE` (9002) and
    /// `SB_TAB_GONE` (9003) become the miss `notFoundError` words for `target`. The file-dialog scripts go
    /// straight to `osascript` and never pass through `runTargetedAppleScript`, which is why they announce a
    /// missing window or tab themselves.
    ///
    /// `stage` says what the command had already done when the wrapped step runs; the target-changed error
    /// repeats it, so its text never claims that nothing was done after a tab was switched or a file dialog
    /// was opened.
    ///
    /// `translateNotFound` also turns a bare "object not found" (-1719 / -1728) into that miss. It is for the
    /// one Safari script that reaches here untranslated: a read or a click on `.anchoredCurrentTab`, whose
    /// errors `runTargetedAppleScript` passes through as they are. It must stay off for the file-dialog
    /// scripts, where System Events answers -1728 for a button or a sheet that is not there. With it, a miss
    /// the wrapped call already translated without the profile (a read on `window id W`, which takes no
    /// profile so that the windows are not enumerated a second time) is worded again with the profile, so one
    /// command words a closed window one way.
    static func translatingWindowLevelMarkers<T>(
        target: TargetDocument,
        profile: String?,
        translateNotFound: Bool = false,
        stage: SafariBrowserError.TargetChangeStage = .beforeAnyAction,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch SafariBrowserError.appleScriptFailed(let message) {
            switch appleScriptErrorCode(in: message) {
            case WindowLevelMarker.targetChanged?:
                throw SafariBrowserError.targetChangedBeforeActing(expected: targetDescription(target), stage: stage)
            case WindowLevelMarker.windowGone?, WindowLevelMarker.tabGone?:
                throw try await notFoundError(for: target, profile: profile)
            case let code? where translateNotFound && (code == -1719 || code == -1728):
                throw try await notFoundError(for: target, profile: profile)
            default:
                throw SafariBrowserError.appleScriptFailed(message)
            }
        } catch SafariBrowserError.documentNotFound where translateNotFound && rewordsMissUnderProfile(target, profile: profile) {
            throw try await notFoundError(for: target, profile: profile)
        }
    }

    /// Whether a miss on `target` reads differently with the profile: an id-based target under `--profile`.
    static func rewordsMissUnderProfile(_ target: TargetDocument, profile: String?) -> Bool {
        guard !(profile ?? "").isEmpty else { return false }
        switch target {
        case .windowID, .resolvedTab: return true
        default: return false
        }
    }

    /// The first statement of a script that acts on `window id W` outside `runTargetedAppleScript`.
    static func windowGoneCheck(windowID: Int) -> String {
        "if not (exists window id \(windowID)) then error \"SB_WINDOW_GONE\" number \(WindowLevelMarker.windowGone)"
    }

    /// Stops a script before it binds `tab <tab>` of a window that has fewer tabs: the tab the resolution
    /// named is gone. Without it the bind raises -1719, which the file-dialog scripts cannot tell from a
    /// System Events answer.
    static func tabGoneCheck(windowReference: String, tab: Int) -> String {
        "if (count of tabs of \(windowReference)) < \(tab) then error \"SB_TAB_GONE\" number \(WindowLevelMarker.tabGone)"
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

    // MARK: - Bringing a named tab forward

    /// Statements that stop when the window has no such tab (`SB_TAB_GONE`), bind the tab to `_t`, run the URL
    /// check when there is one, and make the tab the window's current tab when it is not. A tab that is already current is checked and left alone, so the
    /// check runs whether or not the tab was current when it was resolved.
    static func bringTabForwardStatements(windowReference: String, tab: Int, guardClause: String?) -> [String] {
        var lines = [
            tabGoneCheck(windowReference: windowReference, tab: tab),
            "set _t to tab \(tab) of \(windowReference)",
        ]
        if let guardClause { lines.append(guardClause) }
        lines.append("if (index of current tab of \(windowReference)) is not \(tab) then set current tab of \(windowReference) to _t")
        return lines
    }

    /// One script that brings tab `tab` of the window forward (`bringTabForwardStatements`).
    static func bringTabForwardScript(windowReference: String, tab: Int, guardClause: String?) -> String {
        (["tell application \"Safari\""]
            + bringTabForwardStatements(windowReference: windowReference, tab: tab, guardClause: guardClause)
            + ["end tell"]).joined(separator: "\n")
    }

    /// Check the tab the resolution named and make it current when it is not; nothing is sent when the target
    /// names no tab. Used by the native `upload` paths, whose file-input click has to come between this and the
    /// dialog script. The switch is a passively interfering side effect that `--native` / `--allow-hid`
    /// authorize (non-interference).
    static func bringResolvedTabForward(_ resolved: ResolvedWindowTarget, named: TargetDocument, profile: String?) async throws {
        guard let tab = resolved.anchorTabIndex else { return }
        let window = actingWindow(for: resolved, named: named, profile: profile)
        let target = actedTarget(for: resolved, named: named, profile: profile)
        let script = bringTabForwardScript(
            windowReference: window.reference,
            tab: tab,
            guardClause: tabGuardClause(named: named, matchedURL: resolved.matchedURL))
        try await translatingWindowLevelMarkers(target: target, profile: profile) {
            _ = try await runTargetedAppleScript(script, target: target, profile: profile)
        }
    }

    /// The document a native upload reads and clicks in once the target is resolved and brought forward.
    ///
    /// For a named tab of a window with an id it is `.anchoredCurrentTab`: the read and the click check, in
    /// their own script, that the tab is still that window's current tab, and stop when it is not. They do not
    /// resolve the target again, as a `.resolvedTab` with a matcher would (#79): a file dialog opened from
    /// whichever tab a second resolution found is not what the user asked for. Any other target is
    /// `actedTarget`.
    static func clickTarget(for resolved: ResolvedWindowTarget, named: TargetDocument, profile: String?) -> TargetDocument {
        if case .id(let id) = actingWindow(for: resolved, named: named, profile: profile),
           let tab = resolved.anchorTabIndex {
            return .anchoredCurrentTab(windowID: id, tabInWindow: tab, profile: profile)
        }
        return actedTarget(for: resolved, named: named, profile: profile)
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

    /// Layers 2 and 3 of the spatial gradient in one script: check that the tab still shows `url`, make it
    /// current when it is not, and for another window raise it and activate Safari. `window` is the id the
    /// enumeration read, or the position when its record carries none: the same statements either way, the
    /// raise last, because once a window named by position is raised its position is 1.
    static func focusExistingScript(window: ActingWindow, tab: Int, url: String, raise: Bool) -> String {
        let reference = window.reference
        var lines = ["tell application \"Safari\""]
        lines += bringTabForwardStatements(
            windowReference: reference, tab: tab,
            guardClause: urlGuardClause(for: .exact(url)) ?? exactURLGuardClause(url))
        if raise { lines += ["set index of \(reference) to 1", "activate"] }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    // MARK: - screenshot: the page steps

    /// The document the page steps of `screenshot --full` / `--element` run in (the size read, the scroll and
    /// its restore, the element-bounds read), once the window is known by its id.
    ///
    /// A target that names a tab was refused unless that tab is its window's current tab, so the steps use
    /// `.anchoredCurrentTab`: each checks, in its own script, that the tab is still current, and fails when it
    /// is not, because the pixels would then be another tab's. A target that names only the window reads the
    /// window's current tab, which is the tab the capture shows. `nil` when the window is named by its
    /// position: the steps then resolve the options as they did before #353.
    static func pageTarget(for resolved: ResolvedWindowTarget, named: TargetDocument, profile: String?) -> TargetDocument? {
        guard case .id(let id) = actingWindow(for: resolved, named: named, profile: profile) else { return nil }
        if let tab = resolved.anchorTabIndex {
            return .anchoredCurrentTab(windowID: id, tabInWindow: tab, profile: profile)
        }
        if case .windowID(_, nil, _) = named { return named }
        return .windowID(id)
    }
}
