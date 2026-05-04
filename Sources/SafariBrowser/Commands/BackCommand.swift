import ArgumentParser

struct BackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "back",
        abstract: "Navigate back in history"
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        target.warnIfProfileUnsupported(commandName: "back")
        _ = try await SafariBridge.doJavaScript("history.back()", target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
    }
}
