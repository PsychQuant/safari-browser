import ArgumentParser

struct CloseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close the current tab"
    )

    func run() async throws {
        try await SafariBridge.closeCurrentTab()
    }
}
