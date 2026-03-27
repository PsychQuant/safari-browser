import ArgumentParser

struct DblclickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dblclick",
        abstract: "Double-click an element by CSS selector"
    )

    @Argument(help: "CSS selector")
    var selector: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'NOT_FOUND'; el.dispatchEvent(new MouseEvent('dblclick', {bubbles: true})); return 'OK'; })()"
        )
        if result == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
    }
}
