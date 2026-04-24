import ArgumentParser

struct HoverCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hover",
        abstract: "Hover over an element by CSS selector"
    )

    @Argument(help: "CSS selector of the element to hover")
    var selector: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'NOT_FOUND'; el.dispatchEvent(new MouseEvent('mouseenter', {bubbles: true})); el.dispatchEvent(new MouseEvent('mouseover', {bubbles: true})); return 'OK'; })()",
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter
        )
        if result == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
    }
}
