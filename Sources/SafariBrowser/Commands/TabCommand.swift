import ArgumentParser
import Foundation

struct TabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "Switch to a tab by index, open a new tab, or query/clear the ownership marker",
        subcommands: [
            TabSwitchCommand.self,
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
        if documentTarget.url != nil || documentTarget.tab != nil || documentTarget.document != nil {
            throw ValidationError(
                "`tab` only supports --window for targeting; --url, --tab, and --document are not allowed."
            )
        }
    }

    func run() async throws {
        if tabArg.lowercased() == "new" {
            try await SafariBridge.openNewTab(window: documentTarget.window)
            return
        }

        guard let index = Int(tabArg) else {
            throw ValidationError("Expected a tab number or 'new', got '\(tabArg)'")
        }

        do {
            try await SafariBridge.switchToTab(index, window: documentTarget.window)
        } catch {
            throw SafariBrowserError.invalidTabIndex(index)
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
        do {
            // Read document.title (NOT window title) so the marker
            // detection matches what setTabTitle wrote. Safari's window
            // title prepends the macOS username, which would mask the
            // zero-width-space marker.
            let title = try await SafariBridge.getDocumentTitle(
                target: resolvedTarget,
                firstMatch: firstMatch,
                warnWriter: warnWriter
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
        do {
            // Read via document.title to match how setTabTitle wrote it.
            let title = try await SafariBridge.getDocumentTitle(
                target: resolvedTarget,
                firstMatch: firstMatch,
                warnWriter: warnWriter
            )
            if let original = MarkerConstants.unwrap(title: title) {
                try await SafariBridge.setTabTitle(
                    original,
                    target: resolvedTarget,
                    firstMatch: firstMatch,
                    warnWriter: warnWriter
                )
            }
            // No marker present → nothing to do, exit 0.
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            throw ExitCode(2)
        }
    }
}
