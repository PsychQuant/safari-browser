import ArgumentParser

struct TabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "Switch to a tab by index, or open a new tab"
    )

    @Argument(help: "Tab index (number) or 'new' to open a new tab")
    var target: String

    func run() async throws {
        if target.lowercased() == "new" {
            try await SafariBridge.openNewTab()
            return
        }

        guard let index = Int(target) else {
            throw ValidationError("Expected a tab number or 'new', got '\(target)'")
        }

        do {
            try await SafariBridge.switchToTab(index)
        } catch {
            throw SafariBrowserError.invalidTabIndex(index)
        }
    }
}
