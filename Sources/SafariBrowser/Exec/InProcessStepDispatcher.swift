import Foundation

/// Section 10 v2 of `script-exec-command` — in-process step dispatcher.
/// Routes each step's command directly to `SafariBridge` without
/// spawning a subprocess. Used by the daemon's `exec.runScript`
/// handler so the entire client-daemon interaction is one socket round
/// trip; per-step subprocess overhead is eliminated.
///
/// In-process: `js`, `documents`, `get url`, `get title`, `get text`,
/// `get source` (`supportedCommands`). Any other command throws
/// `unsupportedInExec`, and the client runs a script containing one through
/// the subprocess path; `screenshot` / `pdf` / `upload` are unsupported on
/// that path too.
struct InProcessStepDispatcher: StepDispatcher {
    /// #170: the shared exec target, resolved once per exec run and verified
    /// before each reuse. A new dispatcher is created for every
    /// `exec.runScript` request, so this never carries Safari state across
    /// requests. Before, every step rebuilt and re-resolved the shared target —
    /// one full window/tab enumeration per step for a `--url` target.
    private let sharedResolution = SharedTargetResolution()

    /// Only a `--url` target (any matcher form) is effectively reused: it
    /// resolves to a tab that can be re-checked by its URL, while
    /// `verifyResolvedTab` refuses any target with nothing to check by
    /// (`--document N`, positional flags, `--profile` alone), so those are
    /// resolved afresh every step. Each reuse first checks that the tab still
    /// shows a URL the pattern accepts; if not, the cache is dropped and the
    /// target is resolved afresh, as each step of the subprocess path does
    /// for itself — so a navigated, moved or closed tab gives the same
    /// found / not-found outcome on both paths (verify R1: get steps used to
    /// read the cached tab unchecked). A failed resolution leaves nothing
    /// cached. A change between the check and the step itself is not
    /// detected; the subprocess path has the same gap between its resolution
    /// and its read.
    final class SharedTargetResolution: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: (args: [String], target: SafariBridge.TargetDocument)?

        func resolve(
            args: [String],
            verify: (SafariBridge.TargetDocument) async throws -> Bool = SafariBridge.verifyResolvedTab,
            _ resolver: () async throws -> SafariBridge.TargetDocument
        ) async throws -> SafariBridge.TargetDocument {
            if let hit = lock.withLock({ cached }), hit.args == args {
                // Any failure of the check counts as "not verified": the
                // daemon's NSAppleScript errors carry no -1719 / -1728 and are
                // localized, so a closed tab or window cannot be recognised
                // by its message (verify R2). A check that threw used to skip
                // this reset and leave every later step failing.
                do {
                    if try await verify(hit.target) { return hit.target }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {}
                lock.withLock { cached = nil }
            }
            let target = try await resolver()
            lock.withLock { cached = (args, target) }
            return target
        }
    }

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
        BlockingDialogGate.shared.beginCommand()

        // Reconstruct the per-step target. If the step has its own
        // target flags, those override; otherwise use the shared exec
        // target args. We parse the args back into a `TargetOptions`
        // so we can call the SafariBridge resolver directly.
        let stepHasTargetFlag = args.contains { TargetOptions.targetFlagNames.contains($0) }
        let effectiveTargetArgs = stepHasTargetFlag
            ? Self.extractTargetArgs(args)
            : sharedTargetArgs
        let cmdArgs = Self.stripTargetFlags(args)

        // A step that cannot run in-process must not pay for a resolution
        // first, nor report a resolution error instead of its own (verify R2).
        guard Self.supportedCommands.contains(cmd) else { throw ScriptDispatchError.unsupportedInExec(cmd) }
        if cmd == "js", cmdArgs.first == nil {
            throw ScriptDispatchError.unsupportedInExec("js: missing code argument")
        }

        let target = try Self.parseTargetOptions(from: effectiveTargetArgs)
        // #170: resolve to a concrete target (a `--url` / `--document` target
        // becomes an identity-anchored `.resolvedTab` with its URL guard and
        // bounded retry, #79). Steps without their own target flags share one
        // resolution per exec run. The resolution now also honours `--profile`,
        // which this path parsed but never handed to the bridge (#60 intent).
        let resolveConcrete = {
            try await SafariBridge.resolveToConcreteTarget(
                target.resolve(), firstMatch: target.firstMatch,
                warnWriter: nil, profile: target.resolveProfile())
        }
        let resolved = cmd == "documents" ? target.resolve()
            : stepHasTargetFlag ? try await resolveConcrete()
            : try await sharedResolution.resolve(args: effectiveTargetArgs, resolveConcrete)

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
            // Reuse the existing JSON encoder used by `documents --json`, and
            // its --profile filter (#47), which this path used to skip (verify R3).
            let profile = target.resolveProfile()
            let documents = try await SafariBridge.listAllDocuments().filter { profile == nil || $0.profile == profile }
            guard !documents.isEmpty else { return "[]" }
            let observation = WindowDialogObservation.capture()
            DocumentsCommand.emitDialogWarning(DocumentsCommand.dialogWarnings(commandName: "documents",
                statuses: documents.map { observation.status(for: $0.windowID) }, includeLegend: false))
            let array = DocumentsCommand.jsonRows(documents, observation: observation)
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
