import ArgumentParser

struct ForwardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forward",
        abstract: "Navigate forward in history"
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        // #354: --window N becomes the id of that window, once, before anything reaches Safari.
        let target = try await self.target.pinWindowAtStart()
        _ = try await SafariBridge.doJavaScript("history.forward()", target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile())
    }
}
