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

    // MARK: - Input validation (#19 follow-up: F1/F5)

    func testRunShellRejectsNegativeTimeout() async throws {
        do {
            _ = try await SafariBridge.runShell("/bin/echo", ["hi"], timeout: -1.0)
            XCTFail("Expected invalidTimeout but runShell returned normally")
        } catch let error as SafariBrowserError {
            guard case .invalidTimeout(let value) = error else {
                XCTFail("Expected .invalidTimeout but got \(error)")
                return
            }
            XCTAssertEqual(value, -1.0)
        }
    }

    func testRunShellRejectsZeroTimeout() async throws {
        do {
            _ = try await SafariBridge.runShell("/bin/echo", ["hi"], timeout: 0)
            XCTFail("Expected invalidTimeout but runShell returned normally")
        } catch let error as SafariBrowserError {
            guard case .invalidTimeout = error else {
                XCTFail("Expected .invalidTimeout but got \(error)")
                return
            }
        }
    }

    func testRunShellRejectsNaNTimeout() async throws {
        do {
            _ = try await SafariBridge.runShell("/bin/echo", ["hi"], timeout: .nan)
            XCTFail("Expected invalidTimeout but runShell returned normally")
        } catch let error as SafariBrowserError {
            guard case .invalidTimeout = error else {
                XCTFail("Expected .invalidTimeout but got \(error)")
                return
            }
        }
    }

    func testRunShellRejectsInfiniteTimeout() async throws {
        do {
            _ = try await SafariBridge.runShell("/bin/echo", ["hi"], timeout: .infinity)
            XCTFail("Expected invalidTimeout but runShell returned normally")
        } catch let error as SafariBrowserError {
            guard case .invalidTimeout = error else {
                XCTFail("Expected .invalidTimeout but got \(error)")
                return
            }
        }
    }

    // MARK: - Round 2 follow-up: R2-F1' huge finite + R2-F1'' sub-nanosecond (#19)

    func testRunShellRejectsGreatestFiniteMagnitude() async throws {
        // `.greatestFiniteMagnitude` ≈ 1.8e308 is finite and > 0, but
        // multiplying by 1e9 overflows to +Inf, and UInt64(.infinity) traps.
        // Guard must reject this BEFORE the multiplication.
        do {
            _ = try await SafariBridge.runShell(
                "/bin/echo",
                ["hi"],
                timeout: .greatestFiniteMagnitude
            )
            XCTFail("Expected invalidTimeout but runShell returned normally")
        } catch let error as SafariBrowserError {
            guard case .invalidTimeout = error else {
                XCTFail("Expected .invalidTimeout but got \(error)")
                return
            }
        }
    }

    func testRunShellRejectsExcessivelyLargeTimeout() async throws {
        // A year's worth of seconds is clearly beyond any legitimate subprocess
        // and pushes timeout * 1e9 perilously close to UInt64 overflow.
        do {
            _ = try await SafariBridge.runShell(
                "/bin/echo",
                ["hi"],
                timeout: 1e300
            )
            XCTFail("Expected invalidTimeout but runShell returned normally")
        } catch let error as SafariBrowserError {
            guard case .invalidTimeout = error else {
                XCTFail("Expected .invalidTimeout but got \(error)")
                return
            }
        }
    }

    func testRunShellRejectsSubNanosecondTimeout() async throws {
        // Sub-nanosecond positive values (< 1e-9) round to 0 nanoseconds,
        // causing the watchdog to fire instantly. Semantically invalid —
        // reject as invalidTimeout rather than silently SIGKILLing everything.
        do {
            _ = try await SafariBridge.runShell(
                "/bin/echo",
                ["hi"],
                timeout: 1e-12
            )
            XCTFail("Expected invalidTimeout but runShell returned normally")
        } catch let error as SafariBrowserError {
            guard case .invalidTimeout = error else {
                XCTFail("Expected .invalidTimeout but got \(error)")
                return
            }
        }
    }

    // MARK: - Signal attribution (#19 follow-up: F2)

    func testRunShellDoesNotReportSelfKillAsTimeout() async throws {
        // Child kills itself with SIGTERM via `kill -TERM $$`. This should
        // NOT be reported as a timeout — only the watchdog's kill counts.
        do {
            _ = try await SafariBridge.runShell(
                "/bin/sh",
                ["-c", "kill -TERM $$"],
                timeout: 10.0
            )
            XCTFail("Expected error but runShell returned normally")
        } catch let error as SafariBrowserError {
            if case .processTimedOut = error {
                XCTFail("External SIGTERM was misreported as processTimedOut — F2 regression")
                return
            }
            // .appleScriptFailed is the expected path (non-zero exit / signal exit)
            guard case .appleScriptFailed = error else {
                XCTFail("Expected .appleScriptFailed but got \(error)")
                return
            }
        }
    }
}
