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
        // --new-tab only supports --window (pick which window to add the tab to).
        if newTab {
            if target.url != nil || target.tab != nil || target.document != nil {
                throw ValidationError(
                    "--new-tab only supports --window for targeting; --url, --tab, and --document are not allowed."
                )
            }
        }
        // --new-window creates a brand-new window — no targeting makes sense.
        if newWindow {
            if target.url != nil || target.tab != nil || target.document != nil || target.window != nil {
                throw ValidationError(
                    "--new-window creates a new window and does not accept any targeting flags."
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
