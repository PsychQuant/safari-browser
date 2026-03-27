import ArgumentParser

struct ReloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reload",
        abstract: "Reload the current page"
    )

    func run() async throws {
        _ = try await SafariBridge.doJavaScript("location.reload()")
    }
}
