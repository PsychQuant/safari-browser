import ArgumentParser
import Foundation

/// Subcommand group that manages the opt-in persistent daemon.
///
/// Scaffold only (task 1.1). Subcommand bodies are stubs that will be
/// filled in across tasks 2.1 – 6.3 of the `persistent-daemon` change.
/// Full contract lives in `openspec/specs/persistent-daemon/spec.md`.
struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the opt-in Safari-browser daemon (start / stop / status / logs)",
        subcommands: [
            DaemonStartCommand.self,
            DaemonStopCommand.self,
            DaemonStatusCommand.self,
            DaemonLogsCommand.self,
        ]
    )
}

/// Resolve the daemon namespace from flag, env, or default.
///
/// Precedence matches the `Namespace isolation via NAME` spec requirement:
/// `--name` flag > `SAFARI_BROWSER_NAME` env > literal `"default"`.
/// Full resolution logic (with env lookup) arrives in task 2.2.
struct DaemonNameFlag: ParsableArguments {
    @Option(name: .long, help: "Daemon namespace. Precedence: flag > SAFARI_BROWSER_NAME env > 'default'.")
    var name: String?
}

struct DaemonStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the daemon (idempotent: no-op if already running)"
    )

    @OptionGroup var nameFlag: DaemonNameFlag

    var name: String? { nameFlag.name }

    func run() async throws {
        // Task 6.2: fork-detached daemon process, wait until socket is accepting.
        FileHandle.standardError.write(Data("daemon start: not yet implemented (persistent-daemon task 6.2)\n".utf8))
        throw ExitCode(1)
    }
}

struct DaemonStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the daemon gracefully (idempotent: no-op if not running)"
    )

    @OptionGroup var nameFlag: DaemonNameFlag

    var name: String? { nameFlag.name }

    func run() async throws {
        // Task 6.2: send shutdown request to socket, wait for exit.
        FileHandle.standardError.write(Data("daemon stop: not yet implemented (persistent-daemon task 6.2)\n".utf8))
        throw ExitCode(1)
    }
}

struct DaemonStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print daemon pid / uptime / request count / pre-compiled script count / last activity"
    )

    @OptionGroup var nameFlag: DaemonNameFlag

    var name: String? { nameFlag.name }

    func run() async throws {
        // Task 6.2: inspect pid file + query daemon for runtime stats.
        FileHandle.standardError.write(Data("daemon status: not yet implemented (persistent-daemon task 6.2)\n".utf8))
        throw ExitCode(1)
    }
}

struct DaemonLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Tail the daemon log file"
    )

    @OptionGroup var nameFlag: DaemonNameFlag

    var name: String? { nameFlag.name }

    func run() async throws {
        // Task 6.2: tail the daemon log file.
        FileHandle.standardError.write(Data("daemon logs: not yet implemented (persistent-daemon task 6.2)\n".utf8))
        throw ExitCode(1)
    }
}
