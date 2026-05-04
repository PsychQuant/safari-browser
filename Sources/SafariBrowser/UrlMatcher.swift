import Foundation

extension SafariBridge {
    /// Sum-type that encapsulates the URL matching strategy for
    /// `TargetDocument.urlMatch`. All variance in URL matching (substring,
    /// exact equality, suffix, regex) is collapsed into this single type
    /// so `resolveDocumentReference`, `pickNativeTarget`, and
    /// `pickFirstMatchFallback` carry one matcher case instead of four
    /// top-level `TargetDocument` cases (avoids switch-explosion as more
    /// matcher kinds are added).
    ///
    /// The matcher is a **pure** value — `matches(_:)` performs no I/O
    /// and no URL canonicalization. Callers must pass the URL exactly
    /// as Safari returned it via `URL of tab`. Canonicalization concerns
    /// (trailing-slash handling, percent-encoding normalization, host
    /// case folding) are intentionally out of scope per the proposal's
    /// Non-Goals — if such behavior is needed, use `.endsWith` or
    /// `.regex` to express it explicitly.
    ///
    /// Thread safety: `Sendable` via all-value-type payloads except the
    /// `.regex` case which wraps `NSRegularExpression`. `NSRegularExpression`
    /// is documented as thread-safe (no internal state), so the wrapping
    /// is sound; the `@unchecked Sendable` conformance captures this
    /// contract without relying on Foundation's automatic conformance.
    enum UrlMatcher: @unchecked Sendable, Equatable {
        /// Separator that Safari prepends profile names to window titles
        /// with: `<profile> — <title>` (em-dash U+2014 surrounded by
        /// single spaces). Constant so a copy-paste regression replacing
        /// the em-dash with a regular hyphen breaks `parseProfile` tests
        /// immediately rather than silently failing in production.
        /// Verified against Safari 18 (macOS Sequoia 15.x) with 4 distinct
        /// profiles in Issue #47 diagnose.
        static let profileSeparator: String = " \u{2014} "

        /// Pure helper: split a Safari window's `name` property into the
        /// active profile name (if present) and the page title.
        ///
        /// Safari 17+ prepends the profile name to every window title
        /// with `profileSeparator` between them. AppleScript's window
        /// object does **not** expose a `current profile` property
        /// (verified Safari 18, `osascript` returns `-2741` syntax
        /// error), so window-name parsing is the only reliable way to
        /// filter by profile from a CLI.
        ///
        /// First-occurrence split: page titles legitimately contain
        /// em-dashes (e.g. `"Project — Q1"`), so anything after the
        /// first separator stays in the title part. Without a separator
        /// (default profile or pre-multi-profile Safari) the result is
        /// `(nil, name)` — `--profile` filter never matches such
        /// windows, which is the correct behavior.
        ///
        /// - Parameter name: The window's title as returned by
        ///   AppleScript `name of window`.
        /// - Returns: Tuple of `(profile, title)`. `profile` is `nil`
        ///   when no profile separator is present; `title` is everything
        ///   after the first separator (or the entire `name` when no
        ///   separator).
        static func parseProfile(
            fromWindowName name: String
        ) -> (profile: String?, title: String) {
            guard let range = name.range(of: profileSeparator) else {
                return (nil, name)
            }
            let profile = String(name[..<range.lowerBound])
            let title = String(name[range.upperBound...])
            return (profile, title)
        }


        /// Substring match — `.contains("plaud")` matches any URL whose
        /// string contains `plaud`. This is the historical default and
        /// maps from the `--url <substring>` CLI flag.
        case contains(String)

        /// Full string equality — `.exact("https://x/")` matches only
        /// URLs byte-identical to the argument. No canonicalization.
        /// Maps from `--url-exact`.
        case exact(String)

        /// Suffix match — `.endsWith("/play")` matches URLs whose tail
        /// equals the argument. Useful for disambiguating hierarchical
        /// URLs where a parent is a prefix of a child. Maps from
        /// `--url-endswith`.
        case endsWith(String)

        /// Regex match via `NSRegularExpression`. Unanchored by default
        /// (caller may anchor with `^...$` as needed). Maps from
        /// `--url-regex`.
        case regex(NSRegularExpression)

        /// Short human-readable description for error messages
        /// (`documentNotFound` / `ambiguousWindowMatch` use a `pattern`
        /// field that historically held the raw substring; for matcher
        /// variants we surface the kind so the user sees which flag
        /// caused the failure).
        var description: String {
            switch self {
            case .contains(let p): return p
            case .exact(let u): return "\(u) (exact)"
            case .endsWith(let s): return "\(s) (endsWith)"
            case .regex(let r): return "\(r.pattern) (regex)"
            }
        }

        /// Pure predicate: does the given URL string match under this
        /// matcher's semantics?
        func matches(_ url: String) -> Bool {
            switch self {
            case .contains(let pattern):
                return url.contains(pattern)
            case .exact(let expected):
                return url == expected
            case .endsWith(let suffix):
                return url.hasSuffix(suffix)
            case .regex(let regex):
                let range = NSRange(url.startIndex..<url.endIndex, in: url)
                return regex.firstMatch(in: url, options: [], range: range) != nil
            }
        }

        /// Manual `Equatable` — synthesized conformance would compare
        /// `NSRegularExpression` by reference, yielding surprising
        /// results for two regexes compiled from the same pattern.
        /// Compare by pattern + options instead.
        static func == (lhs: UrlMatcher, rhs: UrlMatcher) -> Bool {
            switch (lhs, rhs) {
            case (.contains(let a), .contains(let b)):
                return a == b
            case (.exact(let a), .exact(let b)):
                return a == b
            case (.endsWith(let a), .endsWith(let b)):
                return a == b
            case (.regex(let a), .regex(let b)):
                return a.pattern == b.pattern && a.options == b.options
            default:
                return false
            }
        }
    }
}
