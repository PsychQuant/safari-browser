import ArgumentParser
import Foundation

/// A Cauchy distribution doubly truncated to `[min, max]` milliseconds (#182).
///
/// Truncation discards the mass outside the interval and renormalizes; it never
/// clamps an out-of-range draw to a bound. Clamping is what the old SKILL.md
/// formula did with `max(2, …)`, and it piled 22.3% of all delays onto exactly
/// 2.0 s — the fixed interval the jitter was meant to avoid.
///
/// `median` is the median of the *truncated* distribution. The location
/// parameter that produces it is solved numerically in `init`.
struct TruncatedCauchy {
    static let defaultMin = 2000.0
    static let defaultMax = 60000.0
    static let defaultMedian = 3000.0
    static let defaultScale = 800.0

    let min: Double
    let max: Double
    let median: Double
    let scale: Double
    /// Location of the untruncated Cauchy whose truncation to `[min, max]` has `median`.
    let location: Double

    init(
        min: Double = defaultMin,
        max: Double = defaultMax,
        median: Double = defaultMedian,
        scale: Double = defaultScale
    ) throws {
        guard min.isFinite, max.isFinite, median.isFinite, scale.isFinite else {
            throw ValidationError("Jitter parameters must be finite numbers")
        }
        guard min >= 0 else {
            throw ValidationError("--min must be non-negative, got \(min)")
        }
        guard min < median, median < max else {
            throw ValidationError("Jitter bounds must satisfy --min < --median < --max, got \(min) < \(median) < \(max)")
        }
        guard scale > 0 else {
            throw ValidationError("--scale must be positive, got \(scale)")
        }
        let achievable = Self.achievableMedianRange(scale: scale, min: min, max: max)
        guard achievable.contains(median) else {
            throw ValidationError(
                "--median \(median) is not achievable with --scale \(scale) on [\(min), \(max)]; "
                    + "achievable medians are \(Self.format(achievable.lowerBound))...\(Self.format(achievable.upperBound)). "
                    + "Lower --scale or move --median into that range."
            )
        }
        self.min = min
        self.max = max
        self.median = median
        self.scale = scale
        self.location = Self.solveLocation(median: median, scale: scale, min: min, max: max)
    }

    /// Draws one duration in milliseconds, strictly inside `(min, max)` in exact arithmetic.
    ///
    /// Inverse-CDF sampling: `u ~ U(F(min), F(max))`, `x = F⁻¹(u)`. One uniform draw
    /// per call, so the cost does not grow as the interval narrows (rejection
    /// sampling would).
    func sample<G: RandomNumberGenerator>(using generator: inout G) -> Double {
        let lower = Self.cdf(min, location: location, scale: scale)
        let upper = Self.cdf(max, location: location, scale: scale)
        while true {
            let u = Double.random(in: lower..<upper, using: &generator)
            let x = Self.quantile(u, location: location, scale: scale)
            // Floating-point rounding at u == lower can land exactly on (or a
            // hair outside) a bound. That event has probability ~2⁻⁵³, so this
            // redraw is not rejection sampling — it only keeps the open-interval
            // guarantee exact.
            if x > min && x < max { return x }
        }
    }

    // MARK: - Distribution functions

    static func cdf(_ x: Double, location: Double, scale: Double) -> Double {
        0.5 + atan((x - location) / scale) / .pi
    }

    static func quantile(_ u: Double, location: Double, scale: Double) -> Double {
        location + scale * tan(.pi * (u - 0.5))
    }

    /// Median of the Cauchy(`location`, `scale`) truncated to `[min, max]`.
    static func truncatedMedian(location: Double, scale: Double, min: Double, max: Double) -> Double {
        let half = (cdf(min, location: location, scale: scale) + cdf(max, location: location, scale: scale)) / 2
        return quantile(half, location: location, scale: scale)
    }

    /// Medians reachable with `location` restricted to `[min, max]`.
    ///
    /// Over the whole real line the truncated median is NOT monotone in the
    /// location: as the location moves far outside the interval the truncated
    /// distribution flattens and its median folds back toward the midpoint.
    /// Restricted to `[min, max]` it is monotone, and its global extremes occur at
    /// the endpoints, so this range is exactly the set of achievable medians.
    static func achievableMedianRange(scale: Double, min: Double, max: Double) -> ClosedRange<Double> {
        truncatedMedian(location: min, scale: scale, min: min, max: max)
            ... truncatedMedian(location: max, scale: scale, min: min, max: max)
    }

    /// Bisection on `[min, max]`, where the truncated median is monotone increasing.
    private static func solveLocation(median: Double, scale: Double, min: Double, max: Double) -> Double {
        var low = min
        var high = max
        for _ in 0..<200 {
            let middle = (low + high) / 2
            if middle == low || middle == high { break }
            if truncatedMedian(location: middle, scale: scale, min: min, max: max) < median {
                low = middle
            } else {
                high = middle
            }
        }
        return (low + high) / 2
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// Deterministic generator for `wait --seed` (SplitMix64). Not cryptographic;
/// it only makes a jittered sequence reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
