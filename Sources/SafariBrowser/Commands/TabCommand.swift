import ArgumentParser
import Foundation

struct TabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "Switch to a tab by index/target, open a new tab, or query/clear the ownership marker",
        subcommands: [
            TabSwitchCommand.self,
            TabFocusCommand.self,
            TabIsMarkedCommand.self,
            TabUnmarkCommand.self,
        ],
        defaultSubcommand: TabSwitchCommand.self
    )
}

/// Default subcommand: preserves the legacy `safari-browser tab <N>` and
/// `safari-browser tab new` behavior so existing scripts keep working.
struct TabSwitchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "Switch to a tab by index, or open a new tab",
        shouldDisplay: false  // hidden because it's the default
    )

    @Argument(help: "Tab index (number) or 'new' to open a new tab")
    var tabArg: String

    @OptionGroup var documentTarget: TargetOptions

    func validate() throws {
        // `tab` names a window (#352: every flag that names a tab is rejected;
        // the URL flags other than --url and --tab-in-window used to be ignored).
        let t = documentTarget
        if t.url != nil || t.urlExact != nil || t.urlEndswith != nil || t.urlRegex != nil
            || t.tab != nil || t.document != nil || t.tabInWindow != nil {
            throw ValidationError(
                "`tab` only supports --window, --window-id, and --profile for targeting; --url, --url-exact, --url-endswith, --url-regex, --tab, --document, and --tab-in-window are not allowed."
            )
        }
    }

    func run() async throws {
        let window = try await targetWindow()
        if tabArg.lowercased() == "new" {
            try await SafariBridge.openNewTab(in: window)
            return
        }

        guard let index = Int(tabArg) else {
            throw ValidationError("Expected a tab number or 'new', got '\(tabArg)'")
        }

        do {
            try await SafariBridge.switchToTab(index, in: window)
        } catch {
            throw SafariBrowserError.invalidTabIndex(index)
        }
    }

    /// The window `tab <N>` / `tab new` act on (#52, #352), as `open --new-tab` resolves it:
    /// - `--window-id W`: checked to exist (and to belong to `--profile`) before anything is sent, then
    ///   addressed by id; `tab new` does not activate Safari.
    /// - `--profile P [--window k]`: the id the profile-scoped enumeration read (it used to fall to the front
    ///   window whenever the resolver returned `.resolvedTab`).
    /// - `--window N`: the position (`tab new` reads its id before `activate`); nothing: the front window.
    private func targetWindow() async throws -> SafariBridge.NewTabWindow {
        let profile = documentTarget.resolveProfile()
        if let windowID = documentTarget.windowID {
            try SafariBridge.checkWindowID(windowID, profile: profile, in: await SafariBridge.listAllWindows())
            return .id(windowID, activate: false)
        }
        guard let profile else { return documentTarget.window.map { .index($0) } ?? .front }
        let base: SafariBridge.TargetDocument = documentTarget.window.map { .windowIndex($0) } ?? .frontWindow
        let resolved = try await SafariBridge.resolveNativeTarget(
            from: base,
            firstMatch: documentTarget.firstMatch,
            warnWriter: TargetOptions.stderrWarnWriter,
            profile: profile
        )
        return resolved.windowID.map { .id($0) } ?? .index(resolved.windowIndex)
    }
}

/// `safari-browser tab focus` — bring an existing tab to the front of its
/// window by target (#45). Unlike `tab <N>` (index-only, within a window),
/// this resolves the full TargetOptions (`--url` / `--url-exact` /
/// `--url-endswith` / `--window` / `--tab-in-window` / `--profile`) to a
/// concrete tab and sets it current via AppleScript `set current tab` — NO
/// navigation, so form input, scroll position, and focus are preserved (the
/// gap that previously forced the `open --replace-tab` re-navigation hack).
struct TabFocusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Bring an existing tab to the front by --url / --window / --tab-in-window (no navigation; preserves tab state)"
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let resolved = try await SafariBridge.resolveNativeTarget(
            from: target.resolve(),
            firstMatch: target.firstMatch,
            warnWriter: TargetOptions.stderrWarnWriter,
            profile: target.resolveProfile()
        )
        // resolveNativeTarget returns tabIndexInWindow = the tab to switch to,
        // or nil when the target IS already the current tab of its window
        // (idempotent no-op in that case).
        // #352: by the window id the resolver read, not its position looked up again.
        if let tab = resolved.tabIndexInWindow {
            try await SafariBridge.switchToTab(tab, in: resolved.windowID.map { .id($0) } ?? .index(resolved.windowIndex))
        }
    }
}

/// `safari-browser tab is-marked` — exit-code-only ownership probe per
/// Requirement: `tab is-marked` query subcommand. No stdout output.
struct TabIsMarkedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "is-marked",
        abstract: "Query whether the target tab carries the ownership marker (exit 0 = marked, 1 = unmarked, 2 = error)"
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let (resolvedTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        let profile = target.resolveProfile()
        do {
            // Read document.title (NOT window title) so the marker
            // detection matches what setTabTitle wrote. Safari's window
            // title prepends the macOS username, which would mask the
            // zero-width-space marker.
            let title = try await SafariBridge.getDocumentTitle(
                target: resolvedTarget,
                firstMatch: firstMatch,
                warnWriter: warnWriter,
                profile: profile
            )
            if MarkerConstants.hasMarker(title: title) {
                throw ExitCode(0)  // marked → exit 0
            } else {
                throw ExitCode(1)  // unmarked → exit 1
            }
        } catch let exit as ExitCode {
            throw exit  // pass through 0 / 1
        } catch {
            // Any other error (target not found, AppleScript failure) →
            // emit standard error shape on stderr, exit 2 per spec.
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            throw ExitCode(2)
        }
    }
}

/// `safari-browser tab unmark` — explicit cleanup for stuck markers from
/// crashed `--mark-tab-persist` invocations. Idempotent: removing an
/// already-unmarked title exits 0 silently.
struct TabUnmarkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unmark",
        abstract: "Remove the ownership marker from the target tab's title (idempotent)"
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let (resolvedTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        let profile = target.resolveProfile()
        do {
            // Read via document.title to match how setTabTitle wrote it.
            let title = try await SafariBridge.getDocumentTitle(
                target: resolvedTarget,
                firstMatch: firstMatch,
                warnWriter: warnWriter,
                profile: profile
            )
            if let original = MarkerConstants.unwrap(title: title) {
                try await SafariBridge.setTabTitle(
                    original,
                    target: resolvedTarget,
                    firstMatch: firstMatch,
                    warnWriter: warnWriter,
                    profile: profile
                )
            }
            // No marker present → nothing to do, exit 0.
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            throw ExitCode(2)
        }
    }
}
