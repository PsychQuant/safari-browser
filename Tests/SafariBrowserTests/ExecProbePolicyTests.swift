import Foundation
import XCTest
@testable import SafariBrowser

/// #226: a `js` command probes for a blocking dialog at most once and, when its JavaScript times
/// out, reports the original timeout instead of running a second inspection (#181). A daemon exec
/// step does not go through `JSCommand`, so the policy has to be applied to it by the in-process
/// dispatcher. These tests run the real dispatcher against the fake Safari of the `js` round-trip
/// tests and count the probes the dialog gate really makes.
final class ExecProbePolicyTests: XCTestCase, @unchecked Sendable {
    typealias FakeSafari = JSCommandRoundTripTests.FakeSafari
    typealias ProbeCounter = JSCommandRoundTripTests.ProbeCounter

    /// Runs the steps one after the other through one dispatcher, as an `exec.runScript` request
    /// does, and returns what each step produced.
    private func run(
        _ steps: [(cmd: String, args: [String])], shared: [String], on fake: FakeSafari, probes: ProbeCounter
    ) async -> (results: [Result<String, Error>], gate: BlockingDialogGate) {
        let context = DaemonRequestContext(probe: { _ in probes.hit(); return .clear }, environment: [:])
        let dispatcher = InProcessStepDispatcher()
        var results: [Result<String, Error>] = []
        await DaemonRequestContext.$current.withValue(context) {
            await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                for step in steps {
                    do { results.append(.success(try await dispatcher.dispatch(cmd: step.cmd, args: step.args, sharedTargetArgs: shared))) }
                    catch { results.append(.failure(error)) }
                }
            }
        }
        return (results, context.gate)
    }

    private let targets: [[String]] = [[], ["--window", "1", "--tab-in-window", "2"], ["--url-exact", "https://w1.example/2"]]

    /// The discriminating case: the step's JavaScript times out, and the forced re-check that used
    /// to follow (a second probe, with its own budget) must not run.
    func testATimedOutJSStepKeepsTheOriginalFailureWithoutASecondProbe() async {
        for shared in targets {
            let fake = FakeSafari(failJSContaining: "document.title")
            fake.failWithTimeout = true
            let probes = ProbeCounter()
            let outcome = await run([("js", ["document.title"])], shared: shared, on: fake, probes: probes)
            guard case .failure(let error)? = outcome.results.first else { XCTFail("\(shared): the timed-out step must fail"); continue }
            guard case SafariBrowserError.processTimedOut(let command, let seconds) = error else {
                XCTFail("\(shared): expected the original processTimedOut, got \(error)"); continue
            }
            XCTAssertEqual(command, "owned-js-fixture", "\(shared)")
            XCTAssertEqual(seconds, 30, "\(shared)")
            XCTAssertEqual(probes.count, 1, "\(shared): \(probes.count) real probes for one timed-out js step")
            XCTAssertEqual(outcome.gate.state(for: .id(101)), .unprobed, "\(shared): no fresh evidence was recorded by a second probe")
        }
    }

    func testAJSStepThatSucceedsProbesOnce() async {
        for shared in targets {
            let fake = FakeSafari()
            let probes = ProbeCounter()
            let outcome = await run([("js", ["document.title"])], shared: shared, on: fake, probes: probes)
            guard case .success? = outcome.results.first else { XCTFail("\(shared): \(outcome.results)"); continue }
            XCTAssertEqual(probes.count, 1, "\(shared)")
        }
    }

    /// The allowance belongs to a step, not to the run: each step is a logical command with its own
    /// evidence and budget (`beginCommand`), as it is when every step runs as its own process.
    func testEachJSStepHasItsOwnAllowance() async {
        let fake = FakeSafari()
        let probes = ProbeCounter()
        let outcome = await run([("js", ["document.title"]), ("js", ["document.title"]), ("js", ["document.title"])],
                                shared: ["--window", "1", "--tab-in-window", "2"], on: fake, probes: probes)
        XCTAssertEqual(outcome.results.count, 3)
        XCTAssertEqual(probes.count, 3, "one probe per step")
    }

    /// Only `js` has the allowance. Its counterparts that are not the `js` command, run as their own
    /// processes, never had it either; their timeout keeps the forced re-check. Pinned so that the
    /// scope of the change is a decision (here: `get text`, whose `innerText` fallback runs JavaScript).
    func testAStepThatIsNotJSKeepsTheForcedRecheckAfterATimeout() async {
        let fake = FakeSafari(failJSContaining: "window.__sb")
        fake.failWithTimeout = true
        let probes = ProbeCounter()
        let outcome = await run([("get text", [])], shared: ["--window", "1", "--tab-in-window", "2"], on: fake, probes: probes)
        guard case .failure(let error)? = outcome.results.first, case SafariBrowserError.processTimedOut = error else {
            return XCTFail("expected a processTimedOut from the innerText fallback, got \(outcome.results)")
        }
        XCTAssertGreaterThan(probes.count, 1, "the step is not a `js` command: its forced re-check after the timeout still runs")
    }
}
