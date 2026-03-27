import ArgumentParser

struct SelectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Select a dropdown option by value"
    )

    @Argument(help: "CSS selector of the <select> element")
    var selector: String

    @Argument(help: "Option value to select")
    var value: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = document.querySelector('\(selector.escapedForJS)'); if (!el) return 'NOT_FOUND'; el.value = '\(value.escapedForJS)'; el.dispatchEvent(new Event('change', {bubbles: true})); return 'OK'; })()"
        )
        if result == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
    }
}
