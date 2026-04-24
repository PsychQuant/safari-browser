import ArgumentParser

struct SetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Browser settings",
        subcommands: [
            SetMedia.self,
        ]
    )
}

struct SetMedia: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "media",
        abstract: "Set color scheme (dark/light)"
    )

    @Argument(help: "Color scheme: dark or light")
    var scheme: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        guard scheme == "dark" || scheme == "light" else {
            throw ValidationError("Scheme must be 'dark' or 'light'")
        }

        _ = try await SafariBridge.doJavaScript("""
            (function(){
                var id = '__sb_color_scheme';
                var existing = document.getElementById(id);
                if (existing) existing.remove();
                var style = document.createElement('style');
                style.id = id;
                style.textContent = ':root { color-scheme: \(scheme) !important; }';
                document.head.appendChild(style);
                document.documentElement.style.colorScheme = '\(scheme)';
            })()
            """, target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter)
    }
}
