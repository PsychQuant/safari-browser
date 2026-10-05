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
        try await BlockingDialogGate.withSingleProbe {
            try await runCommand()
        }
    }

    private func runCommand() async throws {
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
        // read-result/delete) reuse the resolved window and tab position.
        // URL-selected targets carry an in-script URL guard and bounded
        // retry (#79); positional targets do not have stable tab identity.
        // legacy enumeration without window ids degrades to positional
        // `.windowTab` / `.windowIndex`.
        //
        // #180: positional targets (`--window N --tab-in-window M`,
        // `--window N`, no flag) are anchored here too. `.resolvedTab` and
        // `.anchoredCurrentTab` skip repeated enumeration. Before this,
        // `.windowTab` cost one full enumeration per step (six round-trips).
        // #255: the default path now needs one `do JavaScript` after the
        // anchor; `--large` / `--output` still issue several.
        let (initialTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        let profile = target.resolveProfile()
        let documentTarget = try await SafariBridge.resolveToAnchoredTarget(
            initialTarget,
            firstMatch: firstMatch,
            warnWriter: warnWriter,
            profile: profile
        )
        let result: String
        do {
            if large || output != nil {
                result = try await runLargePath(jsCode, target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter, profile: profile)
            } else {
                guard let nonLarge = try await runNonLargePath(
                    jsCode, target: documentTarget, firstMatch: firstMatch,
                    warnWriter: warnWriter, profile: profile
                ) else { return }   // #82: the code navigated — reported, nothing to print
                result = nonLarge
            }
        } catch let error as SafariBrowserError {
            throw Self.anchoredFailure(error, original: initialTarget, anchored: documentTarget)
        }

        if let output {
            let path = (output as NSString).expandingTildeInPath
            try result.write(toFile: path, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("Written \(result.count) bytes to \(output)\n".utf8))
        } else if !result.isEmpty {
            print(result)
        }
    }

    /// #180 verify R1: once a positional target is anchored to
    /// `tab T of window id W`, a mid-command -1719 / -1728 is translated by the
    /// bridge into `documentNotFound`, whose message lists every open tab of
    /// every window and profile. The default target never produced that
    /// listing before it was anchored (the bridge passes `.frontWindow`
    /// failures through untouched), so anchoring would have widened what a
    /// failed `js` prints. Report the vanished tab by the target the user
    /// actually gave instead. Targets that were not positional, or failures
    /// before anchoring, pass through unchanged.
    static func anchoredFailure(
        _ error: SafariBrowserError,
        original: SafariBridge.TargetDocument,
        anchored: SafariBridge.TargetDocument
    ) -> SafariBrowserError {
        switch anchored {
        case .anchoredCurrentTab(let windowID, let tab, _):
            // The current-tab guard trips as SB_TARGET_CHANGED; a closed tab or
            // window surfaces as -1719 / -1728. Both mean the anchored tab is
            // no longer where the command started.
            guard SafariBridge.isTargetDangleError(error) else { return error }
            let anchor = "window id \(windowID) tab \(tab) at command start"
            switch original {
            case .windowIndex(let n):
                return .anchoredTargetChanged(target: "the current tab of window \(n) (\(anchor))")
            default:
                return .anchoredTargetChanged(target: "the front window's current tab (\(anchor))")
            }
        case .resolvedTab(let windowID, let tab, .none, _):
            // A position-named tab that vanished: the translated not-found
            // error lists every profile's tabs; name the target instead
            // (`--document N` too, #168 verify R2).
            guard case .documentNotFound = error else { return error }
            switch original {
            case .windowTab(let w, let t):
                return .anchoredTargetChanged(target: "window \(w) tab \(t) (window id \(windowID))")
            case .documentIndex(let n):
                return .anchoredTargetChanged(target: "document \(n) (window id \(windowID) tab \(tab) at command start)")
            default:
                return error
            }
        default:
            return error
        }
    }

    /// #76 non-large protocol, one-call form (#255).
    ///
    /// #82: returns `nil` when the user's own code navigated the page. The reply travels in the
    /// document that navigation replaces, so a successful navigation is indistinguishable from a
    /// lost reply unless the URL is checked explicitly. Reporting it as an error would tell the
    /// caller a navigation that plainly succeeded had failed.
    ///
    /// The success path is ONE `do JavaScript`: the wrapper returns its own outcome
    /// (`JSWrapper.parseInline`), and the tab's URL is read in the same AppleScript, just before
    /// the code runs (`preNavURL`). It used to be seven round trips.
    ///
    /// Which form runs is `JSSyntaxHint.formsToTry`: when a form is known to compile, only that
    /// form runs, so a missing reply is not answered by running the code again. When neither
    /// form compiles locally, the input is over the hint's size limit, or the hint cannot be
    /// computed, both are tried in turn (the old behaviour): a form Safari did parse but whose
    /// reply was lost, with the URL unchanged, can still run twice.
    private func runNonLargePath(
        _ jsCode: String,
        target documentTarget: SafariBridge.TargetDocument,
        firstMatch: Bool,
        warnWriter: ((String) -> Void)?,
        profile: String?
    ) async throws -> String? {
        var preNavURL: String?
        do {
            // #76: user code is inlined into the injected string instead of routed through
            // page-context eval() — strict-CSP pages refuse eval, while `do JavaScript` itself
            // is UA-privileged and exempt.
            let forms = JSSyntaxHint.formsToTry(for: jsCode)
            for (attempt, form) in forms.enumerated() {
                let wrapper = form == .expression
                    ? JSWrapper.inlineExpression(jsCode) : JSWrapper.inlineStatement(jsCode)
                let reply: String
                if attempt == 0 {
                    let split = JSWrapper.splitCapturedURL(try await SafariBridge.doJavaScript(
                        wrapper, target: documentTarget, firstMatch: firstMatch,
                        warnWriter: warnWriter, captureURL: true))
                    preNavURL = split.url
                    reply = split.output
                } else {
                    reply = try await SafariBridge.doJavaScript(
                        wrapper, target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
                }
                switch JSWrapper.parseInline(reply) {
                case .value(let value):
                    return value
                case .error(let message):
                    // #76: user code calling eval()/new Function() on a strict-CSP page surfaces
                    // here as a caught EvalError — append the hint.
                    throw SafariBrowserError.appleScriptFailed(
                        "JavaScript error: \(message)\(JSWrapper.cspEvalHint(for: message) ?? "")")
                case .stored(let length):
                    return try await readStoredResult(
                        length: length, target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
                case .damaged(let expected, let actual):
                    throw SafariBrowserError.appleScriptFailed(
                        "JavaScript reply damaged: the wrapper reported \(expected) UTF-16 units and \(actual) arrived, or the end of the reply is missing. The code ran; it was not run again. Use --large to read the result in chunks.")
                case .notRun:
                    // #82: nothing came back. Check for a navigation first: the reply went
                    // with the old document.
                    if let navURL = try await Self.navigatedAwayURL(
                        from: preNavURL, target: documentTarget,
                        firstMatch: firstMatch, profile: profile) {
                        Self.reportNavigation(to: navURL)
                        return nil
                    }
                    // A form that parsed and produced no reply has run (see above): do not try
                    // another. Only the unhinted both-forms case moves on to the second form.
                    if forms.count == 1 {
                        throw SafariBrowserError.appleScriptFailed(Self.noReplyMessage)
                    }
                }
            }
            throw SafariBrowserError.appleScriptFailed(
                "JavaScript syntax error: the provided code parses neither as an expression nor as a function body. (Safari's `do JavaScript` swallows the SyntaxError detail; check the code with a linter.)"
            )
        } catch let error as SafariBrowserError {
            // The wrapper ran but a later round-trip found the tab somewhere else — settle it as
            // navigation if the URL agrees, otherwise the original error stands.
            try await Self.settleNavigationOrRethrow(
                error, preNavURL: preNavURL, target: documentTarget,
                firstMatch: firstMatch, profile: profile)
            return nil
        }
    }

    /// The code parsed and Safari returned nothing, and the tab's URL did not change.
    static let noReplyMessage =
        "JavaScript returned no reply. The code parsed, so it most likely ran, but its reply did not come back: the page may have reloaded or navigated to the same address, or the result could not be passed back. It was not run again. Use --large to read a large or unusual result in chunks."

    /// A result above `JSWrapper.inlineResultLimit` was parked in the page's globals by the
    /// wrapper: read it (chunked when the plain read comes back empty), then clean up.
    private func readStoredResult(
        length: Int,
        target documentTarget: SafariBridge.TargetDocument,
        firstMatch: Bool,
        warnWriter: ((String) -> Void)?
    ) async throws -> String {
        let stored = try await SafariBridge.doJavaScript(
            "window.__sbResult", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
        let value: String
        if stored.isEmpty && length > 0 {
            value = try await SafariBridge.doJavaScriptLarge(
                "window.__sbResult", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
            FileHandle.standardError.write(Data("warning: output was large, used chunked read. Use --large to skip this.\n".utf8))
        } else {
            value = stored
        }
        _ = try await SafariBridge.doJavaScript(
            "delete window.__sbLen; delete window.__sbResult",
            target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
        return value
    }

    /// #82: the URL the target now sits on, if the user's code navigated away
    /// from `preURL` — `nil` when it did not move (or when either read failed,
    /// which stays conservative: an unknown URL is treated as "no navigation"
    /// so the existing parse-failure path still runs).
    ///
    /// Same-URL navigation (`location.reload()`, a form post back to the same
    /// address) is invisible to this check by construction. Those cases still
    /// fall through to the retry when both forms are being tried (neither compiled
    /// locally, input over the hint limit) and on the `--large` / `--output` path, so a
    /// reload can still fire twice there; with a single hinted form the missing reply
    /// is reported as `noReplyMessage`. Detecting
    /// it would need a page-side beacon that survives the very navigation it is
    /// meant to observe.
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

    /// #82: a mid-command `targetTabChanged` means the tab stopped matching —
    /// which is what a successful navigation looks like from the guard's point
    /// of view. Confirm against the URL before deciding: only report success if
    /// the tab genuinely moved somewhere new. If it did not (or the tab is gone
    /// entirely), the original error is the honest answer and is rethrown.
    static func settleNavigationOrRethrow(
        _ error: SafariBrowserError,
        preNavURL: String?,
        target: SafariBridge.TargetDocument,
        firstMatch: Bool,
        profile: String?
    ) async throws {
        guard case .targetTabChanged = error else { throw error }
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
        "note: the code navigated the page (now at \(URLText.redactURL(url))); it ran successfully but returned no readable value — the page context that would carry it was replaced.\n"
    }

    /// #76: `--large` / `--output` path without page-context eval().
    /// doJavaScriptLarge wraps its argument as `'' + (code)`, so the
    /// expression form is just newline-guarded parens. Parse failure is
    /// detected the same way as the non-large path: preset the protocol
    /// globals, then check whether the wrapper ever set __sbResultLen.
    ///
    /// INVARIANT (verify-round finding, #76): the empty-result vs
    /// parse-failure discrimination below requires that doJavaScriptLarge
    /// does NOT delete __sbResultLen on its zero-length early return —
    /// a legitimately-empty result must leave __sbResultLen == 0 (set by
    /// the wrapper), while a parse failure leaves it undefined (preset).
    /// If doJavaScriptLarge is ever refactored to always run its cleanup,
    /// every empty `--large` result would misread as a parse failure.
    /// Pinned by the `--large ""` cases in Tests/e2e-csp.sh.
    private func runLargePath(
        _ jsCode: String,
        target: SafariBridge.TargetDocument,
        firstMatch: Bool,
        warnWriter: ((String) -> Void)?,
        profile: String?
    ) async throws -> String {
        // #82: same navigation ambiguity as the non-large path — an unset
        // marker means either "never parsed" or "ran, then navigated away and
        // took the globals with it". Capture the starting URL so the two can be
        // told apart before anything is retried.
        let preNavURL = try? await SafariBridge.getCurrentURL(
            target: target, firstMatch: firstMatch, warnWriter: nil, profile: profile)
        _ = try await SafariBridge.doJavaScript(JSWrapper.presetLargeProtocolGlobals, target: target, firstMatch: firstMatch, warnWriter: warnWriter)
        var result = try await SafariBridge.doJavaScriptLarge(JSWrapper.largeExpression(jsCode), target: target, firstMatch: firstMatch, warnWriter: warnWriter)
        if result.isEmpty {
            // Order matters: a runtime error is captured in-band (the wrapper
            // returns '' after recording __sbLargeErr, so __sbResultLen reads
            // 0, not the sentinel) — check it BEFORE the parse-failure marker,
            // and never retry after it: re-running user code that already
            // executed would double its side effects.
            try await throwLargeRuntimeErrorIfAny(target: target, firstMatch: firstMatch, warnWriter: warnWriter)
            let marker = try await SafariBridge.doJavaScript("'' + window.__sbResultLen", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
            if marker.trimmingCharacters(in: .whitespacesAndNewlines) == JSWrapper.lenUnsetSentinel {
                // #82: navigation before the retry, or the retry re-runs code
                // that already took effect.
                if let navURL = try await Self.navigatedAwayURL(
                    from: preNavURL, target: target, firstMatch: firstMatch, profile: profile) {
                    Self.reportNavigation(to: navURL)
                    return ""
                }
                // Expression form never parsed (nothing ran) — retry as function body.
                result = try await SafariBridge.doJavaScriptLarge(JSWrapper.largeStatement(jsCode), target: target, firstMatch: firstMatch, warnWriter: warnWriter)
                if result.isEmpty {
                    try await throwLargeRuntimeErrorIfAny(target: target, firstMatch: firstMatch, warnWriter: warnWriter)
                    let marker2 = try await SafariBridge.doJavaScript("'' + window.__sbResultLen", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
                    if marker2.trimmingCharacters(in: .whitespacesAndNewlines) == JSWrapper.lenUnsetSentinel {
                        if let navURL = try await Self.navigatedAwayURL(
                            from: preNavURL, target: target, firstMatch: firstMatch, profile: profile) {
                            Self.reportNavigation(to: navURL)
                            return ""
                        }
                        throw SafariBrowserError.appleScriptFailed(
                            "JavaScript syntax error: the provided code parses neither as an expression nor as a function body. (Safari's `do JavaScript` swallows the SyntaxError detail; check the code with a linter.)"
                        )
                    }
                }
            }
        }
        return result
    }

    /// #76: `do JavaScript` swallows uncaught runtime throws as silently as
    /// SyntaxErrors, so the large-path wrappers record them to
    /// window.__sbLargeErr in-band. Throws the normalized `JavaScript
    /// error:` form (matching the non-large path) with the CSP hint when
    /// the user code itself called eval()/new Function() on a strict-CSP
    /// page.
    private func throwLargeRuntimeErrorIfAny(
        target: SafariBridge.TargetDocument,
        firstMatch: Bool,
        warnWriter: ((String) -> Void)?
    ) async throws {
        let errMsg = try await SafariBridge.doJavaScript("'' + window.__sbLargeErr", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
        let trimmed = errMsg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != JSWrapper.lenUnsetSentinel, !trimmed.isEmpty else { return }
        _ = try? await SafariBridge.doJavaScript("delete window.__sbLargeErr", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
        throw SafariBrowserError.appleScriptFailed("JavaScript error: \(errMsg)\(JSWrapper.cspEvalHint(for: errMsg) ?? "")")
    }
}
