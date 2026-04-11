import ArgumentParser

/// Global CLI flags selecting which Safari document a subcommand operates on.
/// Added via `@OptionGroup` to any subcommand that reads from or writes to
/// a Safari document so multi-window users can target by URL, window, or
/// document index instead of relying on `front window` z-order (#17/#18/#21).
///
/// The four flags are mutually exclusive — supplying more than one in a
/// single invocation is a validation error.
struct TargetOptions: ParsableArguments {
    @Option(
        name: .long,
        help: ArgumentHelp(
            "Target the first Safari document whose URL contains this substring (case-sensitive).",
            discussion: "Example: --url plaud matches https://web.plaud.ai/"
        )
    )
    var url: String?

    @Option(
        name: .long,
        help: "Target the document of the Nth Safari window (1-indexed)."
    )
    var window: Int?

    @Option(
        name: .long,
        help: "Target document N (1-indexed). Alias for --document; kept for browser-automation familiarity."
    )
    var tab: Int?

    @Option(
        name: .long,
        help: "Target document N (1-indexed). Run `safari-browser documents` to list indices."
    )
    var document: Int?

    /// The four targeting flags are mutually exclusive. Supplying more than
    /// one produces a validation error before any AppleScript runs.
    func validate() throws {
        let providedFlags = [
            url.map { _ in "--url" },
            window.map { _ in "--window" },
            tab.map { _ in "--tab" },
            document.map { _ in "--document" },
        ].compactMap { $0 }

        if providedFlags.count > 1 {
            throw ValidationError(
                "The targeting flags \(providedFlags.joined(separator: ", ")) are mutually exclusive — pick one."
            )
        }
    }

    /// Convert the parsed flags into a `TargetDocument`. Callers pass the
    /// result into SafariBridge getters as the `target:` parameter.
    /// Returns `.frontWindow` when no flag is set, preserving legacy behavior.
    func resolve() -> SafariBridge.TargetDocument {
        if let url = url {
            return .urlContains(url)
        }
        if let window = window {
            return .windowIndex(window)
        }
        if let tab = tab {
            return .documentIndex(tab)
        }
        if let document = document {
            return .documentIndex(document)
        }
        return .frontWindow
    }
}
