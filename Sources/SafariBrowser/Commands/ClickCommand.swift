import ArgumentParser

struct ClickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Click an element by CSS selector"
    )

    @Argument(help: "CSS selector of the element to click")
    var selector: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        target.warnIfProfileUnsupported(commandName: "click")
        let resolved = target.resolve()
        let mode = target.markTabResolved()
        try await SafariBridge.markTabIfRequested(
            target: resolved,
            mode: mode,
            firstMatch: target.firstMatch,
            warnWriter: TargetOptions.stderrWarnWriter
        ) {
            let result = try await SafariBridge.doJavaScript(
                "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'NOT_FOUND'; el.click(); return 'OK'; })()",
                target: resolved, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter
            )
            if result == "NOT_FOUND" {
                throw SafariBrowserError.elementNotFound(selector)
            }
        }
    }
}
