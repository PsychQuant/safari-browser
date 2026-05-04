import ArgumentParser

struct HighlightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "highlight",
        abstract: "Highlight an element with a red outline"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        target.warnIfProfileUnsupported(commandName: "highlight")
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'NOT_FOUND'; el.style.outline = '2px solid red'; return 'OK'; })()",
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter
        )
        if result == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
    }
}
