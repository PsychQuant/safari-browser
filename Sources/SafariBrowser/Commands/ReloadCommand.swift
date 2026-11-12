import ArgumentParser

struct ReloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reload",
        abstract: "Reload the current page"
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        // #354: --window N becomes the id of that window, once, before anything reaches Safari.
        let target = try await self.target.pinWindowAtStart()
        _ = try await SafariBridge.doJavaScript("location.reload()", target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile())
    }
}
