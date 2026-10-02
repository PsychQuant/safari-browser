import ArgumentParser

/// The JavaScript of every `storage` subcommand, shared by the CLI commands below and the in-process
/// `exec` dispatcher (#219), so a step cannot touch storage differently from the command.
/// `area` is `localStorage` or `sessionStorage`.
enum StorageScripts {
    static func get(_ area: String, key: String) -> String { "\(area).getItem('\(key.escapedForJS)') || ''" }
    static func set(_ area: String, key: String, value: String) -> String {
        "\(area).setItem('\(key.escapedForJS)', '\(value.escapedForJS)')"
    }
    static func remove(_ area: String, key: String) -> String { "\(area).removeItem('\(key.escapedForJS)')" }
    static func clear(_ area: String) -> String { "\(area).clear()" }
}

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
            StorageScripts.get("localStorage", key: key),
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile()
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
            StorageScripts.set("localStorage", key: key, value: value),
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile()
        )
    }
}

struct StorageLocalRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove localStorage item")
    @Argument(help: "Key") var key: String
    @OptionGroup var target: TargetOptions
    func run() async throws {
        _ = try await SafariBridge.doJavaScript(
            StorageScripts.remove("localStorage", key: key),
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile()
        )
    }
}

struct StorageLocalClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Clear all localStorage")
    @OptionGroup var target: TargetOptions
    func run() async throws {
        _ = try await SafariBridge.doJavaScript(StorageScripts.clear("localStorage"), target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile())
    }
}

// MARK: - sessionStorage

struct StorageSessionGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get sessionStorage value")
    @Argument(help: "Key") var key: String
    @OptionGroup var target: TargetOptions
    func run() async throws {
        print(try await SafariBridge.doJavaScript(
            StorageScripts.get("sessionStorage", key: key),
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile()
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
            StorageScripts.set("sessionStorage", key: key, value: value),
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile()
        )
    }
}

struct StorageSessionRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove sessionStorage item")
    @Argument(help: "Key") var key: String
    @OptionGroup var target: TargetOptions
    func run() async throws {
        _ = try await SafariBridge.doJavaScript(
            StorageScripts.remove("sessionStorage", key: key),
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile()
        )
    }
}

struct StorageSessionClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Clear all sessionStorage")
    @OptionGroup var target: TargetOptions
    func run() async throws {
        _ = try await SafariBridge.doJavaScript(StorageScripts.clear("sessionStorage"), target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter, profile: target.resolveProfile())
    }
}
