import ArgumentParser

struct HighlightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "highlight",
        abstract: "Highlight an element with a red outline"
    )

    @Argument(help: "CSS selector")
    var selector: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = document.querySelector('\(selector.escapedForJS)'); if (!el) return 'NOT_FOUND'; el.style.outline = '2px solid red'; return 'OK'; })()"
        )
        if result == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
    }
}
