import ArgumentParser

struct CloseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close the current tab"
    )

    /// #26: close now accepts the full TargetOptions (`--url`, `--tab`,
    /// `--document`, `--window`). The native-path resolver maps each
    /// targeting flag to a physical window + tab-in-window, switches to
    /// the target tab if needed, then closes that window's (now-current)
    /// tab. The previous `WindowOnlyTargetOptions` restriction was
    /// removed because the AppleScript `close current tab of window N`
    /// primitive is fully compatible with document-level targeting
    /// once tab switching resolves the ambiguity.
    @OptionGroup var target: TargetOptions

    func run() async throws {
        target.warnIfProfileUnsupported(commandName: "close")
        let resolved = try await SafariBridge.resolveNativeTarget(from: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
        try await SafariBridge.performTabSwitchIfNeeded(
            window: resolved.windowIndex,
            tab: resolved.tabIndexInWindow
        )
        try await SafariBridge.closeCurrentTab(window: resolved.windowIndex)
    }
}
