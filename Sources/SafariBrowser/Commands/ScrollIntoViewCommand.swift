import ArgumentParser

struct ScrollIntoViewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scrollintoview",
        abstract: "Scroll element into view"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'NOT_FOUND'; el.scrollIntoView({behavior:'smooth',block:'center'}); return 'OK'; })()",
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter
        )
        if result == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
    }
}
