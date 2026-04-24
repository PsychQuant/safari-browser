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
/// - `--tab N` (standalone, **deprecated** — alias for `--document`)
/// - `--document N` (standalone)
///
/// Exclusivity rules:
/// 1. `--tab-in-window` SHALL pair with `--window`; solo usage is rejected.
/// 2. `--window` SHALL NOT combine with `--url`, `--tab`, or `--document`.
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
        help: "Target the document of the Nth Safari window (1-indexed). Pair with --tab-in-window to select a specific tab."
    )
    var window: Int?

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
            "Target the Nth tab within --window M (1-indexed). Same-URL escape hatch.",
            discussion: "Requires --window. Example: --window 1 --tab-in-window 2 targets the second tab of window 1, useful when multiple tabs share the same URL."
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

        // Rule 1: --tab-in-window requires --window
        if tabInWindow != nil && window == nil {
            throw ValidationError(
                "--tab-in-window requires --window (e.g. --window 1 --tab-in-window 2)"
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
        if let t = tab, t < 1 {
            throw ValidationError("--tab must be >= 1 (1-indexed), got \(t)")
        }
        if let d = document, d < 1 {
            throw ValidationError("--document must be >= 1 (1-indexed), got \(d)")
        }
        if let m = tabInWindow, m < 1 {
            throw ValidationError("--tab-in-window must be >= 1 (1-indexed), got \(m)")
        }
    }

    /// Convert the parsed flags into a `TargetDocument`. Precedence
    /// (already checked as mutually exclusive by `validate()`):
    /// 1. `--window + --tab-in-window` → `.windowTab(w, m)`
    /// 2. `--url` → `.urlContains`
    /// 3. `--window` only → `.windowIndex`
    /// 4. `--tab` / `--document` → `.documentIndex`
    /// 5. none → `.frontWindow`
    func resolve() -> SafariBridge.TargetDocument {
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

    /// Default warn-writer shared by every command that wires
    /// `--first-match` plumb-through. Writes UTF-8 encoded messages to
    /// stderr so users see which tab was chosen from a multi-match
    /// fallback. Exposed as a static property so inline command call
    /// sites can reference it without constructing a closure each time.
    static let stderrWarnWriter: @Sendable (String) -> Void = { msg in
        FileHandle.standardError.write(Data(msg.utf8))
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
}
