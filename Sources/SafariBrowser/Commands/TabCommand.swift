import ArgumentParser

struct TabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "Switch to a tab by index, or open a new tab"
    )

    @Argument(help: "Tab index (number) or 'new' to open a new tab")
    var tabArg: String

    // Renamed to avoid collision with the `tabArg` argument; --window still
    // reaches users as the targeting flag thanks to @OptionGroup.
    @OptionGroup var documentTarget: TargetOptions

    func validate() throws {
        if documentTarget.url != nil || documentTarget.tab != nil || documentTarget.document != nil {
            throw ValidationError(
                "`tab` only supports --window for targeting; --url, --tab, and --document are not allowed."
            )
        }
    }

    func run() async throws {
        if tabArg.lowercased() == "new" {
            try await SafariBridge.openNewTab(window: documentTarget.window)
            return
        }

        guard let index = Int(tabArg) else {
            throw ValidationError("Expected a tab number or 'new', got '\(tabArg)'")
        }

        do {
            try await SafariBridge.switchToTab(index, window: documentTarget.window)
        } catch {
            throw SafariBrowserError.invalidTabIndex(index)
        }
    }
}
