import ArgumentParser

struct ForwardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forward",
        abstract: "Navigate forward in history"
    )

    func run() async throws {
        _ = try await SafariBridge.doJavaScript("history.forward()")
    }
}
