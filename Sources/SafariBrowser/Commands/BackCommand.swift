import ArgumentParser

struct BackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "back",
        abstract: "Navigate back in history"
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        // #354: --window N becomes the id of that window, once, before anything reaches Safari.
        let target = try await self.target.pinWindowAtStart()
        _ = try await SafariBridge.doJavaScript("history.back()", target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile())
    }
}
