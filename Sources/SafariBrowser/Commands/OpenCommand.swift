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
        // --new-tab only supports --window (pick which window to add the tab to).
        if newTab {
            if target.url != nil || target.tab != nil || target.document != nil || target.tabInWindow != nil {
                throw ValidationError(
                    "--new-tab only supports --window for targeting; --url, --tab, --document, and --tab-in-window are not allowed."
                )
            }
        }
        // --new-window creates a brand-new window — no targeting makes sense.
        if newWindow {
            if target.url != nil || target.tab != nil || target.document != nil || target.window != nil || target.tabInWindow != nil {
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
            // #51: open the new tab in the requested profile's window.
            try await SafariBridge.openURLInNewTab(url, window: profileWindow() ?? target.window)
            return
        }
        if replaceTab {
            // Opt-out of focus-existing: navigate the (profile-scoped) target
            // document via `do JavaScript window.location.href`.
            let scoped = try await target.resolveProfileScoped()
            try await SafariBridge.openURL(url, target: scoped, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
            return
        }

        // Default path — focus-existing. If the caller supplied a targeting
        // flag — or --profile (#51) — defer to explicit-target navigation:
        // their flag says exactly which tab to change, and focus-existing
        // across ALL profiles could land in the wrong identity. Otherwise
        // search for an exact URL match and focus it; when no match exists,
        // open a new tab.
        let hasExplicitTarget = target.url != nil
            || target.window != nil
            || target.tab != nil
            || target.document != nil
            || target.tabInWindow != nil
            || profile != nil

        if hasExplicitTarget {
            let scoped = try await target.resolveProfileScoped()
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
        try await SafariBridge.openURLInNewTab(url, window: nil)
    }

    /// Resolve the requested profile's window index (its front window, or
    /// --window N validated within it), or nil when --profile is not set. #51.
    private func profileWindow() async throws -> Int? {
        guard let profile = target.resolveProfile() else { return nil }
        let base: SafariBridge.TargetDocument = target.window.map { .windowIndex($0) } ?? .frontWindow
        let concrete = try await SafariBridge.resolveToConcreteTarget(
            base,
            firstMatch: target.firstMatch,
            warnWriter: TargetOptions.stderrWarnWriter,
            profile: profile
        )
        switch concrete {
        case .windowIndex(let n): return n
        case .windowTab(let n, _): return n
        default: return target.window
        }
    }
}
