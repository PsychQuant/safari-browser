import ArgumentParser
import XCTest
@testable import SafariBrowser

final class JitterNanosecondTests: XCTestCase, @unchecked Sendable {
    func testSubNanosecondJitterIsRejectedBeforeSleeping() {
        XCTAssertThrowsError(try WaitCommand.parse([
            "--jitter", "cauchy", "--min", "0.0000001", "--max", "0.0000009",
            "--median", "0.0000005", "--scale", "0.0000001"
        ]))
    }

    func testZeroAndSingleQuantumIntervalsAreRejected() {
        for (min, max) in [(0.0, 0.0000009), (0.0000001, 0.0000019)] {
            XCTAssertThrowsError(try WaitCommand.JitterNanosecondRange(min: min, max: max))
            XCTAssertThrowsError(try WaitCommand.parse([
                "--jitter", "cauchy", "--min", String(min), "--max", String(max),
                "--median", String((min + max) / 2), "--scale", String((max - min) / 4)
            ]))
        }
    }

    func testIntegerMillisecondEndpointsAreNeverSleepArguments() throws {
        let range = try WaitCommand.JitterNanosecondRange(min: 1, max: 2)
        XCTAssertEqual(range.lower, 1_000_001)
        XCTAssertEqual(range.upper, 1_999_999)
        XCTAssertEqual(try range.nanoseconds(for: Double(1).nextUp), 1_000_001)
        XCTAssertEqual(try range.nanoseconds(for: Double(2).nextDown), 1_999_999)
        XCTAssertEqual(try range.nanoseconds(for: 1.25), 1_250_000)
        XCTAssertEqual(try range.nanoseconds(for: 1.75), 1_750_000)
    }

    func testFractionalBoundsAndNearestTickIncludingHalfTick() throws {
        // Binary-exact millisecond fractions avoid an oracle that duplicates
        // the production conversion: 1/128 ms = 7812.5 ns exactly.
        let range = try WaitCommand.JitterNanosecondRange(min: 1.0 / 128, max: 3.0 / 128)
        XCTAssertEqual(range.lower, 7813)
        XCTAssertEqual(range.upper, 23437)
        let broad = try WaitCommand.JitterNanosecondRange(min: 0, max: 1)
        let half = 1.0 / 128
        XCTAssertEqual(try broad.nanoseconds(for: half.nextDown), 7812)
        XCTAssertEqual(try broad.nanoseconds(for: half), 7813)
        XCTAssertEqual(try broad.nanoseconds(for: half.nextUp), 7813)
        XCTAssertEqual(try range.nanoseconds(for: (1.0 / 128).nextUp), 7813)
        XCTAssertEqual(try range.nanoseconds(for: (3.0 / 128).nextDown), 23437)
        // This product rounds to the half tick, but its exact value is below
        // 3.5 ns; ties-away rounding without the residual would incorrectly use 4.
        XCTAssertEqual(0.0000035 * 1_000_000, 3.5)
        XCTAssertEqual(try broad.nanoseconds(for: 0.0000035), 3)
    }

    func testFractionProductRoundedToIntegerStillHonorsExactDoubleBounds() throws {
        // The binary Double 1e-6 is slightly below one nanosecond even though
        // ordinary multiplication rounds its product to exactly 1.0.
        XCTAssertEqual(0.000001 * 1_000_000, 1)
        let below = try WaitCommand.JitterNanosecondRange(min: 0.000001, max: 0.000004)
        XCTAssertEqual(below.lower, 1)
        XCTAssertEqual(below.upper, 3)
        let above = try WaitCommand.JitterNanosecondRange(min: Double(0.000001).nextUp, max: 0.000004)
        XCTAssertEqual(above.lower, 2)
        XCTAssertEqual(above.upper, 3)
        // Conversely, parsed 3e-6 ms is slightly *above* three nanoseconds.
        XCTAssertEqual(0.000003 * 1_000_000, 3)
        let positiveResidual = try WaitCommand.JitterNanosecondRange(min: 0, max: 0.000003)
        XCTAssertEqual(positiveResidual.upper, 3)
    }

    func testLargeWaitKeepsLowNanosecondBitsAndPreservesOverflowGuard() throws {
        let limit = UInt64.max / 1_000_000
        let range = try WaitCommand.JitterNanosecondRange(min: Double(limit - 2), max: Double(limit))
        XCTAssertEqual(range.lower, (limit - 2) * 1_000_000 + 1)
        XCTAssertEqual(range.upper, limit * 1_000_000 - 1)
        XCTAssertEqual(try range.nanoseconds(for: Double(limit) - 1.5), (limit - 2) * 1_000_000 + 500_000)
        // At this magnitude Double's ULP is 1/256 ms = 3906.25 ns.
        XCTAssertEqual(try range.nanoseconds(for: Double(limit).nextDown), limit * 1_000_000 - 3906)
        for max in [Double(limit) + 0.125, Double(limit + 1), Double(UInt64.max), Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try WaitCommand.JitterNanosecondRange(min: 0, max: max))
        }
    }

    func testNonfiniteAndNonInteriorValuesFailWithoutConversionTrap() throws {
        for min in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertThrowsError(try WaitCommand.JitterNanosecondRange(min: min, max: 2))
        }
        for max in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertThrowsError(try WaitCommand.JitterNanosecondRange(min: 0, max: max))
        }
        let range = try WaitCommand.JitterNanosecondRange(min: 1, max: 2)
        for draw in [Double.nan, .infinity, -.infinity, 0, 1, 2, 3] {
            XCTAssertThrowsError(try range.nanoseconds(for: draw))
        }
    }

    func testNegativeZeroLowerBoundBehavesAsZeroAndNeverSleepsZero() throws {
        let range = try WaitCommand.JitterNanosecondRange(min: -0.0, max: 1)
        XCTAssertEqual(range.lower, 1)
        XCTAssertThrowsError(try range.nanoseconds(for: -0.0))
        XCTAssertEqual(try range.nanoseconds(for: Double.leastNonzeroMagnitude), 1)
    }

    func testActualRunPassesOnlyLegalRandomizedNanosecondsToSleep() async throws {
        var observed = Set<UInt64>()
        for seed in 0..<128 {
            let command = try WaitCommand.parse([
                "--jitter", "cauchy", "--min", "0.0000001", "--max", "0.0000029",
                "--median", "0.0000015", "--scale", "0.0000004", "--seed", String(seed)
            ])
            let range = try WaitCommand.JitterNanosecondRange(min: 0.0000001, max: 0.0000029)
            let expected = try range.nanoseconds(for: command.drawJitterMilliseconds())
            var calls: [UInt64] = []
            try await command.run(sleep: { calls.append($0) })
            XCTAssertEqual(calls, [expected])
            XCTAssertTrue(expected == 1 || expected == 2)
            observed.insert(expected)
        }
        XCTAssertEqual(observed, [1, 2])
    }

    func testRunRejectsUnrepresentableIntervalWithoutCallingSleepEvenIfValidationWasSkipped() async {
        var command = WaitCommand()
        command.jitter = .cauchy
        command.jitterMin = 0.0000001
        command.jitterMax = 0.0000009
        command.jitterMedian = 0.0000005
        command.jitterScale = 0.0000001
        var called = false
        do {
            try await command.run(sleep: { _ in called = true })
            XCTFail("Expected unrepresentable jitter to fail")
        } catch {
            XCTAssertTrue(error is ValidationError)
        }
        XCTAssertFalse(called)
    }

    func testFixedDurationStillPassesItsExactDurationToSleep() async throws {
        let command = try WaitCommand.parse(["2"])
        var calls: [UInt64] = []
        try await command.run(sleep: { calls.append($0) })
        XCTAssertEqual(calls, [2_000_000])
    }
}
