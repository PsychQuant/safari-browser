import ArgumentParser
import Foundation

struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for a duration, URL pattern, or JS condition"
    )

    @Argument(help: "Milliseconds to wait (when no --for-url or --js is used)")
    var milliseconds: Int?

    // #23: renamed from --url to --for-url. The old `--url` now belongs to
    // TargetOptions and means "target the document whose URL contains <x>",
    // not "wait until the URL contains <x>". Breaking change — see CHANGELOG.
    @Option(name: .long, help: "Wait until the URL contains this pattern")
    var forUrl: String?

    @Option(name: .long, help: "Wait until this JS expression is truthy")
    var js: String?

    @Option(name: .long, help: "Timeout in milliseconds (default: 30000)")
    var timeout: Int = 30000

    // #182: randomized wait. One duration is drawn from a Cauchy distribution
    // doubly truncated to [--min, --max]; --median is the median of the
    // truncated distribution. See TruncatedCauchy for why this truncates
    // instead of clamping.
    @Option(name: .long, help: "Wait for a randomized duration drawn from this distribution (supported: cauchy). --max is the only cap; --timeout does not apply")
    var jitter: JitterDistribution?

    @Option(name: .customLong("min"), help: "Jitter lower bound in milliseconds (default: 2000)")
    var jitterMin: Double?

    @Option(name: .customLong("max"), help: "Jitter upper bound in milliseconds (default: 60000)")
    var jitterMax: Double?

    @Option(name: .customLong("median"), help: "Median of the truncated jitter distribution in milliseconds (default: 3000)")
    var jitterMedian: Double?

    @Option(name: .customLong("scale"), help: "Cauchy scale in milliseconds (default: 0.8 × the distance from --median to the nearer bound; 800 for the default bounds)")
    var jitterScale: Double?

    // #186: a typo such as --max 600000000 (about a week) would otherwise be
    // accepted, and the heavy tail makes a long draw a matter of time.
    @Flag(name: .customLong("allow-long-wait"), help: "Allow a jitter --max above one hour (3600000 ms)")
    var allowLongWait = false

    /// The largest `--max` accepted without `--allow-long-wait`.
    static let longJitterMaxMilliseconds = 3_600_000.0

    // #182 verify R1: every `wait` is its own process, so a seed cannot carry a
    // sequence across calls — the same seed always yields the same single draw.
    // Using it between steps of a script reinstates a fixed interval, which is
    // exactly what --jitter exists to remove. Testing and debugging only.
    @Option(name: .long, help: "Testing only: fixes this call's draw. The same seed always gives the same delay, so do not use it to pace a script")
    var seed: UInt64?

    @OptionGroup var target: TargetOptions

    enum JitterDistribution: String, ExpressibleByArgument, CaseIterable {
        case cauchy
    }

    /// The truncated distribution described by the jitter options, with defaults filled in.
    func jitterDistribution() throws -> TruncatedCauchy {
        try TruncatedCauchy(
            min: jitterMin ?? TruncatedCauchy.defaultMin,
            max: jitterMax ?? TruncatedCauchy.defaultMax,
            median: jitterMedian ?? TruncatedCauchy.defaultMedian,
            scale: jitterScale
        )
    }

    private var hasJitterParameter: Bool {
        jitterMin != nil || jitterMax != nil || jitterMedian != nil || jitterScale != nil || seed != nil || allowLongWait
    }

    private func validateJitter() throws {
        guard jitter != nil else {
            if hasJitterParameter {
                throw ValidationError("--min, --max, --median, --scale, --seed and --allow-long-wait require --jitter cauchy")
            }
            return
        }
        if milliseconds != nil || forUrl != nil || js != nil {
            throw ValidationError("--jitter cannot be combined with positional milliseconds, --for-url, or --js")
        }
        let distribution = try jitterDistribution()
        _ = try JitterNanosecondRange(min: distribution.min, max: distribution.max)
        // After the representability check: an unrepresentable --max is an
        // error whatever the flags; a long one only needs an explicit opt-in.
        if distribution.max > Self.longJitterMaxMilliseconds && !allowLongWait {
            throw ValidationError(
                "--max \(Int(distribution.max.rounded(.up))) ms is over one hour; a single jittered wait can last "
                    + "that long. Pass --allow-long-wait if that is intended"
            )
        }
    }

    func validate() throws {
        try validateJitter()
        if milliseconds == nil && forUrl == nil && js == nil && jitter == nil {
            // #23 verify R1 finding: detect the rename trap. Users running
            // old `wait --url <pattern>` syntax parse --url as a targeting
            // flag (not a wait predicate) and hit this validate() with a
            // cryptic "Provide milliseconds..." error. If target.url is
            // the ONLY thing they set, they almost certainly meant the old
            // wait-for-URL semantic — point them at --for-url explicitly.
            if target.url != nil && target.window == nil && target.tab == nil && target.document == nil {
                throw ValidationError(
                    "`wait --url <pattern>` was renamed to `wait --for-url <pattern>` in #23 — `--url` is now a global targeting flag. Retry as `safari-browser wait --for-url \"\(target.url!)\"` (see CHANGELOG)."
                )
            }
            throw ValidationError("Provide milliseconds, --for-url, --js, or --jitter cauchy")
        }
    }

    static func nanoseconds(forMilliseconds milliseconds: Int) throws -> UInt64 {
        guard milliseconds >= 0 else {
            throw ValidationError("Milliseconds must be non-negative, got \(milliseconds)")
        }
        let converted = UInt64(milliseconds).multipliedReportingOverflow(by: 1_000_000)
        guard !converted.overflow else {
            throw ValidationError("Milliseconds exceed the maximum representable wait of \(UInt64.max / 1_000_000), got \(milliseconds)")
        }
        return converted.partialValue
    }

    /// Quantizes continuous milliseconds to the nearest *interior* clock tick.
    /// It never changes the sampler's continuous draw or admits an endpoint.
    struct JitterNanosecondRange {
        let minMilliseconds: Double
        let maxMilliseconds: Double
        let lower: UInt64
        let upper: UInt64

        init(min: Double, max: Double) throws {
            guard min.isFinite, max.isFinite, min >= 0, min < max else {
                throw ValidationError("Jitter bounds must be finite and satisfy 0 <= min < max")
            }
            // Preserve the existing #153 whole-millisecond upper-bound guard.
            let ceiling = max.rounded(.up)
            guard ceiling < Double(Int.max), let whole = Int(exactly: ceiling) else {
                throw ValidationError("--max \(max) exceeds the maximum representable wait")
            }
            _ = try WaitCommand.nanoseconds(forMilliseconds: whole)
            let minimum = try Self.parts(min)
            let maximum = try Self.parts(max)
            let first = minimum.floor.addingReportingOverflow(1)
            let last = maximum.ceil.subtractingReportingOverflow(1)
            guard !first.overflow, !last.overflow, first.partialValue < last.partialValue else {
                throw ValidationError("Jitter bounds must contain at least two integer nanosecond durations strictly inside (min, max)")
            }
            minMilliseconds = min
            maxMilliseconds = max
            lower = first.partialValue
            upper = last.partialValue
        }

        func nanoseconds(for milliseconds: Double) throws -> UInt64 {
            guard milliseconds.isFinite, milliseconds > minMilliseconds, milliseconds < maxMilliseconds else {
                throw ValidationError("Jitter draw must be finite and strictly inside (min, max)")
            }
            let rounded = try Self.parts(milliseconds).nearest
            // Only clock quantization is restricted to the legal ticks. No
            // out-of-bounds Cauchy draw is silently clamped to a configured bound.
            return Swift.min(upper, Swift.max(lower, rounded))
        }

        private static func parts(_ milliseconds: Double) throws -> (floor: UInt64, ceil: UInt64, nearest: UInt64) {
            guard milliseconds.isFinite, milliseconds >= 0,
                  let whole = UInt64(exactly: milliseconds.rounded(.down)) else {
                throw ValidationError("Jitter duration cannot be represented in nanoseconds")
            }
            let base = whole.multipliedReportingOverflow(by: 1_000_000)
            guard !base.overflow else {
                throw ValidationError("Jitter duration exceeds the maximum representable wait")
            }
            // Multiplying the complete Double would lose low integer bits for
            // large waits. Split first; the fractional product is at most 1e6.
            let fraction = milliseconds - Double(whole)
            let product = fraction * 1_000_000
            // Fused multiply-add recovers the product's rounding error. This
            // distinguishes a true integer/half tick from a rounded one, even
            // immediately beside a bound (e.g. (1 / 128).nextDown milliseconds).
            let error = (-product).addingProduct(fraction, 1_000_000)
            let floorProduct = product.rounded(.down)
            var floor = floorProduct
            var ceil = product.rounded(.up)
            var nearest = product.rounded(.toNearestOrAwayFromZero)
            if product == floorProduct {
                if error < 0 { floor -= 1 }
                if error > 0 { ceil += 1 }
            } else if product - floorProduct == 0.5, error < 0 {
                nearest = floorProduct
            }
            func combined(_ offset: Double) throws -> UInt64 {
                guard let integer = UInt64(exactly: offset) else {
                    throw ValidationError("Jitter duration cannot be represented in nanoseconds")
                }
                let sum = base.partialValue.addingReportingOverflow(integer)
                guard !sum.overflow else {
                    throw ValidationError("Jitter duration exceeds the maximum representable wait")
                }
                return sum.partialValue
            }
            return try (combined(floor), combined(ceil), combined(nearest))
        }
    }

    /// The single jitter duration this invocation sleeps for, in milliseconds.
    func drawJitterMilliseconds() throws -> Double {
        try drawJitterMilliseconds(from: jitterDistribution())
    }

    private func drawJitterMilliseconds(from distribution: TruncatedCauchy) throws -> Double {
        if let seed {
            var generator = SplitMix64(seed: seed)
            return try distribution.sample(using: &generator)
        }
        var generator = SystemRandomNumberGenerator()
        return try distribution.sample(using: &generator)
    }

    func run() async throws {
        try await run(sleep: { try await Task.sleep(nanoseconds: $0) })
    }

    /// Keep the real sleep argument observable without relying on scheduler timing.
    func run(sleep: (UInt64) async throws -> Void) async throws {
        if jitter != nil {
            let distribution = try jitterDistribution()
            let range = try JitterNanosecondRange(min: distribution.min, max: distribution.max)
            if let warning = distribution.nearlyFixedWarning {
                FileHandle.standardError.write(Data((warning + "\n").utf8))
            }
            let drawn = try drawJitterMilliseconds(from: distribution)
            try await sleep(range.nanoseconds(for: drawn))
        } else if let forUrl {
            try await waitForURL(pattern: forUrl)
        } else if let js {
            try await waitForJS(expression: js)
        } else if let milliseconds {
            let duration = try Self.nanoseconds(forMilliseconds: milliseconds)
            try await sleep(duration)
        }
    }

    /// #168: resolve the target once, before the first poll. Re-resolving on
    /// every 500 ms poll cost one full window/tab enumeration per poll for a
    /// `--url` target, and it defeated the command's purpose: waiting for a
    /// navigation away from the URL the target was named by failed on the next
    /// poll, because the old URL no longer matched anything. Anchored the same
    /// way `js` is (#180): a `--url` / `--document` target is pinned to its tab
    /// by window id, and the default target / `--window N` to the window's
    /// current tab. The deadline starts before resolution, so resolution stays
    /// inside the caller's timeout. The multi-match warning (#59) fires once,
    /// at this single resolution.
    private func resolveOnce() async throws -> (
        original: SafariBridge.TargetDocument, anchored: SafariBridge.TargetDocument, firstMatch: Bool
    ) {
        let (initial, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        let anchored = try await SafariBridge.resolveToAnchoredTarget(
            initial, firstMatch: firstMatch, warnWriter: warnWriter, profile: target.resolveProfile())
        return (initial, anchored, firstMatch)
    }

    private func waitForURL(pattern: String) async throws {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000.0)
        let (original, anchored, firstMatch) = try await resolveOnce()
        // #168 verify R1: `getCurrentURL` on a bare `tab T of window id W` had
        // no identity check. A `--url` / `--document` target is now followed
        // through its whole window's URL list (one Apple event per poll); the
        // anchored current tab is read with the current-tab check.
        var windowAnchor: (windowID: Int, anchor: WaitURLAnchor)?
        if case .resolvedTab(let windowID, let tab, let matcher, _) = anchored {
            windowAnchor = (windowID, WaitURLAnchor(tab: tab, matcher: matcher))
        }
        try await pollUntilDeadline(deadline) {
            do {
                if var tracked = windowAnchor {
                    let urls = try await SafariBridge.tabURLs(windowID: tracked.windowID)
                    defer { windowAnchor = tracked }
                    return try tracked.anchor.url(in: urls).contains(pattern)
                }
                return try await SafariBridge.getCurrentURL(
                    target: anchored, firstMatch: firstMatch, warnWriter: nil,
                    profile: target.resolveProfile()).contains(pattern)
            } catch is WaitURLAnchor.Changed {
                throw SafariBrowserError.anchoredTargetChanged(target: Self.describe(original, anchored))
            } catch let error as SafariBrowserError {
                if windowAnchor != nil, SafariBridge.isTargetDangleError(error) {
                    throw SafariBrowserError.anchoredTargetChanged(target: Self.describe(original, anchored))
                }
                throw JSCommand.anchoredFailure(error, original: original, anchored: anchored)
            }
        }
    }

    /// Polls every 500 ms until `satisfied` returns true or the deadline
    /// passes. The first poll always runs: the deadline starts before target
    /// resolution, and a resolution that used up the timeout must not turn a
    /// condition that already holds into a timeout (#168 verify R1).
    private func pollUntilDeadline(_ deadline: Date, _ satisfied: () async throws -> Bool) async throws {
        var first = true
        while first || Date() < deadline {
            first = false
            if try await satisfied() { return }
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms polling
        }
        throw SafariBrowserError.timeout(seconds: timeout / 1000)
    }

    /// The target as the user named it, for a target-changed error.
    private static func describe(_ original: SafariBridge.TargetDocument, _ anchored: SafariBridge.TargetDocument) -> String {
        let position: String
        if case .resolvedTab(let windowID, let tab, _, _) = anchored {
            position = "window id \(windowID) tab \(tab) at command start"
        } else {
            position = "its position at command start"
        }
        switch original {
        case .urlMatch(let matcher): return "the tab matching \(matcher.description) (\(position))"
        case .documentIndex(let n): return "document \(n) (\(position))"
        case .windowTab(let w, let t): return "window \(w) tab \(t) (\(position))"
        default: return "the target tab (\(position))"
        }
    }

    private func waitForJS(expression: String) async throws {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000.0)
        let (original, anchored, firstMatch) = try await resolveOnce()
        try await pollUntilDeadline(deadline) {
            let result: String
            do {
                result = try await SafariBridge.doJavaScript(
                    "!!(\(expression)) ? 'true' : ''",
                    target: anchored, firstMatch: firstMatch, warnWriter: nil,
                    profile: target.resolveProfile())
            } catch let error as SafariBrowserError {
                throw JSCommand.anchoredFailure(error, original: original, anchored: anchored)
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }
    }
}

/// #168 verify R1: which tab a `wait --for-url` on a `--url`, `--document` or
/// `--window N --tab-in-window M` target reads, poll after poll. Safari has no
/// tab id, so identity is inferred from what one whole-window URL read shows:
///
/// - While the tab still shows a URL its original matcher accepts, it is the
///   target, wherever other tabs open.
/// - When it stops matching and the window's tab count is unchanged since the
///   last poll, the tab navigated — the event being waited for — and it is
///   followed by position from then on.
/// - When it stops matching while the tab count changed, or once followed by
///   position the count shrinks, or the position runs past the end, the tab
///   may have moved or closed: the wait fails closed.
///
/// A tab opened to the left after the navigation is not detected (#188).
struct WaitURLAnchor {
    struct Changed: Error {}

    private let tab: Int
    private var matcher: SafariBridge.UrlMatcher?
    private var tabCount: Int?

    init(tab: Int, matcher: SafariBridge.UrlMatcher?) {
        self.tab = tab
        self.matcher = matcher
    }

    mutating func url(in urls: [String]) throws -> String {
        defer { tabCount = urls.count }
        guard tab >= 1, tab <= urls.count else { throw Changed() }
        let current = urls[tab - 1]
        if let matcher {
            if matcher.matches(current) { return current }
            if let tabCount, tabCount != urls.count { throw Changed() }
            self.matcher = nil
            return current
        }
        if let tabCount, urls.count < tabCount { throw Changed() }
        return current
    }
}
