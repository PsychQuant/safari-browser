import ArgumentParser

struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check a checkbox"
    )

    @Argument(help: "CSS selector of the checkbox")
    var selector: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = document.querySelector('\(selector.escapedForJS)'); if (!el) return 'NOT_FOUND'; if (!el.checked) { el.checked = true; el.dispatchEvent(new Event('change', {bubbles: true})); } return 'OK'; })()"
        )
        if result == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
    }
}

struct UncheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uncheck",
        abstract: "Uncheck a checkbox"
    )

    @Argument(help: "CSS selector of the checkbox")
    var selector: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = document.querySelector('\(selector.escapedForJS)'); if (!el) return 'NOT_FOUND'; if (el.checked) { el.checked = false; el.dispatchEvent(new Event('change', {bubbles: true})); } return 'OK'; })()"
        )
        if result == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
    }
}
