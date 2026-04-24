import ArgumentParser

struct ForwardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forward",
        abstract: "Navigate forward in history"
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        _ = try await SafariBridge.doJavaScript("history.forward()", target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
    }
}
