import ArgumentParser

struct StorageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "storage",
        abstract: "Manage localStorage and sessionStorage",
        subcommands: [
            StorageLocal.self,
            StorageSession.self,
        ]
    )
}

struct StorageLocal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "local",
        abstract: "Manage localStorage",
        subcommands: [
            StorageLocalGet.self,
            StorageLocalSet.self,
            StorageLocalRemove.self,
            StorageLocalClear.self,
        ]
    )
}

struct StorageSession: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Manage sessionStorage",
        subcommands: [
            StorageSessionGet.self,
            StorageSessionSet.self,
            StorageSessionRemove.self,
            StorageSessionClear.self,
        ]
    )
}

// MARK: - localStorage

struct StorageLocalGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get localStorage value")
    @Argument(help: "Key") var key: String
    @OptionGroup var target: TargetOptions
    func run() async throws {
        print(try await SafariBridge.doJavaScript(
            "localStorage.getItem('\(key.escapedForJS)') || ''",
            target: target.resolve()
        ))
    }
}

struct StorageLocalSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set localStorage value")
    @Argument(help: "Key") var key: String
    @Argument(help: "Value") var value: String
    @OptionGroup var target: TargetOptions
    func run() async throws {
        _ = try await SafariBridge.doJavaScript(
            "localStorage.setItem('\(key.escapedForJS)', '\(value.escapedForJS)')",
            target: target.resolve()
        )
    }
}

struct StorageLocalRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove localStorage item")
    @Argument(help: "Key") var key: String
    @OptionGroup var target: TargetOptions
    func run() async throws {
        _ = try await SafariBridge.doJavaScript(
            "localStorage.removeItem('\(key.escapedForJS)')",
            target: target.resolve()
        )
    }
}

struct StorageLocalClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Clear all localStorage")
    @OptionGroup var target: TargetOptions
    func run() async throws {
        _ = try await SafariBridge.doJavaScript("localStorage.clear()", target: target.resolve())
    }
}

// MARK: - sessionStorage

struct StorageSessionGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get sessionStorage value")
    @Argument(help: "Key") var key: String
    @OptionGroup var target: TargetOptions
    func run() async throws {
        print(try await SafariBridge.doJavaScript(
            "sessionStorage.getItem('\(key.escapedForJS)') || ''",
            target: target.resolve()
        ))
    }
}

struct StorageSessionSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set sessionStorage value")
    @Argument(help: "Key") var key: String
    @Argument(help: "Value") var value: String
    @OptionGroup var target: TargetOptions
    func run() async throws {
        _ = try await SafariBridge.doJavaScript(
            "sessionStorage.setItem('\(key.escapedForJS)', '\(value.escapedForJS)')",
            target: target.resolve()
        )
    }
}

struct StorageSessionRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove sessionStorage item")
    @Argument(help: "Key") var key: String
    @OptionGroup var target: TargetOptions
    func run() async throws {
        _ = try await SafariBridge.doJavaScript(
            "sessionStorage.removeItem('\(key.escapedForJS)')",
            target: target.resolve()
        )
    }
}

struct StorageSessionClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Clear all sessionStorage")
    @OptionGroup var target: TargetOptions
    func run() async throws {
        _ = try await SafariBridge.doJavaScript("sessionStorage.clear()", target: target.resolve())
    }
}
