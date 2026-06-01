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
        // #51: --profile now honored for click — scope resolution + marker
        // to the named profile and drop the transitional warn helper.
        let resolved = target.resolve()
        let profile = target.resolveProfile()
        let mode = target.markTabResolved()
        try await SafariBridge.markTabIfRequested(
            target: resolved,
            mode: mode,
            firstMatch: target.firstMatch,
            warnWriter: TargetOptions.stderrWarnWriter,
            profile: profile
        ) {
            let result = try await SafariBridge.doJavaScript(
                "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'NOT_FOUND'; el.click(); return 'OK'; })()",
                target: resolved, firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: profile
            )
            if result == "NOT_FOUND" {
                throw SafariBrowserError.elementNotFound(selector)
            }
        }
    }
}
