import XCTest
@testable import SafariBrowser

final class SystemEventsProbeTests: XCTestCase {

    // MARK: - Wrapping: runShell errors become SystemEventsNotResponding (#20)

    func testProbeSystemEventsWrapsTimeoutAsNotResponding() async throws {
        // `delay 10` hangs osascript for 10 seconds. With a 0.5s probe timeout,
        // runShell's watchdog fires first and throws .processTimedOut. The probe
        // must catch that and re-throw as .systemEventsNotResponding so callers
        // get a consistent error type regardless of the underlying failure mode.
        do {
            try await SafariBridge.probeSystemEvents(
                script: "delay 10",
                timeout: 0.5
            )
            XCTFail("Expected systemEventsNotResponding but probe returned normally")
        } catch let error as SafariBrowserError {
            guard case .systemEventsNotResponding = error else {
                XCTFail("Expected .systemEventsNotResponding but got \(error)")
                return
            }
        }
    }

    func testProbeSystemEventsWrapsAppleScriptErrorAsNotResponding() async throws {
        // A malformed AppleScript causes osascript to exit non-zero, which
        // runShell reports as .appleScriptFailed. The probe must wrap this as
        // .systemEventsNotResponding too — any failure to talk to the script
        // host is effectively "System Events probe failed".
        do {
            try await SafariBridge.probeSystemEvents(
                script: "this is not valid applescript",
                timeout: 5.0
            )
            XCTFail("Expected systemEventsNotResponding but probe returned normally")
        } catch let error as SafariBrowserError {
            guard case .systemEventsNotResponding = error else {
                XCTFail("Expected .systemEventsNotResponding but got \(error)")
                return
            }
        }
    }

    func testProbeSystemEventsReturnsNormallyForTrivialScript() async throws {
        // Any trivially successful AppleScript should let the probe return
        // normally. This exercises the happy path without depending on the
        // real "tell application System Events" call, which might be flaky in
        // sandboxed test environments.
        try await SafariBridge.probeSystemEvents(
            script: "return \"ok\"",
            timeout: 5.0
        )
    }
}
