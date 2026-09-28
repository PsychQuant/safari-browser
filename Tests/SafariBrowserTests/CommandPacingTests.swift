import Foundation
import XCTest
@testable import SafariBrowser

final class CommandPacingTests: XCTestCase, @unchecked Sendable {
    private enum Failure: Error { case owned }
    private func smallPolicy() throws -> CommandPacing {
        try CommandPacing(environment: ["SAFARI_BROWSER_PACING": "cauchy",
            "SAFARI_BROWSER_PACING_MIN_MS": "0", "SAFARI_BROWSER_PACING_MEDIAN_MS": "0.5",
            "SAFARI_BROWSER_PACING_MAX_MS": "1"])
    }

    func testDefaultsReuseTheExistingDistributionAndUnits() throws {
        let policy = try CommandPacing(environment: ["SAFARI_BROWSER_PACING": "cauchy"])
        let prepared = try XCTUnwrap(policy.prepare(draw: { distribution in
            XCTAssertEqual(distribution.min, 2000)
            XCTAssertEqual(distribution.max, 60000)
            XCTAssertEqual(distribution.median, 3000)
            XCTAssertEqual(distribution.scale, 800)
            return 3000
        }))
        XCTAssertEqual(prepared.nanoseconds, 3_000_000_000)
        XCTAssertNil(prepared.warning)
    }

    func testEnvironmentValidationErrorsNameEnvironmentParameters() {
        XCTAssertThrowsError(try CommandPacing(environment: ["SAFARI_BROWSER_PACING": "cauchy", "SAFARI_BROWSER_PACING_MIN_MS": "-1"])) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("SAFARI_BROWSER_PACING_MIN_MS"), message)
            XCTAssertFalse(message.contains("--min"), "Ordinary commands do not accept wait's parameter flags")
        }
    }

    func testOffDoesNotDrawOrSleep() async throws {
        var calls = 0
        let policy = try CommandPacing(environment: [:])
        let result = try await policy.perform(draw: { _ in XCTFail("Disabled pacing drew a value"); return 0 },
            sleep: { _ in XCTFail("Disabled pacing slept") }, operation: { calls += 1; return 42 })
        XCTAssertEqual(result, 42)
        XCTAssertEqual(calls, 1)
    }

    func testOneDrawPrecedesOperationAndOneSleepFollowsIt() async throws {
        var events: [String] = []
        let value = try await smallPolicy().perform(draw: { _ in events.append("draw"); return 0.5 },
            sleep: { ns in events.append("sleep:\(ns)") }, operation: { events.append("operation"); return 17 })
        XCTAssertEqual(value, 17)
        XCTAssertEqual(events, ["draw", "operation", "sleep:500000"])
    }

    func testDrawFailurePreventsOperationAndSleep() async throws {
        var calls = 0, sleeps = 0
        do {
            let _: Int = try await smallPolicy().perform(draw: { _ in throw Failure.owned },
                sleep: { _ in sleeps += 1 }, operation: { calls += 1; return 42 })
            XCTFail("Sampling failure must propagate")
        } catch Failure.owned {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls, 0); XCTAssertEqual(sleeps, 0)
    }

    func testRuntimeErrorSurvivesItsCompletedWait() async throws {
        var calls = 0, sleeps = 0
        do {
            let _: Int = try await smallPolicy().perform(draw: { _ in 0.5 }, sleep: { ns in
                XCTAssertEqual(ns, 500_000); sleeps += 1
            }, operation: { calls += 1; throw Failure.owned })
            XCTFail("Operation error must propagate")
        } catch Failure.owned {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls, 1); XCTAssertEqual(sleeps, 1)
    }

    func testRuntimeErrorRemainsAuthoritativeWhenWaitIsInterrupted() async throws {
        var effects = 0, sleeps = 0
        do {
            let _: Int = try await smallPolicy().perform(draw: { _ in 0.5 }, sleep: { _ in
                sleeps += 1; throw CancellationError()
            }, operation: { effects += 1; throw Failure.owned })
            XCTFail("Original error must propagate")
        } catch Failure.owned {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(effects, 1); XCTAssertEqual(sleeps, 1)
    }

    func testSuccessfulEffectIsNotReplayedWhenWaitIsInterrupted() async throws {
        var effects = 0
        do {
            let _: Int = try await smallPolicy().perform(draw: { _ in 0.5 }, sleep: { _ in throw CancellationError() },
                operation: { effects += 1; return 42 })
            XCTFail("Interrupted pacing must not look successful")
        } catch let error as CommandPacing.InterruptedAfterExecution {
            XCTAssertEqual(error.errorDescription, "Command pacing interrupted after execution; earlier effects are not undone.")
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(effects, 1)
    }

    func testCancellationBeforeOperationPreventsEffectAndSleep() async throws {
        let policy = try smallPolicy()
        let result = await Task {
            var effects = 0, sleeps = 0
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let _: Int = try await policy.perform(draw: { _ in 0.5 }, sleep: { _ in sleeps += 1 },
                    operation: { effects += 1; return 42 })
                return (false, effects, sleeps)
            } catch is CancellationError { return (true, effects, sleeps) }
            catch { return (false, effects, sleeps) }
        }.value
        XCTAssertTrue(result.0); XCTAssertEqual(result.1, 0); XCTAssertEqual(result.2, 0)
    }

    func testOperationCancellationDoesNotStartExtraWait() async throws {
        var sleeps = 0
        do {
            let _: Int = try await smallPolicy().perform(draw: { _ in 0.5 }, sleep: { _ in sleeps += 1 },
                operation: { throw CancellationError() })
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(sleeps, 0)
    }

    func testNearlyFixedWarningIsEmittedOnce() async throws {
        let policy = try CommandPacing(environment: ["SAFARI_BROWSER_PACING": "cauchy",
            "SAFARI_BROWSER_PACING_MIN_MS": "1000", "SAFARI_BROWSER_PACING_MAX_MS": "3000",
            "SAFARI_BROWSER_PACING_MEDIAN_MS": "2000", "SAFARI_BROWSER_PACING_SCALE_MS": "1"])
        var warnings: [String] = []
        try await policy.perform(draw: { _ in 2000 }, sleep: { _ in }, warning: { warnings.append($0) }, operation: {})
        XCTAssertEqual(warnings.count, 1)
        let message = try XCTUnwrap(warnings.first)
        XCTAssertTrue(message.contains("jitter is nearly fixed"))
        for parameter in ["MIN", "MAX", "MEDIAN", "SCALE"] {
            XCTAssertTrue(message.contains("SAFARI_BROWSER_PACING_" + parameter + "_MS"), message)
        }
        XCTAssertFalse(message.contains("--median"))
    }
}
