import ArgumentParser
import Foundation
import Testing
@testable import SafariBrowser

/// #186: usability of `wait --jitter cauchy` parameters — a default scale that
/// follows the bounds, a warning when the draws are nearly fixed, and an
/// explicit opt-in for an upper bound over one hour.
struct JitterUsabilityTests {

    // MARK: - Default scale follows the bounds

    @Test func `Default scale is 800 for the default bounds`() throws {
        let command = try WaitCommand.parse(["--jitter", "cauchy"])
        #expect(try command.jitterDistribution().scale == 800)
        #expect(try TruncatedCauchy().scale == 800)
    }

    @Test func `Default scale follows the distance from the median to the nearer bound`() throws {
        // A fixed 800 made this median unreachable (achievable 1541.7…2458.3).
        let near = try WaitCommand.parse(["--jitter", "cauchy", "--min", "1000", "--max", "3000", "--median", "1500"])
        #expect(try near.jitterDistribution().scale == 400)
        let upper = try WaitCommand.parse(["--jitter", "cauchy", "--min", "1000", "--max", "3000", "--median", "2600"])
        #expect(try upper.jitterDistribution().scale == 320)
    }

    @Test func `An explicit scale is used as given`() throws {
        let command = try WaitCommand.parse(["--jitter", "cauchy", "--min", "1000", "--max", "3000", "--median", "2000", "--scale", "250"])
        #expect(try command.jitterDistribution().scale == 250)
    }

    @Test func `The derived default always reaches the requested median`() throws {
        // 0.8 × the distance to the nearer bound keeps the median inside the
        // achievable range: the lowest reachable median is below min + scale.
        for min in [0.0, 10, 500, 2000] {
            for width in [5.0, 200, 2000, 58000, 3_000_000] {
                for fraction in [0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99] {
                    let max = min + width
                    let median = min + width * fraction
                    let distribution = try TruncatedCauchy(min: min, max: max, median: median)
                    #expect(distribution.scale == 0.8 * Swift.min(median - min, max - median))
                }
            }
        }
    }

    // MARK: - Nearly fixed draws are reported

    @Test func `A tiny scale is reported as a nearly fixed interval`() throws {
        let spike = try TruncatedCauchy(min: 1000, max: 3000, median: 1500, scale: 1)
        let warning = try #require(spike.nearlyFixedWarning)
        #expect(warning.contains("nearly fixed"))
        #expect(warning.contains("--scale"))
        #expect(spike.interquartileRange < 3)
    }

    @Test func `Ordinary and deliberately narrow settings are not reported`() throws {
        #expect(try TruncatedCauchy().nearlyFixedWarning == nil)
        #expect(abs(try TruncatedCauchy().interquartileRange - 1338.8) < 1)
        #expect(try TruncatedCauchy(min: 900, max: 1100, median: 1000, scale: 80).nearlyFixedWarning == nil)
        #expect(try TruncatedCauchy(min: 2000, max: 600_000, median: 3000).nearlyFixedWarning == nil)
    }

    @Test func `The threshold is five percent of the median`() throws {
        // IQR/median: scale 50 → 0.033 (reported), scale 150 → 0.094 (not).
        #expect(try TruncatedCauchy(min: 2000, max: 60000, median: 3000, scale: 50).nearlyFixedWarning != nil)
        #expect(try TruncatedCauchy(min: 2000, max: 60000, median: 3000, scale: 150).nearlyFixedWarning == nil)
    }

    // MARK: - An upper bound over one hour needs an explicit opt-in

    @Test func `A max over one hour is rejected without --allow-long-wait`() throws {
        let error = #expect(throws: (any Error).self) {
            _ = try WaitCommand.parseAsRoot(["--jitter", "cauchy", "--max", "600000000"])
        }
        #expect(WaitCommand.message(for: error!).contains("--allow-long-wait"))
    }

    @Test func `One hour exactly is allowed and longer is allowed with the flag`() throws {
        _ = try WaitCommand.parseAsRoot(["--jitter", "cauchy", "--max", "3600000"])
        let long = try WaitCommand.parse(["--jitter", "cauchy", "--max", "600000000", "--allow-long-wait"])
        #expect(try long.jitterDistribution().max == 600_000_000)
    }

    @Test func `--allow-long-wait requires --jitter`() {
        #expect(throws: (any Error).self) {
            _ = try WaitCommand.parseAsRoot(["2000", "--allow-long-wait"])
        }
    }
}
