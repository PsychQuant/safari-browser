import Foundation

/// Subprocess-based step dispatcher (v1 default). Spawns the same
/// `safari-browser` binary as a subprocess per step. Subprocess routing
/// inherits the daemon opt-in automatically (the child binary calls
/// `runViaRouter` at the bridge layer), so when the caller is in daemon
/// mode each step still rides the warm daemon at ~50ms per call.
///
/// Section 10 v2 of `script-exec-command` introduces `InProcessStepDispatcher`
/// that runs INSIDE the daemon, eliminating per-step subprocess spawn cost
/// for the supported commands. This enum keeps the v1 path available for
/// stateless invocations and as a fallback when the daemon path is
/// unavailable.
enum CommandDispatch {
    /// Phase 1 commands per Requirement: Phase 1 command coverage.
    static let phase1Commands: Set<String> = [
        "click", "fill", "type", "press",
        "js", "documents", "wait", "snapshot",
        // Multi-word commands handled via prefix match below
        "get", "storage",
    ]

    /// Commands explicitly outside Phase 1 — `unsupportedInExec`.
    static let unsupportedCommands: Set<String> = [
        "screenshot", "pdf", "upload",
    ]

    /// Dispatches one step. Returns the step's stdout result on success.
    /// Throws `ScriptDispatchError.unsupportedInExec` when the command is
    /// outside the Phase 1 set, or rethrows the underlying subprocess
    /// error wrapped as `appleScriptFailed` so the calling step records
    /// it correctly.
    static func dispatch(
        cmd: String,
        args: [String],
        sharedTargetArgs: [String]
    ) async throws -> String {
        let cmdParts = cmd.split(separator: " ").map(String.init)
        let head = cmdParts.first ?? ""

        if unsupportedCommands.contains(head) {
            throw ScriptDispatchError.unsupportedInExec(cmd)
        }
        if !phase1Commands.contains(head) {
            throw ScriptDispatchError.unsupportedInExec(cmd)
        }

        let stepHasTargetFlag = args.contains { TargetOptions.targetFlagNames.contains($0) }
        let targetArgs = stepHasTargetFlag ? [] : sharedTargetArgs

        let invocation = cmdParts + args + targetArgs
        return try await runSelfBinary(arguments: invocation)
    }

    /// Executes the running `safari-browser` binary with the given
    /// arguments. Captures stdout. Non-zero exit raises an error that
    /// the step loop translates into a `StepResult.error`.
    private static func runSelfBinary(arguments: [String]) async throws -> String {
        let path = currentExecutablePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            let combined = stderrText.isEmpty ? stdoutText : stderrText
            throw SafariBrowserError.appleScriptFailed(
                combined.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return stdoutText.trimmingCharacters(in: .newlines)
    }

    private static func currentExecutablePath() -> String {
        // ProcessInfo's arguments[0] is reliable when invoked via PATH
        // resolution by the shell; fall back to /proc-style introspection
        // on macOS via _NSGetExecutablePath if needed (kept simple here).
        return CommandLine.arguments.first ?? "safari-browser"
    }
}

/// Adapter that wraps the subprocess `CommandDispatch` enum as a
/// `StepDispatcher` so `ScriptInterpreter` can be parameterized over
/// dispatch strategies.
struct SubprocessStepDispatcher: StepDispatcher {
    func dispatch(
        cmd: String,
        args: [String],
        sharedTargetArgs: [String]
    ) async throws -> String {
        return try await CommandDispatch.dispatch(
            cmd: cmd,
            args: args,
            sharedTargetArgs: sharedTargetArgs
        )
    }
}

// MARK: - Helpers shared with TargetOptions

extension TargetOptions {
    /// Flag names that indicate per-step target overrides. Listed
    /// explicitly so the dispatcher can detect when a step's args
    /// supersede the exec-level shared target.
    static let targetFlagNames: Set<String> = [
        "--url", "--url-exact", "--url-endswith", "--url-regex",
        "--window", "--tab", "--document", "--tab-in-window",
    ]
}
