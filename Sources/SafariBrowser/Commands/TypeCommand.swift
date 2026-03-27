import ArgumentParser

struct TypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into an element (appends to existing value)"
    )

    @Argument(help: "CSS selector of the input element")
    var selector: String

    @Argument(help: "Text to type")
    var text: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'NOT_FOUND'; el.value += '\(text.escapedForJS)'; el.dispatchEvent(new Event('input', {bubbles: true})); return 'OK'; })()"
        )
        if result == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
    }
}
