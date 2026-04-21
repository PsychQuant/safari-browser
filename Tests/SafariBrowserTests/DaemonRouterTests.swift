import XCTest
import Foundation
@testable import SafariBrowser

/// Task 5.2 — silent fallback router.
/// Verifies that `SafariBridge.runViaRouter(...)` calls the daemon-side
/// function when opted in, falls back to the stateless function on
/// fallback-worthy errors with a `[daemon fallback: <reason>]` stderr
/// warning, and propagates Safari domain errors (e.g. `ambiguousWindowMatch`)
/// without falling back.
final class DaemonRouterTests: XCTestCase {

    // MARK: - Opt-out bypasses daemon entirely

    func testRouter_optOut_callsStatelessOnly() async throws {
        actor CallRecorder {
            var statelessCalled = false
            var daemonCalled = false
            func markStateless() { statelessCalled = true }
            func markDaemon() { daemonCalled = true }
        }
        let recorder = CallRecorder()

        let result = try await SafariBridge.runViaRouter(
            source: "ignored",
            daemonOptIn: false,
            daemonFn: { _ in
                await recorder.markDaemon()
                return "unreachable"
            },
            statelessFn: { _ in
                await recorder.markStateless()
                return "stateless-result"
            },
            warnWriter: nil
        )

        XCTAssertEqual(result, "stateless-result")
        let stateless = await recorder.statelessCalled
        let daemon = await recorder.daemonCalled
        XCTAssertTrue(stateless)
        XCTAssertFalse(daemon)
    }

    // MARK: - Opt-in success path

    func testRouter_optInSuccess_doesNotInvokeStateless() async throws {
        actor CallRecorder {
            var statelessCalled = false
            func markStateless() { statelessCalled = true }
        }
        let recorder = CallRecorder()

        let result = try await SafariBridge.runViaRouter(
            source: "ignored",
            daemonOptIn: true,
            daemonFn: { _ in "daemon-result" },
            statelessFn: { _ in
                await recorder.markStateless()
                return "unreachable"
            },
            warnWriter: nil
        )

        XCTAssertEqual(result, "daemon-result")
        let called = await recorder.statelessCalled
        XCTAssertFalse(called)
    }

    // MARK: - Fallback on the 4 defined failure modes

    func testRouter_connectFailed_fallsBack() async throws {
        var warnings: [String] = []
        let result = try await SafariBridge.runViaRouter(
            source: "ignored",
            daemonOptIn: true,
            daemonFn: { _ in throw DaemonClient.Error.connectFailed("socket missing") },
            statelessFn: { _ in "fallback-result" },
            warnWriter: { warnings.append($0) }
        )
        XCTAssertEqual(result, "fallback-result")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].hasPrefix("[daemon fallback:"), "got: \(warnings[0])")
        XCTAssertTrue(warnings[0].contains("connect"))
    }

    func testRouter_ioError_fallsBack() async throws {
        var warnings: [String] = []
        let result = try await SafariBridge.runViaRouter(
            source: "ignored",
            daemonOptIn: true,
            daemonFn: { _ in throw DaemonClient.Error.ioError("write failed") },
            statelessFn: { _ in "fallback-result" },
            warnWriter: { warnings.append($0) }
        )
        XCTAssertEqual(result, "fallback-result")
        XCTAssertTrue(warnings.first?.contains("io") ?? false)
    }

    func testRouter_protocolError_fallsBack() async throws {
        var warnings: [String] = []
        let result = try await SafariBridge.runViaRouter(
            source: "ignored",
            daemonOptIn: true,
            daemonFn: { _ in throw DaemonClient.Error.protocolError("bad envelope") },
            statelessFn: { _ in "fallback-result" },
            warnWriter: { warnings.append($0) }
        )
        XCTAssertEqual(result, "fallback-result")
        XCTAssertTrue(warnings.first?.contains("protocol") ?? false)
    }

    func testRouter_nonDomainRemoteError_fallsBack() async throws {
        var warnings: [String] = []
        let result = try await SafariBridge.runViaRouter(
            source: "ignored",
            daemonOptIn: true,
            daemonFn: { _ in
                throw DaemonClient.Error.remoteError(
                    code: "handlerError", message: "internal daemon bug"
                )
            },
            statelessFn: { _ in "fallback-result" },
            warnWriter: { warnings.append($0) }
        )
        XCTAssertEqual(result, "fallback-result")
        XCTAssertTrue(warnings.first?.contains("handlerError") ?? false)
    }

    // MARK: - Domain errors MUST propagate, not fall back

    func testRouter_ambiguousWindowMatch_propagatesWithoutFallback() async {
        actor CallRecorder {
            var statelessCalled = false
            func mark() { statelessCalled = true }
        }
        let recorder = CallRecorder()

        do {
            _ = try await SafariBridge.runViaRouter(
                source: "ignored",
                daemonOptIn: true,
                daemonFn: { _ in
                    throw DaemonClient.Error.remoteError(
                        code: "ambiguousWindowMatch",
                        message: "2 windows match"
                    )
                },
                statelessFn: { _ in
                    await recorder.mark()
                    return "unreachable"
                },
                warnWriter: nil
            )
            XCTFail("expected remoteError to propagate")
        } catch DaemonClient.Error.remoteError(let code, _) {
            XCTAssertEqual(code, "ambiguousWindowMatch")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let called = await recorder.statelessCalled
        XCTAssertFalse(called, "domain error must NOT trigger fallback")
    }

    func testRouter_documentNotFound_propagatesWithoutFallback() async {
        do {
            _ = try await SafariBridge.runViaRouter(
                source: "ignored",
                daemonOptIn: true,
                daemonFn: { _ in
                    throw DaemonClient.Error.remoteError(
                        code: "documentNotFound",
                        message: "no tab matches 'plaud'"
                    )
                },
                statelessFn: { _ in "unreachable" },
                warnWriter: nil
            )
            XCTFail("expected documentNotFound to propagate")
        } catch DaemonClient.Error.remoteError(let code, _) {
            XCTAssertEqual(code, "documentNotFound")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Fallback classification helper

    func testFallbackReason_connectFailed_returnsReason() {
        XCTAssertNotNil(DaemonClient.Error.connectFailed("x").fallbackReason)
    }

    func testFallbackReason_ambiguousWindowMatch_returnsNil() {
        let err = DaemonClient.Error.remoteError(code: "ambiguousWindowMatch", message: "")
        XCTAssertNil(err.fallbackReason, "domain error must not trigger fallback")
    }

    func testFallbackReason_unknownRemoteError_returnsReason() {
        let err = DaemonClient.Error.remoteError(code: "someBugCode", message: "oops")
        XCTAssertNotNil(err.fallbackReason)
    }
}
