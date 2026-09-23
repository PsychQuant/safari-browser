import ArgumentParser
import Foundation
import Testing
@testable import SafariBrowser

/// #182: doubly truncated Cauchy sampler behind `wait --jitter cauchy`.
struct TruncatedCauchyTests {
    @Test func `Default parameters solve the location for a 3000ms truncated median`() throws {
        let distribution = try TruncatedCauchy()
        #expect(abs(distribution.location - 2611.455) < 0.01)
        let median = TruncatedCauchy.truncatedMedian(location: distribution.location, scale: 800, min: 2000, max: 60000)
        #expect(abs(median - 3000) < 1e-6)
    }

    @Test func `Seeded draws stay strictly inside the bounds with no point mass`() throws {
        let distribution = try TruncatedCauchy()
        var generator = SplitMix64(seed: 182)
        var draws: [Double] = []
        draws.reserveCapacity(100_000)
        for _ in 0..<100_000 {
            draws.append(distribution.sample(using: &generator))
        }
        #expect(draws.allSatisfy { $0 > 2000 && $0 < 60000 })
        draws.sort()
        let empiricalMedian = draws[draws.count / 2]
        #expect(abs(empiricalMedian - 3000) / 3000 < 0.01)
    }

    @Test func `Same seed reproduces the same sequence`() throws {
        let distribution = try TruncatedCauchy()
        var first = SplitMix64(seed: 42)
        var second = SplitMix64(seed: 42)
        let a = (0..<100).map { _ in distribution.sample(using: &first) }
        let b = (0..<100).map { _ in distribution.sample(using: &second) }
        #expect(a == b)
    }

    @Test func `Different seeds produce different sequences`() throws {
        let distribution = try TruncatedCauchy()
        var first = SplitMix64(seed: 1)
        var second = SplitMix64(seed: 2)
        let a = (0..<10).map { _ in distribution.sample(using: &first) }
        let b = (0..<10).map { _ in distribution.sample(using: &second) }
        #expect(a != b)
    }

    @Test func `Median just inside the achievable range is solved`() throws {
        let range = TruncatedCauchy.achievableMedianRange(scale: 800, min: 2000, max: 60000)
        let target = range.lowerBound + 5
        let distribution = try TruncatedCauchy(min: 2000, max: 60000, median: target, scale: 800)
        let median = TruncatedCauchy.truncatedMedian(location: distribution.location, scale: 800, min: 2000, max: 60000)
        #expect(abs(median - target) < 1e-6)
    }

    @Test func `Unreachable median is rejected with the achievable range`() {
        let error = #expect(throws: ValidationError.self) {
            _ = try TruncatedCauchy(min: 2000, max: 60000, median: 3000, scale: 5000)
        }
        let message = error.map { String(describing: $0) } ?? ""
        #expect(message.contains("achievable"), "\(message)")
    }

    /// #182 verify R1: these scales used to trap the process (inverted
    /// ClosedRange, or an empty `Double.random` range after validation passed).
    @Test(arguments: [
        (2000.0, 60000.0, 3000.0, 1e10),
        (2000.0, 60000.0, 31000.0, 1e15),
        (2000.0, 60000.0, 3000.0, 1e300),
        (0.0, 10.0, 5.0, 1e13),
        (0.0, 10.0, 5.0, 1e17),
        (2000.0, 2010.0, 2005.0, 1e12),
    ])
    func `Numerically degenerate scales are validation errors, not traps`(parameters: (Double, Double, Double, Double)) {
        #expect(throws: ValidationError.self) {
            _ = try TruncatedCauchy(min: parameters.0, max: parameters.1, median: parameters.2, scale: parameters.3)
        }
    }

    @Test func `Scale is accepted up to the cap and rejected above it`() throws {
        let atCap = try TruncatedCauchy(min: 0, max: 10, median: 5, scale: 1000)
        var generator = SplitMix64(seed: 9)
        let draws = (0..<10_000).map { _ in atCap.sample(using: &generator) }
        #expect(draws.allSatisfy { $0 > 0 && $0 < 10 })
        #expect(throws: ValidationError.self) {
            _ = try TruncatedCauchy(min: 0, max: 10, median: 5, scale: 1000.001)
        }
    }

    /// #182 verify R2: the printed range used plain rounding, so copying the
    /// printed upper endpoint (55412.5 for a true 55412.4898) was rejected again.
    @Test(arguments: [
        (2000.0, 60000.0, 5000.0),
        (0.0, 1.0, 0.05),
    ])
    func `Both printed achievable endpoints are accepted`(parameters: (Double, Double, Double)) throws {
        let (low, high, scale) = parameters
        let error = #expect(throws: ValidationError.self) {
            _ = try TruncatedCauchy(min: low, max: high, median: low + (high - low) * 1e-9, scale: scale)
        }
        let message = error.map { String(describing: $0) } ?? ""
        let range = try #require(message.range(of: #"achievable medians are ([0-9.]+)\.\.\.([0-9.]+)\."#, options: .regularExpression))
        let printed = message[range]
            .replacingOccurrences(of: "achievable medians are ", with: "")
            .dropLast()
            .components(separatedBy: "...")
            .compactMap(Double.init)
        try #require(printed.count == 2, "\(message)")
        for endpoint in printed {
            _ = try TruncatedCauchy(min: low, max: high, median: endpoint, scale: scale)
        }
    }

    @Test func `SplitMix64 matches the reference stream`() {
        var generator = SplitMix64(seed: 0)
        #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
        #expect(generator.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(generator.next() == 0x06C4_5D18_8009_454F)
    }

    @Test(arguments: [
        (-1.0, 60000.0, 3000.0, 800.0),   // negative minimum
        (3000.0, 60000.0, 3000.0, 800.0), // minimum not below median
        (2000.0, 3000.0, 3000.0, 800.0),  // median not below maximum
        (2000.0, 60000.0, 3000.0, 0.0),   // non-positive scale
        (2000.0, 60000.0, 3000.0, -5.0),
    ])
    func `Invalid parameters are validation errors`(parameters: (Double, Double, Double, Double)) {
        #expect(throws: ValidationError.self) {
            _ = try TruncatedCauchy(min: parameters.0, max: parameters.1, median: parameters.2, scale: parameters.3)
        }
    }
}

/// #182: `wait --jitter cauchy` command-line surface.
struct WaitJitterCommandTests {
    @Test func `Jitter alone parses with default parameters`() throws {
        let command = try WaitCommand.parse(["--jitter", "cauchy"])
        #expect(command.jitter == .cauchy)
        let distribution = try command.jitterDistribution()
        #expect(distribution.min == 2000 && distribution.max == 60000)
        #expect(distribution.median == 3000 && distribution.scale == 800)
    }

    @Test func `Explicit jitter parameters are used`() throws {
        let command = try WaitCommand.parse(["--jitter", "cauchy", "--min", "10", "--max", "30", "--median", "15", "--scale", "3", "--seed", "7"])
        let distribution = try command.jitterDistribution()
        #expect(distribution.min == 10 && distribution.max == 30)
        #expect(distribution.median == 15 && distribution.scale == 3)
        #expect(command.seed == 7)
    }

    /// `parse` wraps a `ValidationError` in a `CommandError`, so each case is
    /// pinned by the user-facing message it must produce — a stricter check than
    /// accepting any error, which would pass even if the wrong guard fired.
    @Test(arguments: [
        (["2000", "--jitter", "cauchy"], "cannot be combined"),
        (["--jitter", "cauchy", "--for-url", "example"], "cannot be combined"),
        (["--jitter", "cauchy", "--js", "true"], "cannot be combined"),
        (["--min", "10"], "require --jitter cauchy"),
        (["--seed", "1", "500"], "require --jitter cauchy"),
        (["--jitter", "cauchy", "--scale", "1e13"], "is too large"),
        (["--jitter", "cauchy", "--max", "18446744073710"], "maximum representable"),
    ])
    func `Conflicting, orphaned, degenerate or unrepresentable jitter options are rejected with the right message`(
        case: ([String], String)
    ) {
        let error = #expect(throws: (any Error).self) {
            _ = try WaitCommand.parse(`case`.0)
        }
        let message = error.map { WaitCommand.message(for: $0) } ?? ""
        #expect(message.contains(`case`.1), "\(message)")
    }

    /// #182 verify R1: each `wait` is its own process, so a seed fixes the single
    /// draw of that call — the CLI has no sequence to reproduce. This pins the
    /// behavior the help text now describes.
    @Test func `The same seed gives the same delay on every call`() throws {
        let first = try WaitCommand.parse(["--jitter", "cauchy", "--seed", "42"]).drawJitterMilliseconds()
        let second = try WaitCommand.parse(["--jitter", "cauchy", "--seed", "42"]).drawJitterMilliseconds()
        let other = try WaitCommand.parse(["--jitter", "cauchy", "--seed", "43"]).drawJitterMilliseconds()
        #expect(first == second)
        #expect(first != other)
    }

    @Test func `Unseeded calls draw different delays`() throws {
        let command = try WaitCommand.parse(["--jitter", "cauchy"])
        let draws = Set(try (0..<20).map { _ in try command.drawJitterMilliseconds() })
        #expect(draws.count > 1)
    }

    @Test func `Unsupported distribution name is rejected`() {
        #expect(throws: (any Error).self) {
            _ = try WaitCommand.parseAsRoot(["--jitter", "lognormal"])
        }
    }

    @Test func `Run sleeps for a drawn duration inside a small interval`() async throws {
        let command = try WaitCommand.parse(["--jitter", "cauchy", "--min", "10", "--max", "40", "--median", "20", "--scale", "5", "--seed", "3"])
        let clock = ContinuousClock()
        let elapsed = try await clock.measure { try await command.run() }
        #expect(elapsed >= .milliseconds(10))
        #expect(elapsed < .milliseconds(1000))
    }
}
