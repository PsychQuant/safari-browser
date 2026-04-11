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

    @OptionGroup var target: TargetOptions

    func validate() throws {
        // --new-tab and --new-window only accept --window targeting; reject
        // document-level flags because creating a new tab/window is a
        // window-scoped UI operation.
        if newTab || newWindow {
            if target.url != nil || target.tab != nil || target.document != nil {
                throw ValidationError(
                    "--new-tab and --new-window only support --window for targeting; --url, --tab, and --document are not allowed."
                )
            }
        }
    }

    func run() async throws {
        if newWindow {
            // New windows never target an existing window
            try await SafariBridge.openURLInNewWindow(url)
        } else if newTab {
            try await SafariBridge.openURLInNewTab(url, window: target.window)
        } else {
            try await SafariBridge.openURL(url, target: target.resolve())
        }
    }
}
