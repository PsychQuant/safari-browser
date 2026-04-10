import XCTest
@testable import SafariBrowser

final class SafariBridgeTimeoutTests: XCTestCase {

    func testRunShellReturnsOutputWhenUnderTimeout() async throws {
        let result = try await SafariBridge.runShell(
            "/bin/echo",
            ["hello-timeout-test"],
            timeout: 5.0
        )
        XCTAssertEqual(result, "hello-timeout-test")
    }

    func testRunShellThrowsProcessTimedOutWhenSubprocessHangs() async throws {
        let start = Date()
        do {
            _ = try await SafariBridge.runShell(
                "/bin/sleep",
                ["60"],
                timeout: 1.0
            )
            XCTFail("Expected processTimedOut error but runShell returned normally")
        } catch let error as SafariBrowserError {
            guard case .processTimedOut(_, let seconds) = error else {
                XCTFail("Expected .processTimedOut but got \(error)")
                return
            }
            XCTAssertEqual(seconds, 1)
        }
        let elapsed = Date().timeIntervalSince(start)
        // Should terminate within timeout + SIGTERM grace (1s) + overhead
        XCTAssertLessThan(elapsed, 5.0, "Timeout took too long: \(elapsed)s")
    }

    func testRunShellPropagatesNonZeroExitWhenNotTimedOut() async throws {
        do {
            _ = try await SafariBridge.runShell(
                "/bin/sh",
                ["-c", "exit 2"],
                timeout: 5.0
            )
            XCTFail("Expected error but runShell returned normally")
        } catch let error as SafariBrowserError {
            guard case .appleScriptFailed = error else {
                XCTFail("Expected .appleScriptFailed but got \(error)")
                return
            }
        }
    }
}
