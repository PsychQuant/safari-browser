import ArgumentParser

struct ScrollIntoViewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scrollintoview",
        abstract: "Scroll element into view"
    )

    @Argument(help: "CSS selector")
    var selector: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = document.querySelector('\(selector.escapedForJS)'); if (!el) return 'NOT_FOUND'; el.scrollIntoView({behavior:'smooth',block:'center'}); return 'OK'; })()"
        )
        if result == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
    }
}
