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

    func testDefaultTargetWaitNeverEnumerates() async {
        let fake = FakeSafari()
        do {
            try await runWait(["--js", "window.ready", "--timeout", "1200"], on: fake)
            XCTFail("expected a timeout")
        } catch {}
        XCTAssertEqual(fake.enumerations, 0, fake.transcript)
        XCTAssertEqual(fake.anchors.count, 1, "one anchor for the whole wait:\n\(fake.transcript)")
    }
}
