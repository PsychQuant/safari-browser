import Foundation

/// Catalog of AppleScript source blocks that the daemon pre-compiles into
/// `NSAppleScript` objects and holds in memory, up to `CompileCache`'s bound
/// (256 sources, least recently used evicted; #170). This is the main latency
/// win of the persistent-daemon change: a warm request path reuses the
/// already-compiled handle instead of spawning a fresh `osascript`
/// subprocess.
///
/// Task 3.1 scope (infrastructure + seed templates):
///
/// - `Template.parse(...)` extracts `{{placeholder}}` tokens from source.
/// - `render(template:params:)` substitutes placeholders; missing params
///   throw `.missingPlaceholder` so callers fail loudly instead of leaving
///   a raw `{{TOKEN}}` in the AppleScript.
/// - `CompileCache` compiles on miss on the main actor and caches by source
///   string, at most 256 of them. Identical rendered sources reuse the same
///   handle.
/// - `known` registers three Phase 1 seed templates (`activateWindow`,
///   `enumerateWindows`, `runJSInCurrentTab`); the remaining 4–7 templates
///   mentioned in design.md will be ported from `SafariBridge.swift` in
///   task 7.1 where the routing lands.
///
/// Actual Safari-side execution of these compiled handles happens in the
/// daemon dispatch layer (task 4.1) and in routing (task 7.1).
enum PreCompiledScripts {

    enum Error: Swift.Error, CustomStringConvertible {
        case missingPlaceholder(String)
        case compilationFailed(String)
        case executionFailed(String)

        var description: String {
            switch self {
            case .missingPlaceholder(let n): return "missing placeholder: {{\(n)}}"
            case .compilationFailed(let m):  return "AppleScript compile failed: \(m)"
            case .executionFailed(let m):    return "AppleScript execute failed: \(m)"
            }
        }
    }

    /// A template whose source contains literal `{{NAME}}` tokens that are
    /// replaced with caller-supplied parameter values at render time.
    struct Template: Sendable, Equatable {
        let name: String
        let source: String
        let placeholders: Set<String>

        /// Parse the source to derive placeholder names. Tokens look like
        /// `{{NAME}}` and must contain only ASCII letters, digits, or `_`.
        static func parse(name: String, source: String) -> Template {
            var found: Set<String> = []
            // Match {{IDENTIFIER}}
            let pattern = #"\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}"#
            let regex = try? NSRegularExpression(pattern: pattern)
            let nsSource = source as NSString
            regex?.enumerateMatches(
                in: source,
                range: NSRange(location: 0, length: nsSource.length)
            ) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let name = nsSource.substring(with: match.range(at: 1))
                found.insert(name)
            }
            return Template(name: name, source: source, placeholders: found)
        }
    }

    /// Phase 1 seed templates. Additional entries (e.g. `getTabUrl`,
    /// `setCurrentTab`, `dispatchMouseEvent`, `dispatchKeyEvent`) land in
    /// task 7.1 where the corresponding command paths switch to the
    /// daemon-routed code path.
    static let known: [String: Template] = [
        "activateWindow": Template.parse(
            name: "activateWindow",
            source: """
                tell application "Safari"
                    set index of window {{WINDOW_INDEX}} to 1
                    activate
                end tell
                """
        ),
        "enumerateWindows": Template.parse(
            name: "enumerateWindows",
            // Walks every Safari window and emits "wN|tM|URL|TITLE" lines.
            // Mirrors the shape produced by `SafariBridge.listAllWindows()`
            // so the daemon path can be plugged in without changing
            // downstream parsing.
            source: """
                tell application "Safari"
                    set output to ""
                    set winCount to count of windows
                    repeat with w from 1 to winCount
                        set theWindow to window w
                        try
                            set tabCount to count of tabs of theWindow
                            repeat with t from 1 to tabCount
                                set theTab to tab t of theWindow
                                set output to output & "w" & w & "|t" & t & "|" & (URL of theTab) & "|" & (name of theTab) & linefeed
                            end repeat
                        end try
                    end repeat
                    return output
                end tell
                """
        ),
        "runJSInCurrentTab": Template.parse(
            name: "runJSInCurrentTab",
            // Caller-supplied JS source is injected as a single-line
            // AppleScript string literal. The caller is responsible for
            // escaping embedded quotes / backslashes before rendering —
            // see `String.escapedForAppleScript` in `SafariBridge.swift`.
            //
            // #87: a 0-tab front window has no `current tab`; the bare
            // `do JavaScript ... in current tab of front window` would raise
            // a raw -1728. Guard with an explicit, actionable error first.
            // The zero-windows guard MUST come first — with no windows,
            // `front window` itself doesn't exist, so `count of tabs of
            // front window` would raise the same raw -1728 (#88 verify M1).
            source: """
                tell application "Safari"
                    if (count of windows) = 0 then
                        error "Safari has no windows — open a window or target a specific window/url"
                    end if
                    if (count of tabs of front window) = 0 then
                        error "front window has no tabs — open a tab or target a specific window/url"
                    end if
                    do JavaScript "{{JS_SOURCE}}" in current tab of front window
                end tell
                """
        ),
        // #37 Batch 2 (task 7.1) — read-path templates for Phase 1
        // `get url` / `get title` / `get text` / `get source` commands.
        // `{{DOC_REF}}` is pre-rendered by the caller via
        // `SafariBridge.resolveDocumentReference` / `resolveToAppleScript`;
        // it already passes through `escapedForAppleScript` for any user
        // substring content, so substitution is safe.
        "getDocumentURL": Template.parse(
            name: "getDocumentURL",
            source: """
                tell application "Safari"
                    get URL of {{DOC_REF}}
                end tell
                """
        ),
        "getDocumentTitle": Template.parse(
            name: "getDocumentTitle",
            source: """
                tell application "Safari"
                    get name of {{DOC_REF}}
                end tell
                """
        ),
        "getDocumentText": Template.parse(
            name: "getDocumentText",
            source: """
                tell application "Safari"
                    get text of {{DOC_REF}}
                end tell
                """
        ),
        "getDocumentSource": Template.parse(
            name: "getDocumentSource",
            source: """
                tell application "Safari"
                    get source of {{DOC_REF}}
                end tell
                """
        ),
    ]

    /// Substitute every `{{NAME}}` token in `template.source` with the matching
    /// value from `params`. Throws `.missingPlaceholder` if a token declared
    /// in `template.placeholders` is absent from `params`. Extra entries in
    /// `params` are silently ignored.
    static func render(template: Template, params: [String: String]) throws -> String {
        var out = template.source
        for placeholder in template.placeholders {
            guard let value = params[placeholder] else {
                throw Error.missingPlaceholder(placeholder)
            }
            out = out.replacingOccurrences(of: "{{\(placeholder)}}", with: value)
        }
        return out
    }

    /// Sendable snapshot of a descriptor's common primitive extractions.
    /// Callers use this instead of the raw `NSAppleEventDescriptor` so the
    /// value can cross the `CompileCache` actor boundary under Swift 6
    /// strict concurrency.
    struct ExecutionResult: Sendable, Equatable {
        let int32Value: Int32
        let stringValue: String?

        init(descriptor: NSAppleEventDescriptor) {
            self.int32Value = descriptor.int32Value
            self.stringValue = descriptor.stringValue
        }
    }

    /// Main-thread cache of `NSAppleScript` compilations keyed by rendered source.
    /// A regular actor serializes access but may execute on a worker thread:
    /// even `return 42` followed by `delay 0.3` can then hang (#130). Keep
    /// creation, compilation, and execution on the main actor together.
    /// Safe for concurrent use from multiple tasks. Cached script instances
    /// never cross the isolation boundary — callers interact through
    /// `execute(source:)` which returns a `Sendable` `ExecutionResult`, or
    /// through the introspection accessors `cacheCount` / `contains(source:)`.
    @MainActor final class CompileCache {
        /// #170: sources embed window ids, tab indices and JavaScript text,
        /// so distinct sources are unbounded; a long-lived daemon kept every
        /// one. The least recently used handle is evicted past this capacity.
        nonisolated static let defaultCapacity = 256

        private struct Entry {
            let script: NSAppleScript
            var lastUse: UInt64
        }
        private let capacity: Int
        /// Keyed by the source's UTF-8 bytes: `String` equality treats canonically equivalent text
        /// (an NFC and an NFD spelling of the same literal) as equal, and the cache would then run one
        /// request's compiled script for another's, though NSAppleScript tells the two apart.
        private var cache: [[UInt8]: Entry] = [:]
        private var useClock: UInt64 = 0

        // No NSAppleScript work occurs until an isolated method is called.
        nonisolated init(capacity: Int = CompileCache.defaultCapacity) {
            self.capacity = max(1, capacity)
        }

        /// Ensure `source` is compiled and cached. Idempotent: repeated calls
        /// with the same source string re-use the cached `NSAppleScript`.
        /// Throws `.compilationFailed` if AppleScript rejects the source.
        func compile(source: String) throws {
            _ = try compiledLocked(for: source)
        }

        /// Compile (cached) and execute the script, returning a Sendable
        /// snapshot of the result descriptor.
        func execute(source: String) throws -> ExecutionResult {
            let script = try compiledLocked(for: source)
            return try PerformanceTrace.span(.daemonExecute) {
                var errorInfo: NSDictionary?
                let descriptor = script.executeAndReturnError(&errorInfo)
                if let info = errorInfo {
                    throw Error.executionFailed(Self.describe(info))
                }
                return ExecutionResult(descriptor: descriptor)
            }
        }

        /// The error text `osascript` would print: the message, then the
        /// AppleScript error number in parentheses (#218). NSAppleScript keeps
        /// the number in a separate key and localizes the message, so without
        /// it `isTargetDangleError` and the not-found translation cannot
        /// classify a daemon-path error.
        nonisolated static func describe(_ info: NSDictionary) -> String {
            let number = (info["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            guard let message = info["NSAppleScriptErrorMessage"] as? String else {
                return number.map { "AppleScript error (\($0))" } ?? String(describing: info)
            }
            return number.map { "\(message) (\($0))" } ?? message
        }

        /// Number of compiled handles currently cached.
        var cacheCount: Int { cache.count }

        /// Whether a given source string has been compiled and cached.
        func contains(source: String) -> Bool {
            cache[Array(source.utf8)] != nil
        }

        private func evictIfOverCapacity() {
            while cache.count > capacity,
                  let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
                cache.removeValue(forKey: oldest)
            }
        }

        // MARK: - Actor-isolated helpers

        private func compiledLocked(for source: String) throws -> NSAppleScript {
            useClock &+= 1
            let key = Array(source.utf8)
            if var existing = cache[key] {
                existing.lastUse = useClock
                cache[key] = existing
                return PerformanceTrace.span(.daemonCacheHit) { existing.script }
            }
            return try PerformanceTrace.span(.daemonCompile) {
                guard let script = NSAppleScript(source: source) else {
                    throw Error.compilationFailed("NSAppleScript init returned nil")
                }
                var errorInfo: NSDictionary?
                if !script.compileAndReturnError(&errorInfo) {
                    throw Error.compilationFailed(errorInfo.map(Self.describe) ?? "compilation failed")
                }
                cache[key] = Entry(script: script, lastUse: useClock)
                evictIfOverCapacity()
                return script
            }
        }
    }
}
