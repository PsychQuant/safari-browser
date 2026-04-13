import ArgumentParser

struct CloseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close the current tab"
    )

    @OptionGroup var windowTarget: WindowOnlyTargetOptions

    func run() async throws {
        try await SafariBridge.closeCurrentTab(window: windowTarget.window)
    }
}
