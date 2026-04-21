import XCTest
import Foundation
@testable import SafariBrowser

/// Task 5.1 — three-signal opt-in detection in `SafariBridge`.
/// Signals (any one true triggers daemon routing):
/// 1. `--daemon` CLI flag
/// 2. `SAFARI_BROWSER_DAEMON=1` environment variable
/// 3. Live daemon socket already exists for the resolved NAME
///
/// The default (all three false) MUST leave behaviour identical to the
/// pre-daemon stateless path.
final class DaemonOptInTests: XCTestCase {

    func testShouldUseDaemon_allSignalsOff_returnsFalse() {
        let result = SafariBridge.shouldUseDaemon(
            flag: false,
            env: [:],
            socketExists: { _ in false }
        )
        XCTAssertFalse(result)
    }

    func testShouldUseDaemon_flagOn_returnsTrue() {
        let result = SafariBridge.shouldUseDaemon(
            flag: true,
            env: [:],
            socketExists: { _ in false }
        )
        XCTAssertTrue(result)
    }

    func testShouldUseDaemon_envVarOne_returnsTrue() {
        let result = SafariBridge.shouldUseDaemon(
            flag: false,
            env: ["SAFARI_BROWSER_DAEMON": "1"],
            socketExists: { _ in false }
        )
        XCTAssertTrue(result)
    }

    func testShouldUseDaemon_envVarZero_returnsFalse() {
        // Explicit "0" MUST NOT opt in — "1" is the only accepted affirmative.
        let result = SafariBridge.shouldUseDaemon(
            flag: false,
            env: ["SAFARI_BROWSER_DAEMON": "0"],
            socketExists: { _ in false }
        )
        XCTAssertFalse(result)
    }

    func testShouldUseDaemon_envVarArbitrary_returnsFalse() {
        // Only "1" opts in. "true" / "yes" / "on" are all false to keep the
        // rule unambiguous and match the spec's literal "set to 1".
        for value in ["true", "yes", "on", "TRUE", "True"] {
            let result = SafariBridge.shouldUseDaemon(
                flag: false,
                env: ["SAFARI_BROWSER_DAEMON": value],
                socketExists: { _ in false }
            )
            XCTAssertFalse(result, "env value \(value) should not opt in")
        }
    }

    func testShouldUseDaemon_liveSocket_returnsTrue() {
        // If the resolved NAME's socket exists, the user has previously
        // started a daemon. Auto-opt-in so agents don't need to pass
        // --daemon on every command.
        let result = SafariBridge.shouldUseDaemon(
            flag: false,
            env: [:],
            socketExists: { path in
                path.contains("safari-browser-default.sock")
            }
        )
        XCTAssertTrue(result)
    }

    func testShouldUseDaemon_liveSocketForDifferentName_returnsFalse() {
        // A live socket for a DIFFERENT namespace must NOT opt in this
        // invocation — NAME namespace isolation applies to detection too.
        let result = SafariBridge.shouldUseDaemon(
            flag: false,
            env: ["SAFARI_BROWSER_NAME": "alpha"],
            socketExists: { path in
                // "beta" socket exists but we resolved name to "alpha"
                path.contains("safari-browser-beta.sock")
            }
        )
        XCTAssertFalse(result)
    }

    // MARK: - Combined signals are OR, not AND

    func testShouldUseDaemon_flagWinsEvenWhenEnvOff() {
        let result = SafariBridge.shouldUseDaemon(
            flag: true,
            env: ["SAFARI_BROWSER_DAEMON": "0"],
            socketExists: { _ in false }
        )
        XCTAssertTrue(result, "--daemon flag is explicit opt-in regardless of env")
    }
}
