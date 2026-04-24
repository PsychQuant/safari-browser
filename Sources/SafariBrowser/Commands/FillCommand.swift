import ArgumentParser

struct FillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fill",
        abstract: "Clear and fill an input element"
    )

    @Argument(help: "CSS selector of the input element")
    var selector: String

    @Argument(help: "Text to fill")
    var text: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'NOT_FOUND'; el.value = '\(text.escapedForJS)'; el.dispatchEvent(new Event('input', {bubbles: true})); el.dispatchEvent(new Event('change', {bubbles: true})); return 'OK'; })()",
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter
        )
        if result == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
    }
}
