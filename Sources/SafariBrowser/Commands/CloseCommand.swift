import ArgumentParser

struct CloseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a tab: the tab a targeting flag names, or the current tab"
    )

    /// #26: close accepts the full TargetOptions (`--url`, `--tab`, `--document`, `--window`, …).
    ///
    /// #353 / #348: it closes the tab the resolution named, in one Apple event that names the window by its
    /// id, and it never makes a tab current first. It used to switch the target tab to the front and then
    /// close "the current tab", which changed the visible tab and closed whatever was current after the switch.
    /// `--window N` is resolved to the window's id once, at command start (#354). With no targeting flag the
    /// script is the one sent before: the current tab of the front window.
    @OptionGroup var target: TargetOptions

    func run() async throws {
        let target = try await self.target.pinWindowAtStart()
        let profile = target.resolveProfile()
        let named = target.resolve()
        let resolved = try await SafariBridge.resolveWindowLevelTarget(
            named: named, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: profile)
        try await SafariBridge.closeResolvedTab(resolved, named: named, profile: profile)
    }
}
