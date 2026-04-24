import ArgumentParser

struct FocusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Focus an element by CSS selector"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'NOT_FOUND'; el.focus(); return 'OK'; })()",
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter
        )
        if result == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
    }
}
