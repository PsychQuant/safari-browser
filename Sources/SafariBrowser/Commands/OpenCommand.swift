import ArgumentParser

struct OpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a URL in Safari"
    )

    @Argument(help: "URL to open")
    var url: String

    @Flag(name: .long, help: "Open in a new tab")
    var newTab = false

    @Flag(name: .long, help: "Open in a new window")
    var newWindow = false

    func run() async throws {
        if newWindow {
            try await SafariBridge.openURLInNewWindow(url)
        } else if newTab {
            try await SafariBridge.openURLInNewTab(url)
        } else {
            try await SafariBridge.openURL(url)
        }
    }
}
