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
/// parameter that produces it is solved on the central branch in `init`.
struct TruncatedCauchy {
    static let defaultMin = 2000.0
    static let defaultMax = 60000.0
    static let defaultMedian = 3000.0
    /// Without `--scale`, the scale is this fraction of the distance from the
    /// median to the nearer bound (#186) — 800 for the default bounds. A scale
    /// no larger than that distance always leaves the median reachable: the
    /// lowest reachable median is below `min + scale`, the highest above
    /// `max − scale`. A fixed 800 made short intervals unreachable.
    static let defaultScaleFraction = 0.8

    static func defaultScale(min: Double, max: Double, median: Double) -> Double {
        defaultScaleFraction * Swift.min(median - min, max - median)
    }

    /// Draws count as nearly fixed when their interquartile range is below
    /// this fraction of the median (#186): `--scale 1` on [1000, 3000] puts
    /// half of all delays within 2 ms of each other — the fixed interval the
    /// jitter exists to remove. The defaults sit at 0.45.
    static let nearlyFixedIQRFraction = 0.05

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
        scale: Double? = nil
    ) throws {
        guard min.isFinite, max.isFinite, median.isFinite else {
            throw ValidationError("Jitter parameters must be finite numbers")
        }
        let scale = scale ?? Self.defaultScale(min: min, max: max, median: median)
        guard scale.isFinite else {
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
        let width = max - min
        let g = scale / width
        let maxScale = Self.maxScaleToWidthRatio * width
        guard g <= Self.maxScaleToWidthRatio else {
            throw ValidationError(
                "--scale \(scale) is too large for [\(min), \(max)]; it must be at most "
                    + "\(Int(Self.maxScaleToWidthRatio)) × (--max − --min) = \(Self.format(maxScale))"
            )
        }
        let p = (median - min) / width
        let q = (max - median) / width
        guard g > 0, p > 0, q > 0, min.nextUp < max else {
            throw ValidationError("Jitter parameters are numerically degenerate")
        }
        let range = Self.achievableMedianRange(scale: scale, min: min, max: max)
        guard range.contains(median) else {
            throw ValidationError(
                "--median \(median) is not achievable with --scale \(scale) on [\(min), \(max)]; "
                    + "achievable medians are \(Self.inwardRange(range.lowerBound, range.upperBound, width: width)). "
                    + "Lower --scale or move --median into that range."
            )
        }
        // In normalized coordinates, y = median - location satisfies
        // (q-p)y² - 2pq*y + (q-p)g² = 0. The central branch uses the
        // rationalized small root, continuous through y=0 at p=q.
        // Dividing in stages avoids underflow in p*q for tiny scales.
        let rawR = ((q - p) * g / p) / q
        // Roundoff in q-p is amplified by g/(p*q), especially near the
        // midpoint with a large scale. Permit its propagated rounding budget
        // at the discriminant, after checking the full attainable range.
        let rTolerance = 16 * Double.ulpOfOne * Swift.max(1, (g / p) / q)
        guard rawR.isFinite, abs(rawR) <= 1 + rTolerance else {
            throw ValidationError("Could not solve the jitter location precisely")
        }
        let r = Swift.max(-1, Swift.min(1, rawR))
        let k = r / (1 + sqrt((1 - r) * (1 + r))) // y / g, within [-1,1]
        let lowerAngle = atan2(g * k - p, g)
        let upperAngle = atan2(q + g * k, g)
        let span = upperAngle - lowerAngle
        // Independent back-substitution in angular CDF space. This does not
        // trust the quadratic root merely because it is finite.
        let solvedProbability = (atan(k) - lowerAngle) / span
        guard span.isFinite, span > 0,
              abs(solvedProbability - 0.5) <= 1e-11 else {
            throw ValidationError("Could not solve the jitter location precisely for --median \(median) with --scale \(scale)")
        }
        // When both central quartiles collapse to the median, Double cannot
        // represent the distribution's central shape. Reject that numerical
        // input rather than lose the central shape in Double arithmetic.
        // This does not guarantee distinct durations after nanosecond quantization.
        let quarterTangent = tan(span / 4)
        let lowerQuartile = median - scale * ((1 + k * k) * quarterTangent / (1 + k * quarterTangent))
        let upperQuartile = median + scale * ((1 + k * k) * quarterTangent / (1 - k * quarterTangent))
        guard lowerQuartile < median, upperQuartile > median else {
            throw ValidationError("Jitter parameters are numerically degenerate at the requested median's precision")
        }
        self.min = min
        self.max = max
        self.median = median
        self.scale = scale
        self.location = median - scale * k
        self.angleSpan = span
        self.medianLocationRatio = k
    }

    /// Retained public scale/width limit; calculations use normalized coordinates.
    static let maxScaleToWidthRatio = 100.0
    private let angleSpan: Double
    private let medianLocationRatio: Double

    enum SamplingError: Error, CustomStringConvertible {
        case numericalExhaustion
        var description: String {
            "Could not draw a finite interior jitter duration after 64 numerical attempts"
        }
    }

    /// The `p`-quantile of the truncated distribution.
    func truncatedQuantile(_ p: Double) -> Double {
        let tangent = tan((p - 0.5) * angleSpan)
        let k = medianLocationRatio
        return median + scale * ((1 + k * k) * tangent / (1 - k * tangent))
    }

    /// Spread of the middle half of all draws, in milliseconds.
    var interquartileRange: Double { truncatedQuantile(0.75) - truncatedQuantile(0.25) }

    /// A one-line warning when the draws are nearly fixed (#186), else nil.
    var nearlyFixedWarning: String? {
        let iqr = interquartileRange
        let belowClockResolution = iqr < 0.000001 // one nanosecond, in milliseconds
        guard belowClockResolution || iqr < Self.nearlyFixedIQRFraction * median else { return nil }
        let clockNote = belowClockResolution ? " The spread is below one nanosecond of sleep resolution." : ""
        return "⚠ jitter is nearly fixed: half of all delays fall within \(String(format: "%.6g", iqr)) ms of each other "
            + "around \(String(format: "%.6g", median)) ms. Consider adjusting --median or widening --min/--max; "
            + "a larger --scale helps only while the median remains achievable (the default for these bounds is "
            + "\(String(format: "%.6g", Self.defaultScale(min: min, max: max, median: median))))." + clockNote
    }

    /// Inverse-CDF draw strictly inside `(min, max)`, without endpoint clamping.
    /// Numerical endpoint results are retried at most 64 times, then fail.
    /// Raw high bits fix the uniform sequence; final floating-point draws are
    /// reproducible within the same supported numerical environment (libm is
    /// not promised to be bit-identical across platforms or toolchains).
    func sample<G: RandomNumberGenerator>(using generator: inout G) throws -> Double {
        for _ in 0..<64 {
            let unit = Double(generator.next() >> 11) * 0x1p-53
            guard unit > 0 else { continue }
            // Center at the requested median rather than subtracting a distant
            // location. Tangent addition gives the same inverse CDF while
            // avoiding loss of scale at a large offset.
            let tangent = tan((unit - 0.5) * angleSpan)
            let k = medianLocationRatio
            let displacement = scale * ((1 + k * k) * tangent / (1 - k * tangent))
            let x = median + displacement
            if x.isFinite, x > min, x < max { return x }
        }
        throw SamplingError.numericalExhaustion
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
        let lower = atan2(min - location, scale)
        let upper = atan2(max - location, scale)
        return location + scale * tan(lower + (upper - lower) / 2)
    }

    /// Full range over all real locations. The median equation has a real
    /// location iff p*q >= abs(q-p)*g. Solving its equality for p gives t;
    /// its reflection gives 1-t. Global extrema can require locations outside
    /// the truncation interval; no artificial location restriction is used.
    static func achievableMedianRange(scale: Double, min: Double, max: Double) -> ClosedRange<Double> {
        let width = max - min
        let g = scale / width
        let t = g / (0.5 + g + hypot(0.5, g))
        let inset = width * t
        return (min + inset)...(max - inset)
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
