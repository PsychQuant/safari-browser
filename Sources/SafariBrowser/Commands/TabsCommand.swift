import ArgumentParser

struct TabsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tabs",
        abstract: "List all open tabs"
    )

    func run() async throws {
        let tabs = try await SafariBridge.listTabs()
        for tab in tabs {
            print("\(tab.index)\t\(tab.title)\t\(tab.url)")
        }
    }
}
