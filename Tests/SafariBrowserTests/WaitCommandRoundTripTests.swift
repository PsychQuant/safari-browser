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

    private func runWait(_ args: [String], on fake: FakeSafari) async throws {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let command = try WaitCommand.parse(args)
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                try await command.run()
            }
        }
    }

    func testWaitForJSResolvesAURLTargetOnceAcrossPolls() async {
        let fake = FakeSafari()
        do {
            try await runWait(["--js", "window.ready", "--timeout", "1200", "--url", "w1.example/53"], on: fake)
            XCTFail("the condition never becomes true, so the wait must time out")
        } catch {
            // expected: timeout
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
        } catch {}
        XCTAssertGreaterThanOrEqual(fake.windowURLReads.count, 2, fake.transcript)
        XCTAssertTrue(fake.windowURLReads.allSatisfy { $0.contains("window id 101") }, fake.transcript)
        XCTAssertEqual(fake.enumerations, 1, fake.transcript)
    }

    func testWaitForURLFailsClosedWhenATabToTheLeftClosesBeforeTheTargetNavigates() async {
        // Tab 53 is still on its original page when tab 1 closes: position 53
        // now holds the old tab 54. Reading it would wait on the wrong tab.
        let fake = FakeSafari()
        fake.closeWindow1Tab1AfterFirstWindowRead = true
        do {
            try await runWait(["--for-url", "/never", "--timeout", "3000", "--url", "w1.example/53"], on: fake)
            XCTFail("a shifted tab must fail the wait")
        } catch SafariBrowserError.anchoredTargetChanged(let target) {
            XCTAssertTrue(target.contains("w1.example/53"), target)
        } catch {
            XCTFail("expected anchoredTargetChanged, got \(error)")
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

    func testDefaultTargetWaitNeverEnumerates() async {
        let fake = FakeSafari()
        do {
            try await runWait(["--js", "window.ready", "--timeout", "1200"], on: fake)
            XCTFail("expected a timeout")
        } catch {}
        XCTAssertEqual(fake.enumerations, 0, fake.transcript)
        XCTAssertEqual(fake.anchors.count, 1, "one anchor for the whole wait:\n\(fake.transcript)")
    }

    // MARK: - WaitURLAnchor (pure)

    private let matcher = SafariBridge.UrlMatcher.contains("example/53")
    private func urls(_ list: [Int]) -> [String] { list.map { "https://w1.example/\($0)" } }

    func testAnchorReadsItsTabWhileItStillShowsTheOriginalPage() throws {
        var anchor = WaitURLAnchor(tab: 3, matcher: matcher)
        XCTAssertEqual(try anchor.url(in: urls([51, 52, 53, 54])), "https://w1.example/53")
        XCTAssertEqual(try anchor.url(in: urls([51, 52, 53, 54, 55])), "https://w1.example/53", "a tab opened on the right is fine")
    }

    func testLeavingTheOriginalURLWithAnUnchangedTabListIsTheNavigation() throws {
        var anchor = WaitURLAnchor(tab: 3, matcher: matcher)
        _ = try anchor.url(in: urls([51, 52, 53, 54]))
        let navigated = ["https://w1.example/51", "https://w1.example/52", "https://w1.example/done", "https://w1.example/54"]
        XCTAssertEqual(try anchor.url(in: navigated), "https://w1.example/done")
        XCTAssertEqual(try anchor.url(in: navigated + ["https://w1.example/new"]), "https://w1.example/done")
    }

    func testLeavingTheOriginalURLWhileTheTabListChangedFailsClosed() {
        var anchor = WaitURLAnchor(tab: 3, matcher: matcher)
        _ = try? anchor.url(in: urls([51, 52, 53, 54]))
        XCTAssertThrowsError(try anchor.url(in: urls([52, 53, 54])), "tab 51 closed: position 3 is now tab 54")
    }

    func testAfterTheNavigationAShrinkingTabListFailsClosed() throws {
        var anchor = WaitURLAnchor(tab: 3, matcher: nil)
        _ = try anchor.url(in: urls([51, 52, 53, 54]))
        XCTAssertThrowsError(try anchor.url(in: urls([52, 53, 54])))
    }

    func testAPositionPastTheEndFailsClosed() {
        var anchor = WaitURLAnchor(tab: 5, matcher: nil)
        XCTAssertThrowsError(try anchor.url(in: urls([51, 52, 53])))
    }
}
