import ArgumentParser
import Foundation

/// Global CLI flags selecting which Safari document a subcommand operates on.
/// Added via `@OptionGroup` to any subcommand that reads from or writes to
/// a Safari document so multi-window users can target by URL, window, or
/// document index instead of relying on `front window` z-order (#17/#18/#21).
///
/// Targeting modes:
/// - `--url <substring>` (standalone)
/// - `--window N` (standalone, or paired with `--tab-in-window`)
/// - `--window N --tab-in-window M` (composite, same-URL escape hatch — #28)
/// - `--window-id W` (standalone, or paired with `--tab-in-window`) — the
///   window by its stable AppleScript id (#352)
/// - `--tab N` (standalone, **deprecated** — alias for `--document`)
/// - `--document N` (standalone)
///
/// Exclusivity rules:
/// 1. `--tab-in-window` SHALL pair with `--window` or `--window-id`; solo usage is rejected.
/// 2. `--window` SHALL NOT combine with `--url`, `--tab`, or `--document`;
///    `--window-id` SHALL NOT combine with any of those or with `--window`.
/// 3. `--url`, `--tab`, `--document` are mutually exclusive with each other.
struct TargetOptions: ParsableArguments {
    @Option(
        name: .long,
        help: ArgumentHelp(
            "Target the first Safari document whose URL contains this substring (case-sensitive).",
            discussion: "Example: --url plaud matches https://web.plaud.ai/"
        )
    )
    var url: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Target the Safari document whose URL equals this string exactly (no normalization).",
            discussion: "Exact-match avoids the hierarchical-URL prefix ambiguity of --url. Trailing slash, query string, and host case are all significant — use --url-endswith or --url-regex when normalization is desired."
        )
    )
    var urlExact: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Target the Safari document whose URL ends with this suffix (case-sensitive).",
            discussion: "Primary escape from prefix-substring ambiguity — a unique suffix differentiates parent from child URLs. Example: --url-endswith /play uniquely locks the deepest tab when parent tabs share a prefix."
        )
    )
    var urlEndswith: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Target the Safari document whose URL matches this NSRegularExpression pattern.",
            discussion: "Unanchored by default (add ^...$ for exact match). Case-sensitive. Compiled once at validate() — invalid patterns fail fast with a clear error. No timeout; Safari URLs are bounded so ReDoS risk is negligible."
        )
    )
    var urlRegex: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Restrict target resolution to windows of the given Safari profile (e.g. \"個人\", \"Work\").",
            discussion: "Detection is by window-name parsing: Safari 17+ prepends the active profile to each window's title with em-dash separator (`<profile> — <title>`). AppleScript has no `current profile` property, so window-name parsing is the only reliable mechanism — verified against Safari 18 in Issue #47. Combine with --url / --window / etc. to disambiguate same-URL tabs across profiles. Profile = nil windows (default profile or pre-multi-profile Safari) never match — exact-match semantics. Case-sensitive.\n\nHonored by all targeting-capable commands — the Issue #51 rollout is complete, so --profile is enforced at the SafariBridge boundary everywhere it applies. The rare exceptions that cannot honor it (e.g. `open --new-window`, where Safari's API has no profile selector) emit an explicit note instead of silently dropping it. A profile name must be non-empty, at most 256 characters, free of control characters, and must not contain the em-dash separator Safari places between profile and window title (such a name is unparseable — see #55)."
        )
    )
    var profile: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Target the document of the Nth Safari window (1-indexed). Pair with --tab-in-window to select a specific tab.",
            discussion: "N counts windows from the front when the command starts. Most commands that read or act on a tab resolve it to that window's stable id once, before anything else, and then address the window by id (as --window-id does), so a window raised mid-command does not redirect later steps; if that window closes mid-command the command fails instead of using the window now in position N. --tab-in-window M stays a position inside that window. If the id cannot be read at start, a note says so and N stays a position. `close`, `screenshot`, `pdf` and `upload` on its native paths (#353), and `tab <N>`, still look the position up."
        )
    )
    var window: Int?

    @Option(
        name: .customLong("window-id"),
        help: ArgumentHelp(
            "Target the Safari window whose stable id is W (its current tab; pair with --tab-in-window for another tab).",
            discussion: "The id is Safari's own `id of window`: it does not change while the window is open, unlike --window N, which counts windows from the front when each command starts, so a window raised between two commands does not change which window the reference names. Read the ids from `safari-browser documents --json` (`window_id`). A window id that does not exist, or one outside --profile, fails with \"No Safari document matches\"; it never falls back to the front window. `close`, `screenshot`, `pdf`, and `upload` on its native paths (`--native`, `--allow-hid`, or the default when Accessibility is granted) find the window by its id but still act on it by its position (#353). Mutually exclusive with --window, --url, --url-exact, --url-endswith, --url-regex, --tab and --document."
        )
    )
    var windowID: Int?

    /// #354: the `--window N` a `--window-id` was read from by `pinWindowAtStart()` at command start.
    /// Private (not in `--help` or the MCP tool schema): it exists so `exec`, which hands its target to
    /// each step as command-line arguments (`ScriptInterpreter.encodeTargetArgs`), keeps naming the
    /// user's `--window N` in a miss. It changes only the wording of an error, never the target.
    @Option(
        name: .customLong("pinned-from-window"),
        help: ArgumentHelp("The --window number a --window-id was read from at command start (internal).",
                           visibility: .private)
    )
    var pinnedFromWindow: Int?

    @Option(
        name: .long,
        help: "Target document N (1-indexed). Alias for --document; kept for browser-automation familiarity."
    )
    var tab: Int?

    @Option(
        name: .long,
        help: "Target document N (1-indexed). Run `safari-browser documents` to list indices."
    )
    var document: Int?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Target the Nth tab within --window M or --window-id W (1-indexed). Same-URL escape hatch.",
            discussion: "Requires --window or --window-id. Example: --window 1 --tab-in-window 2 targets the second tab of window 1, useful when multiple tabs share the same URL."
        )
    )
    var tabInWindow: Int?

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Opt-in: when --url <substring> matches multiple tabs, select the first match (with stderr warning).",
            discussion: "Without this flag, multi-match URL substrings fail-closed with ambiguousWindowMatch — safer default per the human-emulation principle."
        )
    )
    var firstMatch = false

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Opt-in: wrap the target tab title with a zero-width ownership marker for the duration of this command (ephemeral mode).",
            discussion: "Default OFF. Mutually exclusive with --mark-tab-persist. See `tab-ownership-marker` capability for full semantics."
        )
    )
    var markTab = false

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Opt-in: wrap the target tab title with a zero-width ownership marker AND keep it after the command exits (persist mode).",
            discussion: "Use `safari-browser tab unmark` to remove. Mutually exclusive with --mark-tab."
        )
    )
    var markTabPersist = false

    /// Tri-state result of resolving the `--mark-tab` flags + env variable.
    /// `.off` → no title mutation; `.ephemeral` → wrap then unwrap;
    /// `.persist` → wrap and leave for `tab unmark` cleanup.
    enum MarkTabMode: String, Equatable {
        case off
        case ephemeral
        case persist
    }

    /// Resolves the marker mode from flags first, then env var.
    /// Flags always win; env is a session-wide opt-in fallback per
    /// Requirement: Marker is opt-in via `--mark-tab` flag, default OFF.
    /// Pure function — env is injected for testability.
    func markTabResolved(env: [String: String]) -> MarkTabMode {
        if markTabPersist { return .persist }
        if markTab { return .ephemeral }
        let raw = env["SAFARI_BROWSER_MARK_TAB"] ?? ""
        switch raw {
        case "1": return .ephemeral
        case "2", "persist": return .persist
        default: return .off
        }
    }

    /// Convenience that reads the process environment.
    func markTabResolved() -> MarkTabMode {
        markTabResolved(env: ProcessInfo.processInfo.environment)
    }

    /// Validates that `--mark-tab` and `--mark-tab-persist` are not both
    /// supplied. Called from `validate()`. Kept as a separate method so
    /// tests can exercise the rule directly without invoking the full
    /// validate() body.
    func validateMarkTabFlags() throws {
        if markTab && markTabPersist {
            throw ValidationError(
                "--mark-tab and --mark-tab-persist are mutually exclusive — pick one."
            )
        }
    }

    /// Pure helper: produce a deprecation warning message when the
    /// caller used the `--tab` alias. Returns nil when `--tab` was not
    /// supplied. Kept pure so tests do not need to capture stderr.
    static func deprecationMessage(tab: Int?) -> String? {
        guard tab != nil else { return nil }
        return "warning: --tab is deprecated and will be removed in v3.0. "
            + "Use --document N for the global document index (current behavior), "
            + "or --window M --tab-in-window N for a specific tab within a window.\n"
    }

    /// Enforce the exclusivity rules documented at the top of the type.
    /// This runs before any AppleScript executes, so invalid combinations
    /// fail fast with a clear message rather than surfacing as opaque
    /// `appleScriptFailed` errors downstream.
    ///
    /// Also side-effects: when `--tab` is supplied, emits the
    /// deprecation warning to stderr. This is validate-time (not
    /// run-time) so even parse-only tooling surfaces the warning.
    func validate() throws {
        if let msg = TargetOptions.deprecationMessage(tab: tab) {
            FileHandle.standardError.write(Data(msg.utf8))
        }

        try validateMarkTabFlags()

        // Rule 1: --tab-in-window requires --window or --window-id
        if tabInWindow != nil && window == nil && windowID == nil {
            throw ValidationError(
                "--tab-in-window requires --window or --window-id (e.g. --window 1 --tab-in-window 2)"
            )
        }

        // Collect URL-matching flags first for targeted cross-checks.
        let urlMatchingFlags: [String] = [
            url.map { _ in "--url" },
            urlExact.map { _ in "--url-exact" },
            urlEndswith.map { _ in "--url-endswith" },
            urlRegex.map { _ in "--url-regex" },
        ].compactMap { $0 }

        // Rule 2a: the four URL-matching flags are mutually exclusive —
        // pick one matching strategy per invocation (#34 requirement).
        if urlMatchingFlags.count > 1 {
            throw ValidationError(
                "The URL-matching flags \(urlMatchingFlags.joined(separator: ", ")) are mutually exclusive — pick one."
            )
        }

        // Rule 2b: empty --url-endswith expresses no intent; reject
        // early rather than silently matching every tab.
        if let s = urlEndswith, s.isEmpty {
            throw ValidationError(
                "--url-endswith requires a non-empty suffix (an empty suffix would match every tab)."
            )
        }

        // Rule 2c: compile --url-regex at parse time so users see a
        // clear pattern-compile error instead of a cryptic failure
        // later in the resolver.
        if let pattern = urlRegex {
            do {
                _ = try NSRegularExpression(pattern: pattern, options: [])
            } catch {
                throw ValidationError(
                    "--url-regex pattern failed to compile: \(error.localizedDescription)"
                )
            }
        }

        let standaloneFlags: [String] = urlMatchingFlags + [
            tab.map { _ in "--tab" },
            document.map { _ in "--document" },
        ].compactMap { $0 }

        // Rule 2 (#352): --window-id names the window by id; every other
        // flag that names a window or tab is a second, competing target.
        if windowID != nil {
            let others = standaloneFlags + (window != nil ? ["--window"] : [])
            if !others.isEmpty {
                throw ValidationError(
                    "--window-id is mutually exclusive with \(others.joined(separator: ", "))"
                )
            }
        }

        // Rule 2: --window not combinable with standalone flags
        if window != nil && !standaloneFlags.isEmpty {
            throw ValidationError(
                "--window is mutually exclusive with \(standaloneFlags.joined(separator: ", "))"
            )
        }

        // Rule 3: standalone flags mutually exclusive with each other
        if standaloneFlags.count > 1 {
            throw ValidationError(
                "The targeting flags \(standaloneFlags.joined(separator: ", ")) are mutually exclusive — pick one."
            )
        }

        // Index flags must be positive (1-indexed per AppleScript convention).
        // 0 / negative produce AppleScript runtime errors that surface as
        // opaque appleScriptFailed messages — fail fast here.
        if let w = window, w < 1 {
            throw ValidationError("--window must be >= 1 (1-indexed), got \(w)")
        }
        if let id = windowID, id < 1 {
            throw ValidationError("--window-id must be a Safari window id (>= 1), got \(id)")
        }
        // #354: only meaningful next to the id it describes.
        if let n = pinnedFromWindow {
            if windowID == nil {
                throw ValidationError("--pinned-from-window requires --window-id")
            }
            if n < 1 {
                throw ValidationError("--pinned-from-window must be >= 1 (1-indexed), got \(n)")
            }
        }
        if let t = tab, t < 1 {
            throw ValidationError("--tab must be >= 1 (1-indexed), got \(t)")
        }
        if let d = document, d < 1 {
            throw ValidationError("--document must be >= 1 (1-indexed), got \(d)")
        }
        if let m = tabInWindow, m < 1 {
            throw ValidationError("--tab-in-window must be >= 1 (1-indexed), got \(m)")
        }

        // --profile validation hardening. Real Safari profile names are
        // short printable strings; anything else signals a typo or an
        // attempt to smuggle control sequences into stderr / shared logs
        // (self-DoS only on a personal-Mac CLI, but failing fast surfaces
        // intent errors early). Checks ordered cheap → specific.
        if let p = profile {
            // #61: empty value expresses no intent — mirror --url-endswith "".
            if p.isEmpty {
                throw ValidationError(
                    "--profile requires a non-empty name (an empty profile matches nothing)."
                )
            }
            // #65: cap length so a typo can't produce a 1MB stderr line.
            if p.count > 256 {
                throw ValidationError(
                    "--profile name too long (\(p.count) chars; limit 256). Real Safari profile names are short."
                )
            }
            // #63 + #65: reject control chars / ANSI escapes at the boundary.
            if p.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                throw ValidationError(
                    "--profile contains control characters; use printable Unicode only."
                )
            }
            // #55: parseProfile splits window titles on this exact separator,
            // so a profile name containing it could never match its own
            // window. Reuse the parser's constant so the two can't drift.
            if p.contains(SafariBridge.UrlMatcher.profileSeparator) {
                throw ValidationError(
                    "--profile cannot contain the \"\(SafariBridge.UrlMatcher.profileSeparator)\" separator "
                    + "(Safari uses it to delimit profile from window title; such a name is unmatchable). See #55."
                )
            }
        }
    }

    /// True when a flag that names a tab was given (#210). `--profile` and
    /// `--first-match` only narrow or relax a selection; on their own they name
    /// nothing, so a command that refuses to act without an explicit target
    /// must not count them.
    var hasExplicitTarget: Bool {
        url != nil || urlExact != nil || urlEndswith != nil || urlRegex != nil
            || window != nil || windowID != nil || tab != nil || document != nil
    }

    /// Convert the parsed flags into a `TargetDocument`. Precedence
    /// (already checked as mutually exclusive by `validate()`):
    /// 0. `--window-id` (with or without `--tab-in-window`) → `.windowID(w, tabInWindow: m)`
    /// 1. `--window + --tab-in-window` → `.windowTab(w, m)`
    /// 2. `--url` → `.urlContains`
    /// 3. `--window` only → `.windowIndex`
    /// 4. `--tab` / `--document` → `.documentIndex`
    /// 5. none → `.frontWindow`
    func resolve() -> SafariBridge.TargetDocument {
        // #352: by stable window id, always as `.windowID`. Every consumer treats
        // a `.resolvedTab` as already checked, so a user's flags must not produce
        // one: nothing would notice a missing window or tab before the first
        // action, and `open` would still make a new window.
        if let id = windowID {
            return .windowID(id, tabInWindow: tabInWindow, pinnedFrom: pinnedFromWindow)
        }
        if let w = window, let m = tabInWindow {
            return .windowTab(window: w, tabInWindow: m)
        }
        // URL-matching flags in priority order (exactly one is set, per validate()).
        if let url = url {
            return .urlMatch(.contains(url))
        }
        if let exact = urlExact {
            return .urlMatch(.exact(exact))
        }
        if let suffix = urlEndswith {
            return .urlMatch(.endsWith(suffix))
        }
        if let pattern = urlRegex {
            // validate() ensured the pattern compiles; force-try mirrors
            // that contract (no user reaches here with an invalid pattern).
            // swiftlint:disable:next force_try
            let regex = try! NSRegularExpression(pattern: pattern, options: [])
            return .urlMatch(.regex(regex))
        }
        if let window = window {
            return .windowIndex(window)
        }
        if let tab = tab {
            return .documentIndex(tab)
        }
        if let document = document {
            return .documentIndex(document)
        }
        return .frontWindow
    }

    /// #354: the command-start step. `--window N` (and `--window N --tab-in-window M`) counts windows from
    /// the front, and every Apple event that names `window N` looks the position up again, so a window raised
    /// between two steps of one command redirected the later steps. This reads the id of the window that is
    /// N now, once, and returns a copy in which `--window N` has become `--window-id W` (`--tab-in-window M`,
    /// `--profile` and every other flag kept, `pinnedFromWindow` = N for the wording of a miss). Every later
    /// `resolve()` / `resolveProfileScoped()` / `resolveFirstMatchOnce()` / `resolveWithFirstMatch()` on the
    /// copy therefore addresses the window as `--window-id W` does. `--tab-in-window M` stays a position inside
    /// that window (#188).
    ///
    /// - Without `--profile`: one small query, the one `js` anchors with (#180, #255) — `readWindowAnchor`
    ///   for `--window N`, `readTabAnchor` plus `1 <= M <= tab count` for `--tab-in-window M`.
    /// - With `--profile`: N counts that profile's windows, which only the enumeration knows, so the id is
    ///   the one one profile-scoped enumeration reads (no dialog probe: the command's own first step probes).
    ///   That enumeration is the profile check for the whole command: a pinned id is not checked again per
    ///   Apple event (a window's profile does not change while it is open), so the pin costs no enumeration
    ///   beyond the one the first step made before (verify F5).
    /// - An id that arrived pinned (`--window-id W --pinned-from-window N`, as `exec` hands it to a step) under
    ///   `--profile`: checked against the profile once, here, for the same reason.
    /// - The id cannot be read — no N-th window, a window with no tab, tab M outside the window (the anchor
    ///   query, or the profile enumeration's not-found answer), a legacy record without an id, and, without
    ///   `--profile`, an anchor query that did not answer: `self` unchanged, so the first step fails — or runs —
    ///   exactly as before (#87 / #97, the js/wait precedent), and `note` gets one line saying the position is
    ///   used. Under `--profile`, an enumeration that times out or fails is thrown, not retried by the first
    ///   step (verify F18), and so is cancellation.
    /// - Any other flag set: `self` unchanged, nothing sent.
    ///
    /// Call it in `run()` after the command's own argument checks and before anything else reaches Safari
    /// (including the `--mark-tab` wrap): `let target = try await self.target.pinWindowAtStart()`. `close`,
    /// `screenshot`, `pdf` and the native upload paths are to use the same line (#353).
    func pinWindowAtStart(note: ((String) -> Void)? = nil) async throws -> TargetOptions {
        if window == nil, windowID != nil, pinnedFromWindow != nil, let profile, !profile.isEmpty {
            _ = try await SafariBridge.resolveNativeTarget(
                from: resolve(), firstMatch: firstMatch, warnWriter: nil, profile: profile, probeDialog: false)
            return self
        }
        guard let n = window, windowID == nil else { return self }
        let id: Int?
        if let profile, !profile.isEmpty {
            let positional: SafariBridge.TargetDocument = tabInWindow.map { .windowTab(window: n, tabInWindow: $0) }
                ?? .windowIndex(n)
            do {
                id = try await SafariBridge.resolveNativeTarget(
                    from: positional, firstMatch: firstMatch, warnWriter: nil, profile: profile, probeDialog: false).windowID
            } catch SafariBrowserError.documentNotFound {
                // No N-th window of the profile, or no tab M in it: the first step reports it in its own words.
                id = nil
            }
        } else if let m = tabInWindow {
            let anchor = await SafariBridge.readTabAnchor(windowIndex: n)
            id = anchor.flatMap { m >= 1 && m <= $0.tabCount ? $0.windowID : nil }
        } else {
            id = await SafariBridge.readWindowAnchor(index: n)?.windowID
        }
        try Task.checkCancellation()
        guard let id, id > 0 else {
            Self.emitPinNote(Self.pinFallbackNote(window: n), to: note)
            return self
        }
        var pinned = self
        pinned.window = nil
        pinned.windowID = id
        pinned.pinnedFromWindow = n
        return pinned
    }

    /// #354 verify F20: the one line a command prints when `--window N` stays a position.
    static func pinFallbackNote(window n: Int) -> String {
        "note: the id of window \(n) could not be read when the command started, so --window \(n) is looked up "
            + "by its position at each step (a window raised mid-command can take its place).\n"
    }

    private static func emitPinNote(_ line: String, to note: ((String) -> Void)?) {
        if let note { note(line) }
        else if let context = DaemonRequestContext.current { context.emit(line) }
        else { FileHandle.standardError.write(Data(line.utf8)) }
    }

    /// Default warn-writer shared by every command that wires
    /// `--first-match` plumb-through. Writes UTF-8 encoded messages to
    /// stderr so users see which tab was chosen from a multi-match
    /// fallback. Exposed as a static property so inline command call
    /// sites can reference it without constructing a closure each time.
    static let stderrWarnWriter: @Sendable (String) -> Void = { msg in
        FileHandle.standardError.write(Data(msg.utf8))
    }

    /// Resolve to a concrete `TargetDocument`, scoped to `--profile` when set.
    /// When `--profile` is present, the result is the profile's concrete
    /// window/tab (via `resolveToConcreteTarget`, reusing the #47 filter), so
    /// downstream bridge calls inherit profile scoping without each needing a
    /// `profile:` parameter. When absent, returns `resolve()` unchanged so the
    /// no-profile path is byte-identical. Commands whose downstream bridge
    /// methods don't take `profile:` (get text/html, save-image, upload) call
    /// `resolveFirstMatchOnce`, which falls back to this.
    func resolveProfileScoped(
        warnWriter: @escaping (String) -> Void = TargetOptions.stderrWarnWriter
    ) async throws -> SafariBridge.TargetDocument {
        guard let profile = profile, !profile.isEmpty else { return resolve() }
        return try await SafariBridge.resolveToConcreteTarget(
            resolve(),
            firstMatch: firstMatch,
            warnWriter: warnWriter,
            profile: profile
        )
    }

    /// `resolveProfileScoped`, and `--first-match` honoured (#220, #231). `resolveProfileScoped`
    /// resolves to a concrete tab only for `--profile`; for a command whose reads take no
    /// `firstMatch`, an ambiguous `--url` therefore threw although the flag was given. Given
    /// `--first-match` and no `--profile`, a URL-pattern target is resolved once here to a concrete
    /// tab — one enumeration, one warning — and every later read follows that tab. Every other
    /// combination is exactly what `resolveProfileScoped` returns: the flag is a no-op without a
    /// URL-matching flag (`document-targeting`), and with `--profile` the profile-scoped
    /// resolution already carries it. `warnWriter` receives the multi-match warning.
    func resolveFirstMatchOnce(
        warnWriter: @escaping (String) -> Void = TargetOptions.stderrWarnWriter
    ) async throws -> SafariBridge.TargetDocument {
        let named = resolve()
        if firstMatch, profile == nil, case .urlMatch = named {
            return try await SafariBridge.resolveToConcreteTarget(
                named, firstMatch: true, warnWriter: warnWriter, profile: nil)
        }
        return try await resolveProfileScoped(warnWriter: warnWriter)
    }

    /// Convenience wrapper that bundles the resolved `TargetDocument`
    /// with the `firstMatch` opt-in flag and a stderr-backed
    /// `warnWriter`. Commands should prefer this over `resolve()` when
    /// calling bridge APIs that accept `firstMatch` / `warnWriter`
    /// parameters (read-path entry points such as `doJavaScript`,
    /// `getCurrentURL`, `getCurrentTitle`, …), so the `--first-match`
    /// CLI intent propagates through every target-resolving call site
    /// without per-command boilerplate.
    ///
    /// The default warnWriter writes a single UTF-8 encoded message to
    /// stderr per invocation, which matches the contract tested in
    /// `FirstMatchTests` and `ResolveNativeTargetPlumbingTests`.
    func resolveWithFirstMatch() -> (
        target: SafariBridge.TargetDocument,
        firstMatch: Bool,
        warnWriter: (String) -> Void
    ) {
        (
            resolve(),
            firstMatch,
            { msg in FileHandle.standardError.write(Data(msg.utf8)) }
        )
    }

    /// Sibling accessor for the `--profile` CLI flag (Issue #47).
    /// Returns the parsed profile string, or `nil` when the user did
    /// not pass `--profile`. Kept separate from `resolveWithFirstMatch()`
    /// so adding profile filtering doesn't churn the existing 38
    /// command call sites that destructure the 3-tuple — Step 5 of the
    /// plan plumbs `targetOptions.resolveProfile()` through alongside
    /// the existing tuple call.
    func resolveProfile() -> String? {
        profile
    }

    /// Documentation-only listing of commands whose `--profile` flag
    /// is fully honored at the SafariBridge boundary (Issue #54).
    /// Substituted into the `--profile` `@Option` discussion so users
    /// reading `--help` see explicitly which commands enforce the
    /// filter and which ones are still pending rollout via #51.
    ///
    /// **Maintenance contract**: when a new command plumbs `--profile`
    /// through (closing part of #51), add it to this string AND drop
    /// the matching `target.warnIfProfileUnsupported(...)` call from
    /// that command's `run()`. The two are mirrored — the warning
    /// helper exists for commands NOT in this list.
    static let honoredProfileCommandsHelp = "js, get url, get title, get source, get value, get attr, get count, get box, screenshot, documents, click, fill, type, press, select, hover, dblclick, drag, focus, scroll, scrollintoview, highlight, check, uncheck, is visible, is exists, is enabled, is checked, errors, console, cookies get, cookies set, cookies clear, storage local get, storage local set, storage local remove, storage local clear, storage session get, storage session set, storage session remove, storage session clear, back, forward, reload, set media, close, mouse move, mouse down, mouse up, mouse wheel, pdf, snapshot, tabs, tab switch, tab is-marked, tab unmark, find, wait, exec, get text, get html, save-image, save-pdf, upload, open"

    /// Emit a stderr warning when `--profile` was passed but the
    /// invoking command does not yet honor the filter at the
    /// SafariBridge boundary (Issue #54). Silent no-op when
    /// `--profile` was not supplied — the warning is purely
    /// informational about the parse-vs-enforce gap, not a validation
    /// failure.
    ///
    /// Pure dispatch through `warnWriter` so the call site in
    /// `<Command>.run()` doesn't need to know about FileHandle
    /// plumbing, and so unit tests can capture the message without
    /// touching stderr.
    ///
    /// `commandName` is supplied by the caller as a string literal
    /// (not auto-derived from `Self.configuration.commandName`) so
    /// nested subcommands like `get text` can pass the user-facing
    /// two-word name — `Self.configuration.commandName` would only
    /// return the leaf "text" and produce a confusing warning.
    ///
    /// #62: when used inside `exec`, a parent `exec --profile A` and a
    /// sub-step carrying its own `--profile B` each warn (two lines total).
    /// This is by design — the sub-step `--profile` is a distinct override
    /// (it rides as its own target per #60), so the dual warning is more
    /// informative, not a bug. A sub-step without `--profile` inherits the
    /// parent's profile and warns only at the parent.
    ///
    /// - Parameters:
    ///   - commandName: User-facing command name (e.g. "click",
    ///     "get text") embedded into the warning text.
    ///   - warnWriter: Stderr-bound writer; defaults to
    ///     `Self.stderrWarnWriter`. Tests inject a capturing closure.
    func warnIfProfileUnsupported(
        commandName: String,
        warnWriter: ((String) -> Void)? = nil
    ) {
        // #61: stay silent for empty --profile too (validate() rejects it,
        // but guard here as well so the helper is robust if called directly).
        guard let profile = profile, !profile.isEmpty else { return }
        let writer = warnWriter ?? Self.stderrWarnWriter
        let msg = "warning: --profile '\(profile)' is parsed but not yet enforced for '\(commandName)'. Tracked in #51.\n"
            + "  → Falling back: all profiles considered.\n"
        writer(msg)
    }
}
