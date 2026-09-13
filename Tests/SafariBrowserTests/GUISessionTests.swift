import ApplicationServices
import XCTest
@testable import SafariBrowser

final class GUISessionTests: XCTestCase {
    private let locked = GUISession(readDictionary: { ["CGSSessionScreenIsLocked": true] })
    private let unavailable = GUISession(readDictionary: { nil })
    private let available = GUISession(readDictionary: { ["CGSSessionScreenIsLocked": false] })

    func testDictionaryDistinguishesLockedUnavailableAndAvailable() {
        XCTAssertEqual(locked.state, .locked)
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertEqual(available.state, .available)
        XCTAssertEqual(GUISession(readDictionary: { [:] }).state, .available)
        XCTAssertEqual(GUISession(readDictionary: { [kCGSessionOnConsoleKey as String: false] }).state, .unavailable)
        XCTAssertEqual(GUISession(readDictionary: { [kCGSessionLoginDoneKey as String: false] }).state, .unavailable)
    }

    func testDialogScanDoesNotInspectUnavailableSessions() {
        for (session, expected) in [(locked, SafariBridge.DialogScan.sessionLocked),
                                    (unavailable, .sessionUnavailable)] {
            var calls = 0
            XCTAssertEqual(SafariBridge.scanBlockingDialogs(session: session, inspect: {
                calls += 1
                return .none
            }), expected)
            XCTAssertEqual(calls, 0)
        }
        var calls = 0
        XCTAssertEqual(SafariBridge.scanBlockingDialogs(session: available, inspect: {
            calls += 1
            return .none
        }), .none)
        XCTAssertEqual(calls, 1)
    }

    func testDialogPressDoesNotInspectDecideOrActWhenSessionUnavailable() {
        for (session, expected) in [(locked, SafariBridge.DialogPressOutcome.sessionLocked),
                                    (unavailable, .sessionUnavailable)] {
            var calls = 0
            let result = SafariBridge.pressDialogButton(session: session, press: { decide in
                calls += 1
                _ = decide(.init(message: "alert", buttons: ["OK"]))
                return .pressed
            }, deciding: { _ in
                calls += 1
                return 0
            })
            XCTAssertEqual(result, expected)
            XCTAssertEqual(calls, 0)
        }
    }

    func testAvailableSessionPreservesNamedPressDecision() {
        var calls = 0
        let dialog = SafariBridge.BlockingDialog(message: "alert", buttons: ["Cancel", "OK"])
        let outcome = SafariBridge.pressDialogButton(session: available, press: { decide in
            calls += 1
            XCTAssertEqual(decide(dialog), 1)
            return .pressed
        }, deciding: { current in
            XCTAssertEqual(current, dialog)
            return 1
        })
        XCTAssertEqual(outcome, .pressed)
        XCTAssertEqual(calls, 1)
    }

    func testCaptureResolverDoesNotResolveAnyWindowWhenSessionUnavailable() async throws {
        for (session, expected) in [(locked, GUISession.State.locked), (unavailable, .unavailable)] {
            for window in [nil, 2] as [Int?] {
                var calls = 0
                do {
                    _ = try await SafariBridge.resolveWindowForCapture(window: window, session: session, resolve: { _ in
                        calls += 1
                        return ("42", nil)
                    })
                    XCTFail("capture must fail before resolving a window")
                } catch {
                    if expected == .locked {
                        guard case SafariBrowserError.guiSessionLocked = error else { return XCTFail("\(error)") }
                    } else {
                        guard case SafariBrowserError.guiSessionUnavailable = error else { return XCTFail("\(error)") }
                    }
                }
                XCTAssertEqual(calls, 0)
            }
        }
        let result = try await SafariBridge.resolveWindowForCapture(window: 2, session: available, resolve: { window in
            XCTAssertEqual(window, 2)
            return ("42", nil)
        })
        XCTAssertEqual(result.cgID, "42")
    }

    func testScopedProviderPreservesUnknownForUnavailableSession() {
        for session in [locked, unavailable] {
            let probe = BoundedDialogProbe { AXDialogProbeProvider(session: session) }
            XCTAssertEqual(probe.check(windowKey: .id(42)), .unprobed)
        }
    }

    func testSessionErrorsProvideActionableGuidance() {
        XCTAssertTrue(SafariBrowserError.guiSessionLocked.localizedDescription.lowercased().contains("unlock"))
        XCTAssertTrue(SafariBrowserError.guiSessionUnavailable.localizedDescription.lowercased().contains("logged-in"))
    }
}
