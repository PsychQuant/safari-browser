import ArgumentParser

struct ReloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reload",
        abstract: "Reload the current page"
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        target.warnIfProfileUnsupported(commandName: "reload")
        _ = try await SafariBridge.doJavaScript("location.reload()", target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
    }
}
