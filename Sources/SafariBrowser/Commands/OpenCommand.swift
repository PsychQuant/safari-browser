import ArgumentParser
import Foundation

struct OpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a URL in Safari"
    )

    @Argument(help: "URL to open")
    var url: String

    @Flag(name: .long, help: "Open in a new tab")
    var newTab = false

    @Flag(name: .long, help: "Open in a new window")
    var newWindow = false

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Opt-out of focus-existing: navigate the current tab of the front window instead of focusing a matching existing tab.",
            discussion: "Once the focus-existing default lands (Group 8), this flag restores v2.4 behavior where `open` always replaces the front tab's URL via JavaScript, even when a tab with that URL already exists."
        )
    )
    var replaceTab = false

    @OptionGroup var target: TargetOptions

    func validate() throws {
        // --new-tab names a window (pick which window to add the tab to): --window,
        // --window-id, --profile. Every flag that names a tab is rejected (#352:
        // the URL flags other than --url used to be ignored, not rejected).
        if newTab {
            if target.url != nil || target.urlExact != nil || target.urlEndswith != nil || target.urlRegex != nil
                || target.tab != nil || target.document != nil || target.tabInWindow != nil {
                throw ValidationError(
                    "--new-tab only supports --window, --window-id, and --profile for targeting; --url, --url-exact, --url-endswith, --url-regex, --tab, --document, and --tab-in-window are not allowed."
                )
            }
        }
        // --new-window creates a brand-new window — no targeting makes sense.
        if newWindow {
            if target.hasExplicitTarget || target.tabInWindow != nil {
                throw ValidationError(
                    "--new-window creates a new window and does not accept any targeting flags."
                )
            }
        }
        // --replace-tab is mutually exclusive with tab/window creation.
        // It forces "navigate front tab" semantics, which conflicts with
        // both "create a new tab" and "create a new window".
        if replaceTab && (newTab || newWindow) {
            throw ValidationError(
                "--replace-tab conflicts with --new-tab and --new-window. Pick one behavior."
            )
        }
    }

    func run() async throws {
        let profile = target.resolveProfile()
        if newWindow {
            // #51: Safari's new-window API has no profile selector, so
            // --profile can't be honored here. Be explicit rather than
            // silently dropping it.
            if profile != nil {
                FileHandle.standardError.write(Data(
                    "note: --profile is ignored with --new-window (Safari opens new windows without profile selection)\n".utf8
                ))
            }
            try await SafariBridge.openURLInNewWindow(url)
            return
        }
        if newTab {
            // #51: open the new tab in the requested profile's window. #351 / #352: by its id, never by a position
            // read after Safari is activated.
            try await SafariBridge.openURLInNewTab(url, window: newTabWindow())
            return
        }
        if replaceTab {
            // Opt-out of focus-existing: navigate the (profile-scoped) target
            // document via `do JavaScript window.location.href`.
            // #354: --window N becomes the id of that window, once; `openURL` then reads the reference,
            // navigates, and activates last, as for --window-id. `--new-tab` keeps its own pre-`activate` read.
            let scoped = try await target.pinWindowAtStart().resolveProfileScoped()
            try await SafariBridge.openURL(url, target: scoped, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
            return
        }

        // Default path — focus-existing. If the caller supplied a targeting
        // flag — or --profile (#51) — defer to explicit-target navigation:
        // their flag says exactly which tab to change, and focus-existing
        // across ALL profiles could land in the wrong identity. Otherwise
        // search for an exact URL match and focus it; when no match exists,
        // open a new tab.
        // #352: `TargetOptions.hasExplicitTarget` is the one list of flags that
        // name a tab — this used to be a local copy that left out --window-id
        // and the URL flags other than --url (safari-browser#233), so
        // `open --url-endswith S <url>` opened a new tab instead.
        let hasExplicitTarget = target.hasExplicitTarget
            || target.tabInWindow != nil
            || profile != nil

        if hasExplicitTarget {
            // #354: --window N becomes the id of that window, once; `openURL` then reads the reference,
            // navigates, and activates last, as for --window-id. `--new-tab` keeps its own pre-`activate` read.
            let scoped = try await target.pinWindowAtStart().resolveProfileScoped()
            try await SafariBridge.openURL(url, target: scoped, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
            return
        }

        if let match = try await SafariBridge.findExactMatchingTab(url: url) {
            try await SafariBridge.focusExistingTab(
                window: match.window,
                tabInWindow: match.tabInWindow,
                isCurrent: match.isCurrent,
                url: url,
                warnWriter: { msg in
                    FileHandle.standardError.write(Data(msg.utf8))
                }
            )
            return
        }

        // No existing tab matches — open a new tab in the front window.
        try await SafariBridge.openURLInNewTab(url, window: .front)
    }

    /// The window `--new-tab` creates the tab in (#351, #352):
    /// - `--window-id W`: that window, without `activate`; with `--profile` the
    ///   enumeration first checks W belongs to the profile (fails closed otherwise).
    /// - `--profile P [--window k]`: the id the profile-scoped enumeration read
    ///   for that window (`activate` kept); a legacy record without an id falls
    ///   back to its position, which the script pins before `activate`.
    /// - `--window N`: the position, pinned by id before `activate` in the script.
    /// - nothing: the front window.
    private func newTabWindow() async throws -> SafariBridge.NewTabWindow {
        let profile = target.resolveProfile()
        if let windowID = target.windowID {
            // Checked before anything is sent, with or without --profile, so a
            // missing id is a targeting miss rather than a raw AppleScript error.
            try SafariBridge.checkWindowID(windowID, profile: profile, in: await SafariBridge.listAllWindows())
            return .id(windowID, activate: false)
        }
        guard let profile else { return target.window.map { .index($0) } ?? .front }
        let base: SafariBridge.TargetDocument = target.window.map { .windowIndex($0) } ?? .frontWindow
        let resolved = try await SafariBridge.resolveNativeTarget(
            from: base,
            firstMatch: target.firstMatch,
            warnWriter: TargetOptions.stderrWarnWriter,
            profile: profile
        )
        return resolved.windowID.map { .id($0) } ?? .index(resolved.windowIndex)
    }
}
