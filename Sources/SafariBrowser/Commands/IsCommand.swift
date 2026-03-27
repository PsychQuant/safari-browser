import ArgumentParser

struct IsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "is",
        abstract: "Check element state",
        subcommands: [
            IsVisible.self,
            IsExists.self,
            IsEnabled.self,
            IsChecked.self,
        ]
    )
}

struct IsVisible: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "visible",
        abstract: "Check if an element is visible"
    )

    @Argument(help: "CSS selector")
    var selector: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'false'; var r = el.getBoundingClientRect(); var s = getComputedStyle(el); return (r.width > 0 && r.height > 0 && s.display !== 'none' && s.visibility !== 'hidden') ? 'true' : 'false'; })()"
        )
        print(result)
    }
}

struct IsExists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exists",
        abstract: "Check if an element exists in the DOM"
    )

    @Argument(help: "CSS selector")
    var selector: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "\(selector.resolveRefJS) !== null ? 'true' : 'false'"
        )
        print(result)
    }
}

struct IsEnabled: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enabled",
        abstract: "Check if an element is enabled"
    )

    @Argument(help: "CSS selector")
    var selector: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'false'; return !el.disabled ? 'true' : 'false'; })()"
        )
        print(result)
    }
}

struct IsChecked: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checked",
        abstract: "Check if a checkbox is checked"
    )

    @Argument(help: "CSS selector")
    var selector: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return 'false'; return el.checked ? 'true' : 'false'; })()"
        )
        print(result)
    }
}
