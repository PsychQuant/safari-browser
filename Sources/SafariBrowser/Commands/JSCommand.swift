import ArgumentParser
import Foundation

struct JSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "js",
        abstract: "Execute JavaScript in the current tab"
    )

    @Option(name: .long, help: "Execute JavaScript from a file")
    var file: String?

    @Option(name: .long, help: "Write result to file (for large outputs)")
    var output: String?

    @Flag(name: .long, help: "Use chunked read for large results")
    var large = false

    @Argument(help: "JavaScript code to execute")
    var code: String?

    @OptionGroup var target: TargetOptions

    func validate() throws {
        if file == nil && code == nil {
            throw ValidationError("Provide JavaScript code as an argument or use --file")
        }
    }

    func run() async throws {
        try Task.checkCancellation()
        let jsCode: String
        if let file {
            let path = (file as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw SafariBrowserError.fileNotFound(file)
            }
            jsCode = try String(contentsOfFile: path, encoding: .utf8)
        } else {
            jsCode = code!
        }

        // Resolve once at the command boundary so (a) `--first-match`
        // multi-match fires its stderr warning at most once and (b)
        // downstream internal `doJavaScript` calls (store/read-length/
        // read-result/delete) cannot race on Safari tab-list changes
        // between chunked reads. The concrete target is normally an
        // identity-anchored `.resolvedTab` (#79 — stable window id +
        // in-script URL guard + bounded retry on every round-trip);
        // legacy enumeration without window ids degrades to positional
        // `.windowTab` / `.windowIndex`.
        let (initialTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        let profile = target.resolveProfile()
        let documentTarget = try await SafariBridge.resolveToConcreteTarget(
            initialTarget,
            firstMatch: firstMatch,
            warnWriter: warnWriter,
            profile: profile
        )
        guard let result = try await runResultPath(
            jsCode, target: documentTarget, firstMatch: firstMatch,
            warnWriter: warnWriter, profile: profile
        ) else { return }

        try Task.checkCancellation()
        if let output {
            let path = (output as NSString).expandingTildeInPath
            try result.write(toFile: path, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("Written \(result.utf8.count) bytes to \(output)\n".utf8))
        } else if !result.isEmpty {
            print(result)
        }
    }

    /// One owned state for evaluation and all result reads. A large-response
    /// fallback reads the captured value instead of evaluating code again.
    private func runResultPath(
        _ code: String,
        target: SafariBridge.TargetDocument,
        firstMatch: Bool,
        warnWriter: ((String) -> Void)?,
        profile: String?
    ) async throws -> String? {
        try Task.checkCancellation()
        let preNavURL = try? await SafariBridge.getCurrentURL(
            target: target, firstMatch: firstMatch, warnWriter: nil, profile: profile)
        do {
            return try await JavaScriptResultSession().execute(
                code, allowStatements: true, chunked: large || output != nil
            ) { script in
                try await SafariBridge.doJavaScript(script, target: target,
                    firstMatch: firstMatch, warnWriter: warnWriter, profile: profile)
            }
        } catch JavaScriptResultSession.TransferFailure.executionResultLost {
            try await Self.settleNavigationOrRethrow(
                JavaScriptResultSession.TransferFailure.executionResultLost,
                preNavURL: preNavURL, target: target, firstMatch: firstMatch, profile: profile)
            return nil
        }
    }

    /// #82: the URL the target now sits on, if the user's code navigated away
    /// from `preURL` — `nil` when it did not move (or when either read failed,
    /// which stays conservative: an unknown URL is treated as "no navigation"
    /// and the missing-result failure remains explicit).
    ///
    /// Same-URL navigation (`location.reload()`, a form post back to the same
    /// address) is invisible to this check by construction. Those cases fail with unavailable result state;
    /// only a still-present prepared object permits a parse-form retry.
    static func navigatedAwayURL(
        from preURL: String?,
        target: SafariBridge.TargetDocument,
        firstMatch: Bool,
        profile: String?
    ) async throws -> String? {
        guard let preURL else { return nil }
        guard let nowURL = await currentURLIgnoringGuard(
            of: target, firstMatch: firstMatch, profile: profile)
        else { return nil }
        let before = preURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = nowURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return after != before && !after.isEmpty ? after : nil
    }

    /// #82: read the target's URL **without** the #79 identity guard. Once the
    /// user's code navigates, the guard's matcher by definition no longer
    /// matches, so a guarded read fails with `targetTabChanged` — which is
    /// precisely the situation we are trying to describe. The window id and
    /// tab position still address the same physical tab, so drop only the
    /// matcher and keep the coordinates.
    ///
    /// Falls back to the guarded read for legacy positional targets, which
    /// carry no matcher to drop.
    static func currentURLIgnoringGuard(
        of target: SafariBridge.TargetDocument,
        firstMatch: Bool,
        profile: String?
    ) async -> String? {
        if case .resolvedTab(let windowID, let tabInWindow, _, let carried) = target {
            let unguarded = SafariBridge.TargetDocument.resolvedTab(
                windowID: windowID, tabInWindow: tabInWindow,
                rematch: nil, profile: carried ?? profile)
            return try? await SafariBridge.getCurrentURL(
                target: unguarded, firstMatch: false, warnWriter: nil, profile: carried ?? profile)
        }
        return try? await SafariBridge.getCurrentURL(
            target: target, firstMatch: firstMatch, warnWriter: nil, profile: profile)
    }

    /// Only receipt-confirmed result loss permits navigation settlement.
    /// Raw target changes before execution and all other errors remain errors.
    /// URL observation still uses the existing positional heuristic; #188 owns
    /// stronger identity across tab closure/reordering and navigation.
    static func settleNavigationOrRethrow(
        _ error: Error,
        preNavURL: String?,
        target: SafariBridge.TargetDocument,
        firstMatch: Bool,
        profile: String?
    ) async throws {
        guard case JavaScriptResultSession.TransferFailure.executionResultLost = error else { throw error }
        guard let navURL = try await navigatedAwayURL(
            from: preNavURL, target: target, firstMatch: firstMatch, profile: profile)
        else { throw error }
        reportNavigation(to: navURL)
    }

    /// #82: navigation is a successful outcome, not a result — the globals the
    /// wrapper would have reported through are gone with the old document. Say
    /// so on stderr so stdout stays empty for scripts.
    static func reportNavigation(to url: String) {
        FileHandle.standardError.write(Data(navigationNote(for: url).utf8))
    }

    /// Pure message builder so the wording is testable without capturing stderr.
    static func navigationNote(for url: String) -> String {
        "note: the code navigated the page (now at \(url)); it ran successfully but returned no readable value — the page context that would carry it was replaced.\n"
    }

}
