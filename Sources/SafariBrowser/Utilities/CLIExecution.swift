import ArgumentParser
import Foundation

/// The same parser, command structs and diagnostics serve standalone and
/// persistent execution. Only the outer main entry point exits the process.
enum CLIExecution {
    enum Mode { case standalone, persistent }
    enum Stream { case stdout, stderr }
    struct Diagnostic {
        let exitCode: Int32
        let stream: Stream
        let bytes: Data
    }

    static func diagnostic(for error: Error) -> Diagnostic {
        let code = SafariBrowser.exitCode(for: error).rawValue
        let message = SafariBrowser.fullMessage(for: error)
        if let hint = SafariBrowser.gluedFlagHint(forErrorMessage: SafariBrowser.message(for: error)) {
            return Diagnostic(exitCode: code, stream: .stderr, bytes: Data((message + "\n" + hint + "\n").utf8))
        }
        // ArgumentParser's nonempty success messages are help/CleanExit; bare
        // ExitCode (including success) has no message. Mirror its print newline.
        return Diagnostic(exitCode: code, stream: code == 0 ? .stdout : .stderr,
                          bytes: message.isEmpty ? Data() : Data((message + "\n").utf8))
    }

    static func execute(arguments: [String]? = nil, mode: Mode = .standalone,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        diagnosticSink: (Stream, Data) -> Void = writeDiagnostic) async -> Int32 {
        let invocation = mode == .persistent ? MCPInvocationContext(environment: environment) : nil
        let timing = mode == .persistent ? invocation?.timing
            : (PerformanceTrace.isEnabled(environment) ? PerformanceTrace.Collector() : nil)
        let span = timing?.begin(.command)
        let context = timing.map { PerformanceTrace.Context(collector: $0, parentID: span) }
        func finish(_ code: Int32) {
            let outcome: PerformanceTrace.Outcome = code == 0 ? .ok : .error
            if let span { timing?.end(span, outcome: outcome) }
            if let summary = timing?.finish(status: outcome), let line = PerformanceTrace.line(summary) {
                diagnosticSink(.stderr, line)
            }
        }
        do {
            try await MCPInvocationContext.$current.withValue(invocation) {
                try await PerformanceTrace.$context.withValue(context) {
                    try MCPWorkerContext.validate(environment: environment,
                                                  currentImage: MCPWorkerContext.currentImageIdentifier)
                    let command = try SafariBrowser.parseAsRoot(arguments)
                    try validate(command, mode: mode)
                    // Long-lived hosts own no command-wide timing collector.
                    if command is DaemonServeCommand || command is MCPCommand
                        || command is MCPSupervisorCommand || command is MCPPersistentWorkerCommand {
                        _ = timing?.finish(status: .ok)
                    }
                    try await runParsed(command, environment: environment)
                }
            }
            finish(0)
            return 0
        } catch {
            let output = diagnostic(for: error)
            finish(output.exitCode)
            if !output.bytes.isEmpty { diagnosticSink(output.stream, output.bytes) }
            return output.exitCode
        }
    }

    /// Keep parser diagnostics outside this boundary. Hidden wrappers delegate
    /// here again for the actual public command, without adding their own wait.
    static func runParsed(_ command: any ParsableCommand, environment: [String: String],
                          sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws {
        let configuration = type(of: command).configuration
        // ArgumentParser returns its internal HelpCommand from parseAsRoot;
        // its reserved public name identifies it without a private type cast.
        // Visibility is not an execution role: tab's public default action is
        // hidden from help. Exempt only the actual internal hosts/wrapper.
        let exempt = configuration.commandName == "help"
            || command is MCPWorkerCommand || command is MCPSupervisorCommand || command is MCPPersistentWorkerCommand
            || command is NativeUploadWorkerCommand
            || !configuration.subcommands.isEmpty
            || command is SafariBrowser || command is WaitCommand || command is MCPCommand
            || command is DaemonCommand || command is DaemonStartCommand || command is DaemonStopCommand
            || command is DaemonStatusCommand || command is DaemonLogsCommand || command is DaemonServeCommand
        if exempt { return try await invoke(command, environment: environment, sleep: sleep) }
        let policy = try CommandPacing(environment: environment)
        try await CommandPacing.$currentEnabled.withValue(policy.isEnabled) {
            if command is ExecCommand { try await invoke(command, environment: environment, sleep: sleep) }
            else { try await policy.perform(sleep: sleep) { try await invoke(command, environment: environment, sleep: sleep) } }
        }
    }

    private static func invoke(_ parsed: any ParsableCommand, environment: [String: String],
                               sleep: (UInt64) async throws -> Void) async throws {
        if var worker = parsed as? MCPWorkerCommand {
            return try await worker.run(environment: environment, sleep: sleep)
        }
        var command = parsed
        if var asynchronous = command as? any AsyncParsableCommand { try await asynchronous.run() }
        else { try command.run() }
    }

    static func validate(_ command: any ParsableCommand, mode: Mode) throws {
        if mode == .persistent {
            let configuration = type(of: command).configuration
            guard configuration.shouldDisplay, !(command is MCPCommand) else {
                throw ValidationError("Recursive or hidden MCP dispatch is not allowed")
            }
        }
    }

    private static func writeDiagnostic(_ stream: Stream, _ bytes: Data) {
        let handle = stream == .stdout ? FileHandle.standardOutput : FileHandle.standardError
        try? handle.write(contentsOf: bytes)
    }
}
