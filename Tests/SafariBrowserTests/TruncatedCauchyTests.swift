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

    @Test(arguments: [
        ["2000", "--jitter", "cauchy"],
        ["--jitter", "cauchy", "--for-url", "example"],
        ["--jitter", "cauchy", "--js", "true"],
        ["--min", "10"],
        ["--seed", "1", "500"],
        ["--jitter", "cauchy", "--max", "18446744073710"],
    ])
    func `Conflicting or orphaned jitter options are rejected`(arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try WaitCommand.parseAsRoot(arguments)
        }
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
