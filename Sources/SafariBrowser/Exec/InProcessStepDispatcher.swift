import Foundation

/// Section 10 v2 of `script-exec-command` — in-process step dispatcher.
/// Routes each step's command directly to `SafariBridge` without
/// spawning a subprocess. Used by the daemon's `exec.runScript`
/// handler so the entire client-daemon interaction is one socket round
/// trip; per-step subprocess overhead is eliminated.
///
/// v2.0 ships the most common Phase 1 commands as in-process; less
/// common commands (storage, snapshot, wait, type, press, fill, click,
/// get text/source) throw `unsupportedInExec` so the client falls
/// back to the subprocess path. Future iterations expand coverage.
struct InProcessStepDispatcher: StepDispatcher {

    /// Phase 1 commands this dispatcher handles directly. v2.0 ships the
    /// most-common read commands; v2.1 adds `get text` and `get source`
    /// which are also pure-read (no Safari state mutation).
    static let supportedCommands: Set<String> = [
        "js",
        "documents",
        "get url",
        "get title",
        "get text",
        "get source",
    ]

    /// Returns true when `cmd` is in `supportedCommands` so callers can
    /// pre-flight a script before sending to the daemon.
    static func isSupported(_ cmd: String) -> Bool {
        supportedCommands.contains(cmd)
    }

    func dispatch(
        cmd: String,
        args: [String],
        sharedTargetArgs: [String]
    ) async throws -> String {
        // Reconstruct the per-step target. If the step has its own
        // target flags, those override; otherwise use the shared exec
        // target args. We parse the args back into a `TargetOptions`
        // so we can call the SafariBridge resolver directly.
        let stepHasTargetFlag = args.contains { TargetOptions.targetFlagNames.contains($0) }
        let effectiveTargetArgs = stepHasTargetFlag
            ? Self.extractTargetArgs(args)
            : sharedTargetArgs
        let cmdArgs = Self.stripTargetFlags(args)

        let target = try Self.parseTargetOptions(from: effectiveTargetArgs)
        let resolved = try target.resolve()

        switch cmd {
        case "js":
            guard let code = cmdArgs.first else {
                throw ScriptDispatchError.unsupportedInExec(
                    "js: missing code argument"
                )
            }
            return try await SafariBridge.doJavaScript(
                code,
                target: resolved,
                firstMatch: target.firstMatch,
                warnWriter: nil
            )

        case "get url":
            return try await SafariBridge.getCurrentURL(
                target: resolved,
                firstMatch: target.firstMatch,
                warnWriter: nil
            )

        case "get title":
            return try await SafariBridge.getCurrentTitle(
                target: resolved,
                firstMatch: target.firstMatch,
                warnWriter: nil
            )

        case "get text":
            return try await SafariBridge.getCurrentText(
                target: resolved,
                firstMatch: target.firstMatch,
                warnWriter: nil
            )

        case "get source":
            return try await SafariBridge.getCurrentSource(
                target: resolved,
                firstMatch: target.firstMatch,
                warnWriter: nil
            )

        case "documents":
            // Reuse the existing JSON encoder used by `documents --json`.
            let documents = try await SafariBridge.listAllDocuments()
            let array = documents.map { doc in
                [
                    "index": doc.index,
                    "window": doc.window,
                    "tab_in_window": doc.tabInWindow,
                    "is_current": doc.isCurrent,
                    "url": doc.url,
                    "title": doc.title,
                ] as [String: Any]
            }
            let data = try JSONSerialization.data(
                withJSONObject: array,
                options: [.prettyPrinted, .sortedKeys]
            )
            return String(data: data, encoding: .utf8) ?? "[]"

        default:
            // Outside the v2.0 supported set — surface via the standard
            // `unsupportedInExec` so the client knows it can fall back
            // to subprocess dispatch for this script.
            throw ScriptDispatchError.unsupportedInExec(cmd)
        }
    }

    // MARK: - Helpers

    /// Pull out only the `--url` / `--window` / `--tab` / etc. pairs
    /// from args. Used when a step has its own target overrides.
    static func extractTargetArgs(_ args: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if TargetOptions.targetFlagNames.contains(a) {
                out.append(a)
                if i + 1 < args.count {
                    out.append(args[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            } else if a == "--first-match" {
                out.append(a)
                i += 1
            } else {
                i += 1
            }
        }
        return out
    }

    /// Drop the `--url` / `--window` / `--tab` / etc. pairs from args
    /// so the remaining list is the command-positional + non-target flags.
    static func stripTargetFlags(_ args: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if TargetOptions.targetFlagNames.contains(a) {
                // Skip flag and its value
                i += 2
            } else if a == "--first-match" {
                i += 1
            } else {
                out.append(a)
                i += 1
            }
        }
        return out
    }

    /// Parse a list of `--url …` / `--window …` / etc. flag pairs back
    /// into a `TargetOptions` instance using ArgumentParser. The empty
    /// list produces a default `TargetOptions` (front window).
    static func parseTargetOptions(from args: [String]) throws -> TargetOptions {
        return try TargetOptions.parse(args)
    }
}
