import Foundation

/// Section 10 v2 of `script-exec-command` — in-process step dispatcher.
/// Routes each step's command directly to `SafariBridge` without
/// spawning a subprocess. Used by the daemon's `exec.runScript`
/// handler so the entire client-daemon interaction is one socket round
/// trip; per-step subprocess overhead is eliminated.
///
/// In-process (only for the argument shapes `runsInProcess` accepts, #220): `js`, `documents`, `get url`, `get title`, `get text`,
/// `get source`, and, since #219, `click`, `fill`, `type`, `press` and the `storage local|session` subcommands
/// (`supportedCommands`). `wait` and `snapshot` still run as child processes. Any other command throws
/// `unsupportedInExec`, and a supported command with arguments outside those
/// shapes throws `unsupportedArguments`; the client runs a script containing
/// either through the subprocess path (`screenshot` / `pdf` / `upload` are
/// unsupported on that path too).
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
        /// Keyed by the target arguments' UTF-8 bytes, not by `String` equality: Swift treats canonically
        /// equivalent text (NFC and NFD spellings of the same pattern) as equal, while AppleScript and
        /// the JavaScript it embeds tell them apart. Within one run the exec-level arguments never change,
        /// so this is a guard against serving one spelling's resolution for another, not a path a real
        /// run takes; a spurious miss is the worst it can cost.
        private var cached: (args: [[UInt8]], target: SafariBridge.TargetDocument)?

        func resolve(
            args: [String],
            verify: (SafariBridge.TargetDocument) async throws -> Bool = SafariBridge.verifyResolvedTab,
            _ resolver: () async throws -> SafariBridge.TargetDocument
        ) async throws -> SafariBridge.TargetDocument {
            // A cancelled request starts no resolution and dispatches no step
            // (verify R6, R7): cancellation is cooperative, so it is checked on
            // entry, whatever the check raised, and after the check returns.
            try Task.checkCancellation()
            let key = args.map { Array($0.utf8) }
            if let hit = lock.withLock({ cached }), hit.args == key {
                // Any failure of the check counts as "not verified": the
                // daemon's NSAppleScript errors carry no -1719 / -1728 and are
                // localized, so a closed tab or window cannot be recognised
                // by its message (verify R2). A check that threw used to skip
                // this reset and leave every later step failing.
                let verified: Bool
                do {
                    verified = try await verify(hit.target)
                } catch {
                    if error is CancellationError { throw CancellationError() }
                    verified = false
                }
                try Task.checkCancellation()
                if verified { return hit.target }
                lock.withLock { cached = nil }
            }
            let target = try await resolver()
            // A request cancelled while it resolved caches and dispatches nothing
            // (verify R7, Codex).
            try Task.checkCancellation()
            lock.withLock { cached = (key, target) }
            return target
        }
    }

    /// Phase 1 commands this dispatcher handles directly. v2.0 ships the
    /// most-common read commands; v2.1 adds `get text` and `get source`
    /// which are also pure-read (no Safari state mutation). #219 adds the commands that are one
    /// JavaScript call whose script and result handling the CLI command shares with this dispatcher
    /// (`perform` / `StorageScripts`): `click`, `fill`, `type`, `press` and the `storage` subcommands.
    /// `wait` (a polling loop with its own timeout) and `snapshot` (chunked reads and options) are not
    /// here: a script that has one still runs as one child process per step.
    static let supportedCommands: Set<String> = [
        "js",
        "documents",
        "get url",
        "get title",
        "get text",
        "get source",
        "click",
        "fill",
        "type",
        "press",
        "storage local get",
        "storage local set",
        "storage local remove",
        "storage local clear",
        "storage session get",
        "storage session set",
        "storage session remove",
        "storage session clear",
    ]

    /// Whether `cmd` is one of the in-process commands. Not enough to run a step in-process:
    /// see `runsInProcess`, which also looks at the arguments (#220).
    static func isSupported(_ cmd: String) -> Bool {
        supportedCommands.contains(cmd)
    }

    /// #220: whether a step is one this dispatcher runs *exactly* as the CLI command would.
    /// The command being supported is not enough — the dispatcher reads only the target flags,
    /// so anything else on the step (a selector for `get text`, `--file` for `js`, a stray
    /// positional, a step-level `--first-match` with no target flag of its own) it would ignore
    /// or misread while a child process running the CLI command honours or rejects it. A step
    /// outside this closed list of shapes is run by a child process, and so is the whole script
    /// (the client pre-flights with this; the dispatcher enforces it too, before resolving).
    static func runsInProcess(cmd: String, args: [String]) -> Bool {
        guard supportedCommands.contains(cmd) else { return false }
        // A target flag needs a value that is not another option: a child's parser reads
        // `--url --first-match` as a flag missing its value, while `stripTargetFlags` here would
        // take `--first-match` for the value.
        var index = 0
        while index < args.count {
            if TargetOptions.targetFlagNames.contains(args[index]) {
                guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else { return false }
                index += 2
            } else {
                index += 1
            }
        }
        let hasTargetFlag = args.contains { TargetOptions.targetFlagNames.contains($0) }
        if args.contains("--first-match"), !hasTargetFlag { return false }
        let rest = stripTargetFlags(args)
        switch cmd {
        case "js":
            // Exactly the code; text that starts like an option is misread by a child's parser.
            return rest.count == 1 && !rest[0].hasPrefix("-")
        case "documents":
            // In-process is always JSON, and so is a `documents` child under exec (#220).
            return rest.isEmpty || rest == ["--json"]
        case "click", "press", "storage local get", "storage local remove",
             "storage session get", "storage session remove":
            // Exactly one positional; a value that starts like an option is misread by a child's parser (#219).
            return rest.count == 1 && !rest[0].hasPrefix("-")
        case "fill", "type", "storage local set", "storage session set":
            return rest.count == 2 && !rest[0].hasPrefix("-") && !rest[1].hasPrefix("-")
        default:
            return rest.isEmpty
        }
    }

    func dispatch(
        cmd: String,
        args: [String],
        sharedTargetArgs: [String]
    ) async throws -> String {
        // Cancelled before the step starts: nothing is resolved or dispatched for it.
        try Task.checkCancellation()
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
        guard Self.runsInProcess(cmd: cmd, args: args) else {
            throw ScriptDispatchError.unsupportedArguments(cmd)
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
        // A step with its own target flags resolves outside the shared object, and a resolver that
        // finishes after the request was cancelled still returns a target: check again before the
        // command runs, so no command's AppleScript follows a cancellation.
        try Task.checkCancellation()

        switch cmd {
        case "js":
            // `runsInProcess` has already required exactly one argument; this stays a refusal with
            // the same code as every other shape the dispatcher does not run, were that list loosened.
            guard let code = cmdArgs.first else {
                throw ScriptDispatchError.unsupportedArguments(cmd)
            }
            return try await SafariBridge.doJavaScript(
                code,
                target: resolved,
                firstMatch: target.firstMatch,
                warnWriter: nil
            )

        case "click":
            guard cmdArgs.count == 1 else { throw ScriptDispatchError.unsupportedArguments(cmd) }
            try await ClickCommand.perform(
                selector: cmdArgs[0], target: resolved, firstMatch: target.firstMatch,
                warnWriter: nil, profile: target.resolveProfile())
            return ""

        case "fill":
            guard cmdArgs.count == 2 else { throw ScriptDispatchError.unsupportedArguments(cmd) }
            try await FillCommand.perform(
                selector: cmdArgs[0], text: cmdArgs[1], target: resolved, firstMatch: target.firstMatch,
                warnWriter: nil, profile: target.resolveProfile())
            return ""

        case "type":
            guard cmdArgs.count == 2 else { throw ScriptDispatchError.unsupportedArguments(cmd) }
            try await TypeCommand.perform(
                selector: cmdArgs[0], text: cmdArgs[1], target: resolved, firstMatch: target.firstMatch,
                warnWriter: nil, profile: target.resolveProfile())
            return ""

        case "press":
            guard cmdArgs.count == 1 else { throw ScriptDispatchError.unsupportedArguments(cmd) }
            try await PressCommand.perform(
                key: cmdArgs[0], target: resolved, firstMatch: target.firstMatch,
                warnWriter: nil, profile: target.resolveProfile())
            return ""

        case "storage local get", "storage local set", "storage local remove", "storage local clear",
             "storage session get", "storage session set", "storage session remove", "storage session clear":
            // The same script as the CLI subcommand (`StorageScripts`); only `get` has a value to return.
            let parts = cmd.split(separator: " ").map(String.init)
            let area = parts[1] == "local" ? "localStorage" : "sessionStorage"
            let script: String
            switch (parts[2], cmdArgs.count) {
            case ("get", 1): script = StorageScripts.get(area, key: cmdArgs[0])
            case ("set", 2): script = StorageScripts.set(area, key: cmdArgs[0], value: cmdArgs[1])
            case ("remove", 1): script = StorageScripts.remove(area, key: cmdArgs[0])
            case ("clear", 0): script = StorageScripts.clear(area)
            default: throw ScriptDispatchError.unsupportedArguments(cmd)
            }
            let result = try await SafariBridge.doJavaScript(
                script, target: resolved, firstMatch: target.firstMatch, warnWriter: nil, profile: target.resolveProfile())
            return parts[2] == "get" ? result : ""

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
            // Same two steps as `GetText.run` (#220): native text first; a page whose native
            // text is empty is read through its innerText, in chunks for a large page.
            let native = try await SafariBridge.getCurrentText(
                target: resolved,
                firstMatch: target.firstMatch,
                warnWriter: nil
            )
            guard native.isEmpty else { return native }
            return try await SafariBridge.doJavaScriptLarge("document.body.innerText", target: resolved)

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
