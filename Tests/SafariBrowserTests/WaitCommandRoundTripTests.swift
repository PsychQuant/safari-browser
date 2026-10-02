import Foundation
import XCTest
@testable import SafariBrowser

/// #168: `wait --js` / `wait --for-url` polled every 500 ms and re-resolved the
/// target on every poll — for a `--url` target that is one full window/tab
/// enumeration per poll. It also broke the command's own purpose: waiting for
/// a navigation away from the URL the target was named by failed on the next
/// poll, because the old URL no longer matched anything. The target is now
/// resolved once, at the command boundary, with the same anchoring `js` uses.
final class WaitCommandRoundTripTests: XCTestCase, @unchecked Sendable {
    typealias FakeSafari = JSCommandRoundTripTests.FakeSafari

    private func runWait(_ args: [String], on fake: FakeSafari,
                         probe: @escaping @Sendable (BlockingDialogGate.WindowKey) -> BlockingDialogState = { _ in .clear }) async throws {
        let context = DaemonRequestContext(probe: probe, environment: [:])
        let command = try WaitCommand.parse(args)
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                try await command.run()
            }
        }
    }

    /// What the wait asks its sleep for, in nanoseconds.
    final class SleepRequests: @unchecked Sendable {
        private let lock = NSLock(); private var items: [UInt64] = []
        func add(_ ns: UInt64) { lock.withLock { items.append(ns) } }
        var all: [UInt64] { lock.withLock { items } }
    }

    /// A clock that moves only when the wait sleeps, by what it asked for: no real time passes, so
    /// the requests are exact and do not depend on the scheduler.
    final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock(); private var t = Date(timeIntervalSinceReferenceDate: 0)
        var now: Date { lock.withLock { t } }
        func advance(nanoseconds: UInt64) { lock.withLock { t = t.addingTimeInterval(Double(nanoseconds) / 1_000_000_000) } }
    }

    /// Runs the wait on a virtual clock and returns what it asked to sleep for. The error, if any,
    /// is the wait's own (a timeout, for a condition that never holds).
    private func virtualRun(_ args: [String], on fake: FakeSafari, pollCost: UInt64 = 0) async -> (requests: [UInt64], error: Error?) {
        let requests = SleepRequests()
        let clock = VirtualClock()
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        do {
            let command = try WaitCommand.parse(args)
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                    // A poll that takes `pollCost` of the virtual clock: what a slow poll does to the deadline.
                    if pollCost > 0, source.contains("window.ready") { clock.advance(nanoseconds: pollCost) }
                    return try fake.respond(source)
                }) {
                    try await command.run(sleep: { requests.add($0); clock.advance(nanoseconds: $0) }, now: { clock.now })
                }
            }
            return (requests.all, nil)
        } catch { return (requests.all, error) }
    }

    func testWaitForJSResolvesAURLTargetOnceAcrossPolls() async {
        let fake = FakeSafari()
        do {
            try await runWait(["--js", "window.ready", "--timeout", "1200", "--url", "w1.example/53"], on: fake)
            XCTFail("the condition never becomes true, so the wait must time out")
        } catch SafariBrowserError.timeout {
        } catch {
            XCTFail("expected a timeout, got \(error)")
        }
        XCTAssertGreaterThanOrEqual(fake.javaScripts.count, 2, "several polls ran:\n\(fake.transcript)")
        XCTAssertEqual(fake.enumerations, 1, "one enumeration for the whole wait, not one per poll:\n\(fake.transcript)")
        for script in fake.javaScripts {
            XCTAssertTrue(script.contains("tab 53 of window id 101"), script)
        }
    }

    func testWaitForURLFollowsTheTargetTabThroughTheNavigationItWaitsFor() async throws {
        let fake = FakeSafari()
        fake.navigateTab53AfterFirstURLRead = true
        // Before #168 the second poll re-resolved `--url w1.example/53`, found
        // nothing (the tab now shows /done) and failed — during exactly the
        // navigation the command was waiting for.
        try await runWait(["--for-url", "/done", "--timeout", "3000", "--url", "w1.example/53"], on: fake)
        XCTAssertEqual(fake.enumerations, 1, fake.transcript)
    }

    // MARK: - Verify R1: the URL wait keeps its target or fails closed

    func testWaitForURLOnTheDefaultTargetFailsClosedWhenAnotherTabBecomesCurrent() async {
        // The URL read of an anchored current tab carries the same current-tab
        // check as `js`; before, `wait --for-url` read `tab T of window id W`
        // with no check at all.
        let fake = FakeSafari()
        fake.tripGuard = true
        do {
            try await runWait(["--for-url", "/never", "--timeout", "2000"], on: fake)
            XCTFail("a changed current tab must fail the wait")
        } catch SafariBrowserError.anchoredTargetChanged(let target) {
            XCTAssertTrue(target.contains("front window's current tab"), target)
        } catch {
            XCTFail("expected anchoredTargetChanged, got \(error)")
        }
        XCTAssertTrue(fake.scripts.contains { $0.contains("index of current tab of _w") && $0.contains("get URL of tab") },
                      fake.transcript)
    }

    func testWaitForURLOnAURLTargetReadsItsWindowOncePerPoll() async {
        let fake = FakeSafari()
        do {
            try await runWait(["--for-url", "/never", "--timeout", "1200", "--url", "w1.example/53"], on: fake)
            XCTFail("expected a timeout")
        } catch SafariBrowserError.timeout {
        } catch {
            XCTFail("expected a timeout, got \(error)")
        }
        XCTAssertGreaterThanOrEqual(fake.windowURLReads.count, 2, fake.transcript)
        XCTAssertTrue(fake.windowURLReads.allSatisfy { $0.contains("window id 101") }, fake.transcript)
        XCTAssertEqual(fake.enumerations, 1, fake.transcript)
    }

    private func expectTimeout(_ args: [String], on fake: FakeSafari, _ why: String) async {
        do {
            try await runWait(args, on: fake)
            XCTFail(why + "\n" + fake.transcript)
        } catch SafariBrowserError.timeout {
        } catch {
            XCTFail("expected a timeout, got \(error)")
        }
    }

    private func expectTargetChanged(_ args: [String], on fake: FakeSafari, containing text: String) async {
        do {
            try await runWait(args, on: fake)
            XCTFail("the wait must fail closed\n" + fake.transcript)
        } catch SafariBrowserError.anchoredTargetChanged(let target) {
            XCTAssertTrue(target.contains(text), target)
        } catch {
            XCTFail("expected anchoredTargetChanged, got \(error)")
        }
    }

    func testWaitForURLFollowsTheTargetWhenATabToTheLeftCloses() async {
        // Verify R2: tab 53 is still on its page when tab 1 closes, so position
        // 53 now holds the old tab 54. The tab is found by its URL at 52; the
        // old tab 54 must never satisfy the wait.
        let fake = FakeSafari()
        fake.closeWindow1Tab1AfterFirstWindowRead = true
        await expectTimeout(["--for-url", "w1.example/54", "--timeout", "1500", "--url", "w1.example/53"], on: fake,
                            "the target never showed /54")
    }

    func testAShiftBetweenResolutionAndTheFirstPollIsNotTakenForTheNavigation() async {
        // Verify R2 (devil's advocate): with no baseline, the first poll saw
        // /54 at position 53, took it for the target's navigation and reported
        // success. The resolving enumeration is now the baseline.
        let fake = FakeSafari()
        fake.closeWindow1Tab1AfterEnumeration = true
        await expectTimeout(["--for-url", "w1.example/54", "--timeout", "1500", "--url", "w1.example/53"], on: fake,
                            "the target never showed /54")
    }

    func testATabToTheLeftClosingWhileTheTargetNavigatesFailsClosed() async {
        let fake = FakeSafari()
        fake.closeWindow1Tab1AfterFirstWindowRead = true
        fake.navigateTab53AfterFirstURLRead = true
        await expectTargetChanged(["--for-url", "/never", "--timeout", "3000", "--url", "w1.example/53"], on: fake,
                                  containing: "w1.example/53")
    }

    func testAClosedWindowFailsTheURLWaitWithTheTargetChangedError() async {
        // Verify R2: the fake answered an empty list for a missing window, so
        // Safari's own -1728 was never exercised.
        let fake = FakeSafari()
        fake.closeWindow1AfterFirstWindowRead = true
        await expectTargetChanged(["--for-url", "/never", "--timeout", "3000", "--url", "w1.example/53"], on: fake,
                                  containing: "w1.example/53")
    }

    func testWaitForJSOnTheDefaultTargetFailsClosedWhenAnotherTabBecomesCurrent() async {
        let fake = FakeSafari()
        fake.tripGuard = true
        await expectTargetChanged(["--js", "window.ready", "--timeout", "2000"], on: fake,
                                  containing: "front window's current tab")
    }

    func testWaitForJSOnAVanishedDocumentNamesTheTargetInsteadOfListingEveryTab() async {
        // Verify R2: the not-found translation lists every profile's tabs;
        // `--document N` was not mapped, so all of them reached the user.
        let fake = FakeSafari(failJSContaining: "window.ready")
        await expectTargetChanged(["--js", "window.ready", "--timeout", "2000", "--document", "5"], on: fake,
                                  containing: "document 5")
    }

    func testWaitForJSOnAVanishedWindowTabNamesTheTargetInsteadOfListingEveryTab() async {
        let fake = FakeSafari(failJSContaining: "window.ready")
        await expectTargetChanged(["--js", "window.ready", "--timeout", "2000", "--window", "1", "--tab-in-window", "5"],
                                  on: fake, containing: "window 1 tab 5")
    }

    func testURLWaitsKeepProbingForABlockingDialog() async {
        // Verify R2: the default target's URL read skipped the probe entirely,
        // and a --url wait probed only at resolution. The gate caches 2 s, so
        // a 2.6 s wait probes twice when every poll asks.
        for args in [["--for-url", "/never", "--timeout", "2600"],
                     ["--for-url", "/never", "--timeout", "2600", "--window", "2"],
                     ["--for-url", "/never", "--timeout", "2600", "--url", "w1.example/53"]] {
            let fake = FakeSafari()
            let probes = JSCommandRoundTripTests.ProbeCounter()
            do {
                try await runWait(args, on: fake, probe: { _ in probes.hit(); return .clear })
                XCTFail("\(args): expected a timeout")
            } catch SafariBrowserError.timeout {
            } catch {
                XCTFail("\(args): expected a timeout, got \(error)")
            }
            XCTAssertGreaterThanOrEqual(probes.count, 2, "\(args): \(probes.count) probes")
        }
    }

    func testPositionNamedTargetsAreReadAtTheirPosition() async {
        for (args, window) in [(["--document", "5"], "window id 101"),
                               (["--window", "1", "--tab-in-window", "53"], "window id 101")] {
            let fake = FakeSafari()
            await expectTimeout(["--for-url", "/never", "--timeout", "1200"] + args, on: fake, "\(args)")
            XCTAssertEqual(fake.enumerations, 1, "\(args): one resolution\n\(fake.transcript)")
            XCTAssertGreaterThanOrEqual(fake.windowURLReads.count, 2, "\(args)")
            XCTAssertTrue(fake.windowURLReads.allSatisfy { $0.contains(window) }, fake.transcript)
        }
    }

    func testTheSecondWindowsCurrentTabIsReadWithoutEnumerating() async {
        let fake = FakeSafari()
        await expectTimeout(["--for-url", "/never", "--timeout", "1200", "--window", "2"], on: fake, "never matches")
        XCTAssertEqual(fake.enumerations, 0, fake.transcript)
        XCTAssertTrue(fake.scripts.contains { $0.contains("set _w to window id 102") }, fake.transcript)
    }

    func testAnAmbiguousPatternIsRejectedAtResolution() async {
        let fake = FakeSafari()
        do {
            try await runWait(["--for-url", "/never", "--timeout", "1200", "--url", "example"], on: fake)
            XCTFail("every tab matches 'example'")
        } catch SafariBrowserError.ambiguousWindowMatch {
        } catch {
            XCTFail("expected ambiguousWindowMatch, got \(error)")
        }
        XCTAssertEqual(fake.windowURLReads.count, 0, "no poll after a failed resolution")
    }

    func testTheBaselineResolutionMatchesTheAnchoredOne() async throws {
        let fake = FakeSafari()
        try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
            let target = SafariBridge.TargetDocument.urlMatch(.contains("w1.example/53"))
            let anchored = try await SafariBridge.resolveToAnchoredTarget(target)
            let (withBaseline, urls) = try await SafariBridge.resolveURLTargetWithWindowURLs(target)
            XCTAssertEqual(String(describing: withBaseline), String(describing: anchored))
            XCTAssertEqual(urls?.count, 96)
            XCTAssertEqual(urls?[52], "https://w1.example/53")
        }
    }

    func testWindowURLReadEvaluatesTheListBeforeIteratingIt() async throws {
        // Live check: `repeat with u in (URL of every tab of window id W)` hands
        // out lazy element references that Safari refuses to resolve (-1700).
        let fake = FakeSafari()
        _ = try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
            try await SafariBridge.tabURLs(windowID: 101)
        }
        let script = try XCTUnwrap(fake.windowURLReads.first)
        XCTAssertTrue(script.contains("set urls to URL of every tab of window id 101"), script)
        XCTAssertTrue(script.contains("item i of urls"), script)
        XCTAssertFalse(script.contains("repeat with u in"), script)
    }

    func testAWaitWhoseResolutionOutlastsTheTimeoutStillPollsOnce() async throws {
        // The deadline starts before resolution. A resolution slower than the
        // whole timeout used to leave zero polls and a timeout, even when the
        // condition already held.
        let fake = FakeSafari()
        fake.enumerationDelay = 1.2
        try await runWait(["--for-url", "w1.example/53", "--timeout", "500", "--url", "w1.example/53"], on: fake)
    }

    // MARK: - #221: `--timeout` bounds when a poll may start, not how long the command takes

    private func elapsed(_ body: () async throws -> Void) async -> (seconds: TimeInterval, error: Error?) {
        let start = Date()
        do { try await body(); return (Date().timeIntervalSince(start), nil) }
        catch { return (Date().timeIntervalSince(start), error) }
    }

    /// A poll already running is not interrupted at the deadline, and what it answers counts. The
    /// fake's poll checks, after it has waited, whether its own task was cancelled: elapsed time
    /// alone cannot tell "not interrupted" from "cancelled, then waited for".
    func testAJSPollThatOutlastsTheTimeoutIsNotInterruptedAndItsAnswerCounts() async {
        let fake = FakeSafari()
        fake.javaScriptDelay = 0.8
        fake.waitJavaScriptAnswer = "true"
        let result = await elapsed { try await runWait(["--js", "window.ready", "--timeout", "300"], on: fake) }
        XCTAssertNil(result.error, "\(String(describing: result.error))")
        XCTAssertGreaterThanOrEqual(result.seconds, 0.75, "the poll ran to completion")
        XCTAssertEqual(fake.javaScripts.count, 1, fake.transcript)
        XCTAssertFalse(fake.aPollWasCancelled, "the poll's task was never cancelled")
    }

    /// The claim is about a poll that STARTED before the deadline, not only the first one (which is
    /// exempt anyway): poll 1 is quick and false, poll 2 starts before the deadline, outlasts it,
    /// and its answer counts.
    func testALaterJSPollThatOutlastsTheTimeoutIsNotInterruptedEither() async {
        let fake = FakeSafari()
        fake.waitPollDelays = [0, 2.0]
        fake.waitConditionHoldsFromPoll = 2
        let result = await elapsed { try await runWait(["--js", "window.ready", "--timeout", "1500"], on: fake) }
        XCTAssertNil(result.error, "\(String(describing: result.error))")
        XCTAssertEqual(fake.javaScripts.count, 2, fake.transcript)
        XCTAssertGreaterThanOrEqual(result.seconds, 2.4, "poll 2 started at about 0.5 s, a second before the deadline at 1.5 s, and took 2 s")
        XCTAssertFalse(fake.aPollWasCancelled)
    }

    /// The last poll outlasting the deadline ends the wait; no further poll starts.
    func testNoJSPollStartsAfterTheDeadlineEvenWhenTheLastOneOutlastedIt() async {
        let fake = FakeSafari()
        fake.javaScriptDelay = 0.8
        let result = await elapsed { try await runWait(["--js", "window.ready", "--timeout", "300"], on: fake) }
        guard case SafariBrowserError.timeout? = result.error else { return XCTFail("expected a timeout, got \(String(describing: result.error))") }
        XCTAssertGreaterThanOrEqual(result.seconds, 0.75, "the poll in flight was not interrupted at 300 ms")
        XCTAssertEqual(fake.javaScripts.count, 1, "no second poll after the deadline:\n\(fake.transcript)")
        XCTAssertFalse(fake.aPollWasCancelled)
    }

    func testAURLPollThatOutlastsTheTimeoutIsNotInterruptedAndItsAnswerCounts() async {
        let fake = FakeSafari()
        fake.windowURLReadDelay = 0.8
        let result = await elapsed {
            try await runWait(["--for-url", "w1.example/53", "--timeout", "300", "--url", "w1.example/53"], on: fake)
        }
        XCTAssertNil(result.error, "\(String(describing: result.error))")
        XCTAssertGreaterThanOrEqual(result.seconds, 0.75, "the poll ran to completion")
        XCTAssertEqual(fake.windowURLReads.count, 1, fake.transcript)
        XCTAssertFalse(fake.aPollWasCancelled, "the poll's task was never cancelled")
    }

    /// The same for a poll that STARTED before the deadline and is not the first: poll 1 answers
    /// the old URL at once, poll 2 starts at about 0.5 s, outlasts the deadline, and sees the
    /// navigation the wait is for.
    func testALaterURLPollThatOutlastsTheTimeoutIsNotInterruptedEither() async {
        let fake = FakeSafari()
        fake.navigateTab53AfterFirstURLRead = true
        fake.windowURLReadDelays = [0, 2.0]
        let result = await elapsed {
            try await runWait(["--for-url", "/done", "--timeout", "1500", "--url", "w1.example/53"], on: fake)
        }
        XCTAssertNil(result.error, "\(String(describing: result.error))")
        XCTAssertEqual(fake.windowURLReads.count, 2, fake.transcript)
        XCTAssertGreaterThanOrEqual(result.seconds, 2.4, "poll 2 started at about 0.5 s and took 2 s")
        XCTAssertFalse(fake.aPollWasCancelled)
    }

    func testNoURLPollStartsAfterTheDeadlineEvenWhenTheLastOneOutlastedIt() async {
        let fake = FakeSafari()
        fake.windowURLReadDelay = 0.8
        let result = await elapsed {
            try await runWait(["--for-url", "never-matches", "--timeout", "300", "--url", "w1.example/53"], on: fake)
        }
        guard case SafariBrowserError.timeout? = result.error else { return XCTFail("expected a timeout, got \(String(describing: result.error))") }
        XCTAssertGreaterThanOrEqual(result.seconds, 0.75)
        XCTAssertEqual(fake.windowURLReads.count, 1, "no second poll after the deadline:\n\(fake.transcript)")
        XCTAssertFalse(fake.aPollWasCancelled)
    }

    /// A call that reaches its own limit ends the wait with that call's error; the wait does not
    /// go on polling until `--timeout`, and does not report the `--timeout` error.
    func testACallThatReachesItsOwnLimitEndsTheWaitWithThatError() async {
        let fake = FakeSafari(failJSContaining: "window.ready")
        fake.failWithTimeout = true
        let result = await elapsed { try await runWait(["--js", "window.ready", "--timeout", "5000"], on: fake) }
        guard case SafariBrowserError.processTimedOut? = result.error else { return XCTFail("expected the call's own timeout error, got \(String(describing: result.error))") }
        XCTAssertEqual(fake.javaScripts.count, 1, fake.transcript)
    }

    /// The same for a `--for-url` poll, which has its own error handling around the read.
    func testAURLPollCallThatReachesItsOwnLimitEndsTheWaitWithThatError() async {
        let fake = FakeSafari()
        fake.windowURLReadError = SafariBrowserError.processTimedOut(command: "owned-url-fixture", seconds: 30)
        let result = await elapsed {
            try await runWait(["--for-url", "never-matches", "--timeout", "5000", "--url", "w1.example/53"], on: fake)
        }
        guard case SafariBrowserError.processTimedOut? = result.error else { return XCTFail("expected the call's own timeout error, got \(String(describing: result.error))") }
        XCTAssertEqual(fake.windowURLReads.count, 1, fake.transcript)
    }

    /// The daemon client's answer to a request that was sent and not answered is not a
    /// `SafariBrowserError`, so it passes the polls' own error handling; it must reach the person as
    /// it is, not as a `--timeout` error and not swallowed into more polling.
    func testAnUnansweredDaemonRequestEndsTheWaitWithThatErrorUnchanged() async {
        let unknown = DaemonClient.Error.requestOutcomeUnknown("timeout")
        let js = FakeSafari()
        js.waitPollError = unknown
        let jsResult = await elapsed { try await runWait(["--js", "window.ready", "--timeout", "5000"], on: js) }
        guard case DaemonClient.Error.requestOutcomeUnknown("timeout")? = jsResult.error else { return XCTFail("js: \(String(describing: jsResult.error))") }
        XCTAssertEqual(js.javaScripts.count, 1, js.transcript)

        let url = FakeSafari()
        url.windowURLReadError = unknown
        let urlResult = await elapsed {
            try await runWait(["--for-url", "never-matches", "--timeout", "5000", "--url", "w1.example/53"], on: url)
        }
        guard case DaemonClient.Error.requestOutcomeUnknown("timeout")? = urlResult.error else { return XCTFail("url: \(String(describing: urlResult.error))") }
        XCTAssertEqual(url.windowURLReads.count, 1, url.transcript)
    }

    /// `--timeout 0` or a negative value polls once, for both kinds of wait, and a resolution that
    /// used up the timeout does not remove that first poll from a JS wait either.
    func testATimeoutOfZeroOrLessPollsOnceAndAJSFirstPollAlwaysRuns() async throws {
        for timeout in ["0", "-5"] {
            let js = FakeSafari()
            let jsResult = await elapsed { try await runWait(["--js", "window.ready", "--timeout=\(timeout)"], on: js) }
            guard case SafariBrowserError.timeout? = jsResult.error else { return XCTFail("js \(timeout): \(String(describing: jsResult.error))") }
            XCTAssertEqual(js.javaScripts.count, 1, "js --timeout \(timeout):\n\(js.transcript)")

            let url = FakeSafari()
            let urlResult = await elapsed {
                try await runWait(["--for-url", "never-matches", "--timeout=\(timeout)", "--url", "w1.example/53"], on: url)
            }
            guard case SafariBrowserError.timeout? = urlResult.error else { return XCTFail("url \(timeout): \(String(describing: urlResult.error))") }
            XCTAssertEqual(url.windowURLReads.count, 1, "for-url --timeout \(timeout):\n\(url.transcript)")
        }
        let slow = FakeSafari()
        slow.enumerationDelay = 1.0
        slow.waitJavaScriptAnswer = "true"
        try await runWait(["--js", "window.ready", "--timeout", "300", "--url", "w1.example/53"], on: slow)
        XCTAssertEqual(slow.javaScripts.count, 1, "the resolution used up the timeout and the condition held")
    }

    /// A process timeout of a `--js` poll's call ends the wait with the blocking-dialog error when
    /// a dialog is found; the same timeout of a `--for-url` poll ends it with the call's own error,
    /// because the dialog check runs only for the JS read; and an unanswered daemon request is
    /// not turned into the dialog error for either (the check is for a process timeout). This
    /// pins existing behaviour; the spec does not state it.
    func testTheDialogErrorAfterALimitIsForJSPollsOnly() async {
        let dialog = SafariBridge.BlockingDialog(message: "owned", buttons: ["OK"])
        let js = FakeSafari(failJSContaining: "window.ready")
        js.failWithTimeout = true
        do {
            try await runWait(["--js", "window.ready", "--timeout", "5000"], on: js,
                              probe: { _ in js.scripts.contains { $0.contains("window.ready") } ? .present(dialog) : .clear })
            XCTFail("--js: expected an error")
        } catch SafariBrowserError.javaScriptDialogBlocking {
        } catch { XCTFail("--js: expected the blocking-dialog error, got \(error)") }

        let url = FakeSafari()
        url.windowURLReadError = SafariBrowserError.processTimedOut(command: "owned-url-fixture", seconds: 30)
        do {
            try await runWait(["--for-url", "never-matches", "--timeout", "5000", "--url", "w1.example/53"], on: url,
                              probe: { _ in url.windowURLReads.isEmpty ? .clear : .present(dialog) })
            XCTFail("--for-url: expected an error")
        } catch SafariBrowserError.processTimedOut {
        } catch { XCTFail("--for-url: expected the call's own error, got \(error)") }

        let daemon = FakeSafari()
        daemon.waitPollError = DaemonClient.Error.requestOutcomeUnknown("timeout")
        do {
            try await runWait(["--js", "window.ready", "--timeout", "5000"], on: daemon,
                              probe: { _ in daemon.scripts.contains { $0.contains("window.ready") } ? .present(dialog) : .clear })
            XCTFail("daemon: expected an error")
        } catch DaemonClient.Error.requestOutcomeUnknown("timeout") {
        } catch { XCTFail("daemon: expected the outcome-unknown error unchanged, got \(error)") }
    }

    /// `resolution time counts against --timeout` for a `--for-url` wait too: were the deadline taken
    /// after the resolution, this wait would run for the resolution PLUS the timeout.
    func testTheDeadlineStartsBeforeTheTargetIsResolvedForAURLWaitToo() async {
        let fake = FakeSafari()
        fake.enumerationDelay = 0.8
        let result = await elapsed {
            try await runWait(["--for-url", "never-matches", "--timeout", "1000", "--url", "w1.example/53"], on: fake)
        }
        guard case SafariBrowserError.timeout? = result.error else { return XCTFail("expected a timeout, got \(String(describing: result.error))") }
        XCTAssertGreaterThanOrEqual(result.seconds, 0.95)
        XCTAssertLessThan(result.seconds, 1.5, "0.8 s of resolution plus the 1 s timeout would be 1.8 s")
    }

    /// The sleeps the wait asks for, exactly, on a clock that moves only when it sleeps: after an
    /// unsatisfied poll it asks for the usual 500 ms, or for what is left until the deadline when
    /// that is less, and it asks for nothing once the deadline has been reached — so no poll
    /// starts at the deadline. One table, for the three ways a poll reads: `--js`, `--for-url` on
    /// a `--url` target, and `--for-url` on the default target.
    func testTheSleepsAreExactlyWhatIsLeftUntilTheDeadline() async {
        let ms: UInt64 = 1_000_000
        // Timeouts that are exact in binary (quarter seconds), so that the virtual clock and the
        // deadline agree to the nanosecond: with a timeout such as 1200 ms the floating-point
        // remainder is a fraction of a nanosecond, which asks for a sleep of zero.
        let cases: [(timeout: String, sleeps: [UInt64], polls: Int)] = [
            ("0", [], 1), ("-5", [], 1),
            ("250", [250 * ms], 1),
            ("500", [500 * ms], 1),
            ("750", [500 * ms, 250 * ms], 2),
            ("1250", [500 * ms, 500 * ms, 250 * ms], 3),
        ]
        for (timeout, sleeps, polls) in cases {
            let js = FakeSafari()
            let jsRun = await virtualRun(["--js", "window.ready", "--timeout=\(timeout)"], on: js)
            guard case SafariBrowserError.timeout? = jsRun.error else { XCTFail("js \(timeout): \(String(describing: jsRun.error))"); continue }
            XCTAssertEqual(jsRun.requests, sleeps, "js --timeout \(timeout)")
            XCTAssertEqual(js.javaScripts.count, polls, "js --timeout \(timeout):\n\(js.transcript)")

            let url = FakeSafari()
            let urlRun = await virtualRun(["--for-url", "never-matches", "--timeout=\(timeout)", "--url", "w1.example/53"], on: url)
            guard case SafariBrowserError.timeout? = urlRun.error else { XCTFail("for-url \(timeout): \(String(describing: urlRun.error))"); continue }
            XCTAssertEqual(urlRun.requests, sleeps, "--for-url --timeout \(timeout)")
            XCTAssertEqual(url.windowURLReads.count, polls, "--for-url --timeout \(timeout):\n\(url.transcript)")

            let current = FakeSafari()
            let currentRun = await virtualRun(["--for-url", "never-matches", "--timeout=\(timeout)"], on: current)
            guard case SafariBrowserError.timeout? = currentRun.error else { XCTFail("default target \(timeout): \(String(describing: currentRun.error))"); continue }
            XCTAssertEqual(currentRun.requests, sleeps, "--for-url on the default target, --timeout \(timeout)")
        }
    }

    /// A poll that runs past the deadline is not followed by a sleep, and no further poll starts:
    /// the time left is read AFTER the poll, not before it. A poll of 0.75 s against a 0.25 s
    /// timeout asks for no sleep at all; against a 1.25 s timeout it is followed by a sleep of
    /// what is left of the deadline and by one more poll.
    func testAPollThatRunsPastTheDeadlineIsNotFollowedByASleep() async {
        let ms: UInt64 = 1_000_000
        let slow = FakeSafari()
        let past = await virtualRun(["--js", "window.ready", "--timeout", "250"], on: slow, pollCost: 750 * ms)
        guard case SafariBrowserError.timeout? = past.error else { return XCTFail("expected a timeout, got \(String(describing: past.error))") }
        XCTAssertEqual(past.requests, [], "the deadline passed during the poll: nothing to sleep for")
        XCTAssertEqual(slow.javaScripts.count, 1, slow.transcript)

        let inside = FakeSafari()
        let partly = await virtualRun(["--js", "window.ready", "--timeout", "1250"], on: inside, pollCost: 750 * ms)
        guard case SafariBrowserError.timeout? = partly.error else { return XCTFail("expected a timeout, got \(String(describing: partly.error))") }
        // poll 1 ends at 0.75 s: sleep 0.5 s (to 1.25 s, the deadline); no poll starts at the deadline.
        XCTAssertEqual(partly.requests, [500 * ms], "the time left after the poll, not before it")
        XCTAssertEqual(inside.javaScripts.count, 1, inside.transcript)
    }

    /// The default is stated in the help and in the `Default timeout` requirement.
    func testTheDefaultTimeoutIsThirtySeconds() throws {
        XCTAssertEqual(try WaitCommand.parse(["--js", "x"]).timeout, 30000)
        XCTAssertEqual(try WaitCommand.parse(["--for-url", "x"]).timeout, 30000)
    }

    /// The help sentence the spec requires. ArgumentParser wraps help at the terminal width, so a
    /// phrase can be split by a line break: compare with whitespace normalised.
    func testTheHelpSaysTheCommandCanEndLaterThanTheTimeout() {
        let help = WaitCommand.helpMessage().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(help.contains("can end later than --timeout"), help)
        XCTAssertTrue(help.contains("not cut short by --timeout"), help)
        XCTAssertTrue(help.contains("a poll after the first"), help)
    }

    /// The deadline is taken before the target is resolved, so a slow resolution counts against
    /// `--timeout`. Were it taken afterwards, this wait would run for the resolution PLUS the timeout.
    func testTheDeadlineStartsBeforeTheTargetIsResolved() async {
        let fake = FakeSafari()
        fake.enumerationDelay = 0.8
        let result = await elapsed {
            try await runWait(["--js", "window.ready", "--timeout", "1000", "--url", "w1.example/53"], on: fake)
        }
        guard case SafariBrowserError.timeout? = result.error else { return XCTFail("expected a timeout, got \(String(describing: result.error))") }
        XCTAssertGreaterThanOrEqual(result.seconds, 0.95)
        XCTAssertLessThan(result.seconds, 1.5, "0.8 s of resolution plus the 1 s timeout would be 1.8 s")
    }

    func testDefaultTargetWaitNeverEnumerates() async {
        let fake = FakeSafari()
        do {
            try await runWait(["--js", "window.ready", "--timeout", "1200"], on: fake)
            XCTFail("expected a timeout")
        } catch SafariBrowserError.timeout {
        } catch {
            XCTFail("expected a timeout, got \(error)")
        }
        XCTAssertEqual(fake.enumerations, 0, fake.transcript)
        XCTAssertEqual(fake.anchors.count, 1, "one anchor for the whole wait:\n\(fake.transcript)")
    }

    // MARK: - WaitURLAnchor (pure)

    private func urls(_ list: [Int]) -> [String] { list.map { "https://w1.example/\($0)" } }
    private func follow(_ tab: Int, in list: [Int]) throws -> WaitURLAnchor {
        try XCTUnwrap(WaitURLAnchor(following: tab, in: urls(list)))
    }

    func testTheSameTabIsReadWhileNothingToItsLeftChanges() throws {
        var anchor = try follow(3, in: [51, 52, 53, 54])
        XCTAssertEqual(try anchor.url(in: urls([51, 52, 53, 54])), "https://w1.example/53")
        XCTAssertEqual(try anchor.url(in: urls([51, 52, 53, 54, 55])), "https://w1.example/53", "a tab opened on the right")
        XCTAssertEqual(try anchor.url(in: urls([51, 52, 53])), "https://w1.example/53", "a tab closed on the right")
    }

    func testTheFirstReadIsComparedWithTheResolvingEnumeration() throws {
        // Tab 51 closed between resolution and the first poll: position 3 is
        // now tab 54. The tab is found at 2 by its URL.
        var anchor = try follow(3, in: [51, 52, 53, 54])
        XCTAssertEqual(try anchor.url(in: urls([52, 53, 54])), "https://w1.example/53")
        XCTAssertEqual(try anchor.url(in: urls([52, 53, 54])), "https://w1.example/53")
    }

    func testAMovedTabIsFoundByItsURL() throws {
        var opened = try follow(3, in: [51, 52, 53, 54])
        XCTAssertEqual(try opened.url(in: urls([50, 51, 52, 53, 54])), "https://w1.example/53", "a tab opened on the left")
        var dragged = try follow(3, in: [51, 52, 53, 54])
        XCTAssertEqual(try dragged.url(in: urls([53, 51, 52, 54])), "https://w1.example/53", "dragged to the front")
        var besides = try follow(3, in: [51, 52, 53, 54])
        XCTAssertEqual(try besides.url(in: urls([51, 52, 99, 53, 54])), "https://w1.example/53", "a tab opened right before it")
    }

    func testANavigationWithEverythingElseInPlaceIsFollowed() throws {
        var anchor = try follow(3, in: [51, 52, 53, 54])
        let navigated = ["https://w1.example/51", "https://w1.example/52", "https://w1.example/done", "https://w1.example/54"]
        XCTAssertEqual(try anchor.url(in: navigated), "https://w1.example/done")
        // After it, the navigated tab is followed like any other (the #188 case).
        XCTAssertEqual(try anchor.url(in: ["https://w1.example/new"] + navigated), "https://w1.example/done")
    }

    func testANavigationWhileTabsToItsLeftChangedFailsClosed() throws {
        var anchor = try follow(3, in: [51, 52, 53, 54])
        XCTAssertThrowsError(try anchor.url(in: ["https://w1.example/52", "https://w1.example/done", "https://w1.example/54"]))
        var sameCount = try follow(3, in: [51, 52, 53, 54])
        XCTAssertThrowsError(try sameCount.url(in: urls([50, 52, 99, 54])), "a left tab changed too: it may have been a move")
    }

    func testANavigationWhileTheTabCountChangedFailsClosed() throws {
        // The same observation is a navigation plus a tab opened on the right, or
        // the target closing and another tab taking its place: it cannot be told
        // apart, so the wait fails closed, as the spec says (the tab count must be
        // unchanged for a position showing another URL to count as a navigation).
        var anchor = try follow(3, in: [51, 52, 53, 54])
        XCTAssertThrowsError(try anchor.url(in: urls([51, 52, 99, 54, 55])))
    }

    func testAWindowThatShrinksByMoreThanOneTabFailsClosedInsteadOfTrapping() throws {
        // Codex, round 3: the right-shift comparison sliced the new list with the
        // old list's bound, so a window that lost the target and several tabs to
        // its right in one interval crashed the process (array bounds).
        var anchor = try follow(2, in: [51, 52, 53, 54, 55])
        XCTAssertThrowsError(try anchor.url(in: urls([51])), "only tab 1 is left")
        var toTwo = try follow(2, in: [51, 52, 53, 54, 55])
        XCTAssertThrowsError(try toTwo.url(in: urls([51, 99])))
        var toZero = try follow(3, in: [51, 52, 53])
        XCTAssertThrowsError(try toZero.url(in: []), "the window has no tabs")
    }

    func testANavigationWithRepeatedURLsAndAnUnchangedLeftIsFollowed() throws {
        // Tab 3 and tab 5 show the same page. Tab 3 navigates and nothing else
        // changes, so it is the navigation; the copy at tab 5 does not matter.
        var anchor = try follow(3, in: [51, 52, 53, 54, 53])
        XCTAssertEqual(try anchor.url(in: ["https://w1.example/51", "https://w1.example/52", "https://w1.example/done",
                                           "https://w1.example/54", "https://w1.example/53"]), "https://w1.example/done")
    }

    func testARepeatedURLDoesNotBypassTheLeftCheck() throws {
        // Codex and haiku, round 3, read `a, b, c, d || e` as `(a && b && c && d) || e`.
        // Commas separate conditions, so `||` applies to the last one only; this pins
        // that a non-unique old URL still needs an unchanged left and an unchanged count.
        var leftChanged = try follow(3, in: [51, 52, 53, 54, 53])
        XCTAssertThrowsError(try leftChanged.url(in: ["https://w1.example/50", "https://w1.example/52", "https://w1.example/done",
                                                      "https://w1.example/54", "https://w1.example/53"]))
        var countChanged = try follow(3, in: [51, 52, 53, 54, 53])
        XCTAssertThrowsError(try countChanged.url(in: ["https://w1.example/51", "https://w1.example/52", "https://w1.example/done",
                                                       "https://w1.example/54", "https://w1.example/53", "https://w1.example/new"]))
    }

    func testEveryPairOfSmallWindowListsEitherThrowsOrReturnsAURLThatExists() throws {
        // Exhaustive over small windows: 0-4 tabs, URLs drawn from {a, b, c, ""}
        // (an empty string is what a tab without a URL reads as). For every
        // previous list, every tracked position and every current list, the
        // anchor must neither trap nor return a URL that is not in the current
        // list. This is what the hand-picked cases missed (the shrink trap).
        let alphabet = ["https://w1.example/a", "https://w1.example/b", "https://w1.example/c", ""]
        func lists(upTo n: Int) -> [[String]] {
            var out: [[String]] = [[]]
            var level: [[String]] = [[]]
            for _ in 0..<n {
                level = level.flatMap { prefix in alphabet.map { prefix + [$0] } }
                out += level
            }
            return out
        }
        let all = lists(upTo: 4)
        var checked = 0, followed = 0
        for previous in all where !previous.isEmpty {
            for tab in 1...previous.count {
                for current in all {
                    var anchor = try XCTUnwrap(WaitURLAnchor(following: tab, in: previous))
                    checked += 1
                    if let url = try? anchor.url(in: current) {
                        followed += 1
                        XCTAssertTrue(current.contains(url), "returned \(url) not in \(current) (was \(previous), tab \(tab))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 10_000)
        XCTAssertGreaterThan(followed, 0)
    }

    func testAUniqueURLThatStaysUniqueIsFollowedToItsNewPositionOrNotAtAll() throws {
        // The property behind "found by its URL": when the tracked URL was shown by
        // exactly one tab and is shown by exactly one tab now, the anchor either
        // returns it or fails closed because the tab itself navigated at the same
        // time; it never returns a different URL.
        let alphabet = ["https://w1.example/a", "https://w1.example/b", "https://w1.example/c", "https://w1.example/d"]
        func lists(upTo n: Int) -> [[String]] {
            var out: [[String]] = [[]]
            var level: [[String]] = [[]]
            for _ in 0..<n { level = level.flatMap { prefix in alphabet.map { prefix + [$0] } }; out += level }
            return out
        }
        let all = lists(upTo: 4)
        var confirmed = 0
        for previous in all where !previous.isEmpty {
            for tab in 1...previous.count {
                let last = previous[tab - 1]
                guard previous.filter({ $0 == last }).count == 1 else { continue }
                for current in all where current.filter({ $0 == last }).count == 1 {
                    var anchor = try XCTUnwrap(WaitURLAnchor(following: tab, in: previous))
                    let url = try anchor.url(in: current)
                    XCTAssertEqual(url, last, "unique \(last) in \(previous) at \(tab), now \(current)")
                    confirmed += 1
                }
            }
        }
        XCTAssertGreaterThan(confirmed, 100)
    }

    func testNavigatingToTheRightNeighboursURLIsIndistinguishableFromAClosureAndFailsClosed() throws {
        // [A, B, C] -> [A, C, C]: tab 2 navigated to C, or tab 2 closed and a tab
        // showing C opened at the end. The observation is the same, so the wait
        // fails closed (it is documented in the spec) rather than guessing.
        var anchor = try follow(2, in: [1, 2, 3])
        XCTAssertThrowsError(try anchor.url(in: ["https://w1.example/1", "https://w1.example/3", "https://w1.example/3"]))
    }

    func testAClosedTargetFailsClosed() throws {
        var closed = try follow(3, in: [51, 52, 53, 54, 55])
        XCTAssertThrowsError(try closed.url(in: urls([51, 52, 54, 55])), "it closed: the tabs to its right moved left")
        var replaced = try follow(3, in: [51, 52, 53, 54, 55])
        XCTAssertThrowsError(try replaced.url(in: urls([51, 52, 54, 55, 99])), "it closed and a tab opened at the end")
        var gone = try follow(4, in: [51, 52, 53, 54])
        XCTAssertThrowsError(try gone.url(in: urls([51, 52, 53])), "the last tab closed")
    }

    func testATabWhoseURLAnotherTabSharesIsNotFollowedByThatURL() throws {
        // Tab 3 and tab 5 both show /53. After tab 51 closes, /53 shows twice:
        // which one is the target cannot be told.
        var anchor = try follow(3, in: [51, 52, 53, 54, 53])
        XCTAssertThrowsError(try anchor.url(in: urls([52, 53, 54, 53])))
        // With nothing to its left changed, it is still read in place, and its
        // navigation is still seen.
        var inPlace = try follow(3, in: [51, 52, 53, 54, 53])
        XCTAssertEqual(try inPlace.url(in: urls([51, 52, 53, 54, 53])), "https://w1.example/53")
        XCTAssertEqual(try inPlace.url(in: urls([51, 52, 99, 54, 53])), "https://w1.example/99")
    }

    func testAPositionNamedTabIsReadAtItsPosition() throws {
        var anchor = WaitURLAnchor(position: 3)
        XCTAssertEqual(try anchor.url(in: urls([51, 52, 53, 54])), "https://w1.example/53")
        XCTAssertEqual(try anchor.url(in: urls([51, 52, 53])), "https://w1.example/53", "a tab closed on the right")
        XCTAssertThrowsError(try anchor.url(in: urls([51, 52])), "the position ran past the end")
    }

    func testAnAnchorOutsideItsWindowIsRefused() {
        XCTAssertNil(WaitURLAnchor(following: 5, in: urls([51, 52, 53])))
        XCTAssertNil(WaitURLAnchor(following: 0, in: urls([51])))
    }
}
