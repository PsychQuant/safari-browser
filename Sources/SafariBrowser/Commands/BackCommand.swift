import ArgumentParser

struct BackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "back",
        abstract: "Navigate back in history"
    )

    func run() async throws {
        _ = try await SafariBridge.doJavaScript("history.back()")
    }
}
