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
        // #182 verify R1: when --scale is huge relative to the interval, both
        // CDF values round to 0.5 and quantile() multiplies the rounding noise
        // by --scale. The computed truncated median then stops being monotone
        // (the range below inverted and trapped) and F(min) == F(max) (the
        // uniform draw trapped). Measured: strictly monotone at every tested
        // interval width and offset up to a ratio of 100, broken at 1000. At a
        // ratio of 100 the truncated distribution is already nearly uniform on
        // [min, max], so nothing useful lies beyond the cap.
        let maxScale = Self.maxScaleToWidthRatio * (max - min)
        guard scale <= maxScale else {
            throw ValidationError(
                "--scale \(scale) is too large for [\(min), \(max)]; it must be at most "
                    + "\(Int(Self.maxScaleToWidthRatio)) × (--max − --min) = \(Self.format(maxScale))"
            )
        }
        let lowMedian = Self.truncatedMedian(location: min, scale: scale, min: min, max: max)
        let highMedian = Self.truncatedMedian(location: max, scale: scale, min: min, max: max)
        guard lowMedian.isFinite, highMedian.isFinite, lowMedian < highMedian else {
            throw ValidationError("Jitter parameters are numerically degenerate for [\(min), \(max)] with --scale \(scale)")
        }
        guard (lowMedian...highMedian).contains(median) else {
            throw ValidationError(
                "--median \(median) is not achievable with --scale \(scale) on [\(min), \(max)]; "
                    + "achievable medians are \(Self.inwardRange(lowMedian, highMedian, width: max - min)). "
                    + "Lower --scale or move --median into that range."
            )
        }
        let location = Self.solveLocation(median: median, scale: scale, min: min, max: max)
        // Verify the solve instead of trusting it: bisection converges on
        // whatever the arithmetic says, and the arithmetic is what failed in R1.
        // The tolerance is relative to the interval width, not to the median:
        // at a large offset a median-relative tolerance can exceed the whole
        // interval and accept anything (#182 verify R2). The ulp floor keeps a
        // width near the Double resolution from demanding the impossible.
        let solved = Self.truncatedMedian(location: location, scale: scale, min: min, max: max)
        let tolerance = Swift.max(1e-6 * (max - min), 4 * median.ulp)
        guard solved > min, solved < max, abs(solved - median) <= tolerance else {
            throw ValidationError("Could not solve the jitter location precisely for --median \(median) with --scale \(scale)")
        }
        let cdfLower = Self.cdf(min, location: location, scale: scale)
        let cdfUpper = Self.cdf(max, location: location, scale: scale)
        guard cdfUpper > cdfLower else {
            throw ValidationError("Jitter parameters are numerically degenerate for [\(min), \(max)] with --scale \(scale)")
        }
        self.min = min
        self.max = max
        self.median = median
        self.scale = scale
        self.location = location
        self.cdfLower = cdfLower
        self.cdfUpper = cdfUpper
        self.solvedMedian = solved
    }

    /// `--scale` may be at most this multiple of `max − min`; see `init`.
    static let maxScaleToWidthRatio = 100.0

    private let cdfLower: Double
    private let cdfUpper: Double
    /// The truncated median at `location`, verified in `init` to lie strictly inside the bounds.
    private let solvedMedian: Double

    /// Draws one duration in milliseconds, strictly inside `(min, max)`.
    ///
    /// Inverse-CDF sampling: `u ~ U(F(min), F(max))`, `x = F⁻¹(u)`. One uniform draw
    /// per call, so the cost does not grow as the interval narrows (rejection
    /// sampling would).
    ///
    /// The uniform is built from the generator's raw 53 high bits rather than
    /// `Double.random(in:using:)`, whose algorithm the standard library does not
    /// promise to keep stable — a seeded draw must be the same on every toolchain.
    func sample<G: RandomNumberGenerator>(using generator: inout G) -> Double {
        let width = cdfUpper - cdfLower
        // Floating-point rounding near u == F(min) can land exactly on (or a hair
        // outside) a bound. init() guarantees a non-empty CDF interval, so such
        // draws are rare; the cap only makes termination unconditional.
        for _ in 0..<64 {
            let unit = Double(generator.next() >> 11) * 0x1p-53
            let x = Self.quantile(cdfLower + width * unit, location: location, scale: scale)
            if x > min && x < max { return x }
        }
        // Unreachable in practice. Return the truncated median computed in init(),
        // which init() verified lies strictly inside the bounds — the very value,
        // not a recomputation that could round differently.
        return solvedMedian
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
    /// Restricted to `[min, max]` it is monotone in exact arithmetic, and its
    /// global extremes occur at the endpoints, so this range is the set of
    /// achievable medians.
    ///
    /// In floating point that holds only while `scale` is at most
    /// `maxScaleToWidthRatio × (max − min)`; beyond it the computed endpoints can
    /// invert (#182 verify R1). The bounds are ordered here so an inverted pair
    /// cannot trap; `init` rejects such parameters before relying on the range.
    static func achievableMedianRange(scale: Double, min: Double, max: Double) -> ClosedRange<Double> {
        let a = truncatedMedian(location: min, scale: scale, min: min, max: max)
        let b = truncatedMedian(location: max, scale: scale, min: min, max: max)
        return Swift.min(a, b)...Swift.max(a, b)
    }

    /// Bisection on `[min, max]`, where the truncated median is monotone increasing
    /// under the scale cap enforced by `init`.
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

    /// Formats an achievable range rounded INWARD — the lower bound up, the upper
    /// bound down — so a user who copies either printed endpoint gets a median
    /// that is actually accepted. Plain rounding printed 55412.5 for a true bound
    /// of 55412.4898, which is then rejected (#182 verify R2). Narrow intervals
    /// get more decimals until the rounded range is still non-empty.
    static func inwardRange(_ low: Double, _ high: Double, width: Double) -> String {
        var decimals = width < 10 ? 4 : 1
        while decimals <= 9 {
            let factor = pow(10.0, Double(decimals))
            let roundedLow = (low * factor).rounded(.up) / factor
            let roundedHigh = (high * factor).rounded(.down) / factor
            if roundedLow <= roundedHigh {
                return String(format: "%.\(decimals)f...%.\(decimals)f", roundedLow, roundedHigh)
            }
            decimals += 1
        }
        return "\(low)...\(high)"
    }
}

/// Deterministic generator for `wait --seed` (SplitMix64). Not cryptographic.
/// It makes draws reproducible in tests; at the CLI each `wait` seeds a fresh
/// generator, so a seed fixes that call's single draw.
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
