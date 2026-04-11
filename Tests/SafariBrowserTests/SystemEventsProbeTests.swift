import XCTest
@testable import SafariBrowser

final class SystemEventsProbeTests: XCTestCase {

    override func setUp() async throws {
        // #20 F4: these tests spawn a real osascript subprocess. Sandboxed CI
        // runners may not have /usr/bin/osascript available — skip rather than
        // hang or report a confusing failure.
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript"),
            "osascript not available — these tests require macOS with AppleScript"
        )
    }

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

    // MARK: - F1: generic catch must wrap non-SafariBrowserError as well

    func testProbeSystemEventsWrapsNonSafariBrowserError() async throws {
        // If runShell throws something other than SafariBrowserError (e.g., a
        // CocoaError from Process.run() when the executable doesn't exist),
        // the probe must still wrap it as `.systemEventsNotResponding` so the
        // "one actionable error type" contract holds across all failure modes.
        do {
            try await SafariBridge.probeSystemEvents(
                executable: "/nonexistent/osascript",
                script: "return \"ok\"",
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
}
