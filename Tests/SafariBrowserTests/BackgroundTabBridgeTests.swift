import Foundation
import XCTest
@testable import SafariBrowser

final class BackgroundTabBridgeTests: XCTestCase, @unchecked Sendable {
    private let fixed = SafariBridge.TargetDocument.resolvedTab(windowID: 71, tabInWindow: 2, rematch: nil, profile: nil)

    func testBindingRetainsStableCoordinatesAndMatcherWithoutGuessingCurrentTarget() {
        let resolved = SafariBridge.ResolvedWindowTarget(windowIndex: 9, tabIndexInWindow: nil, windowID: 71, anchorTabIndex: 2)
        let binding = SafariBridge.backgroundDiagnosticTarget(for: .urlMatch(.exact("https://fixture/")), resolved: resolved)
        XCTAssertEqual(binding?.windowID, 71)
        XCTAssertEqual(binding?.tabIndex, 2)
        XCTAssertEqual(binding?.matcher, .exact("https://fixture/"))
        XCTAssertNil(SafariBridge.backgroundDiagnosticTarget(for: .frontWindow, resolved: resolved))
        XCTAssertNil(SafariBridge.backgroundDiagnosticTarget(for: .windowIndex(9), resolved: resolved))
        let legacy = SafariBridge.ResolvedWindowTarget(windowIndex: 9, tabIndexInWindow: 2)
        XCTAssertNil(SafariBridge.backgroundDiagnosticTarget(for: .documentIndex(2), resolved: legacy))
    }

    func testTimeoutAddsBackgroundHintAndPreservesOriginalError() async {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let observations = ExecSubprocessOutputTests.Output()
        do {
            _ = try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in
                    throw SafariBrowserError.processTimedOut(command: "fixture", seconds: 30)
                }) {
                    try await BackgroundTabDiagnostics.$query.withValue({ source in
                        observations.append(source)
                        return "1\u{1d}3\u{1d}https://fixture/"
                    }) { try await SafariBridge.doJavaScript("1+1", target: fixed) }
                }
            }
            XCTFail("Expected original timeout")
        } catch SafariBrowserError.processTimedOut(let command, let seconds) {
            XCTAssertEqual(command, "fixture"); XCTAssertEqual(seconds, 30)
        } catch { XCTFail("Unexpected replacement error: \(error)") }
        XCTAssertTrue(context.diagnostics.joined().contains("background"))
        XCTAssertTrue(context.diagnostics.joined().contains("tab focus"))
        XCTAssertTrue(observations.text.contains("window id 71"))
    }

    func testEmptyTextAddsHintButRemainsSuccessfulEmptyText() async throws {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let result = try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in "" }) {
                try await BackgroundTabDiagnostics.$query.withValue({ _ in "1\u{1d}3\u{1d}https://fixture/" }) {
                    try await SafariBridge.getCurrentText(target: fixed)
                }
            }
        }
        XCTAssertEqual(result, "")
        XCTAssertTrue(context.diagnostics.joined().contains("background"))
    }

    func testSuccessfulNonemptyTextDoesNotStartBackgroundQuery() async throws {
        let observations = ExecSubprocessOutputTests.Output()
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let result = try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in "content" }) {
                try await BackgroundTabDiagnostics.$query.withValue({ source in
                    observations.append(source); return "1\u{1d}3\u{1d}https://fixture/"
                }) { try await SafariBridge.getCurrentText(target: fixed) }
            }
        }
        XCTAssertEqual(result, "content")
        XCTAssertTrue(observations.text.isEmpty)
        XCTAssertTrue(context.diagnostics.isEmpty)
    }
    func testStaleURLAndFailedObservationCannotReplaceTimeout() async {
        for staleURL in [true, false] {
            let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            let matched = SafariBridge.TargetDocument.resolvedTab(windowID: 71, tabInWindow: 2,
                rematch: .exact("https://fixture/"), profile: nil)
            do {
                _ = try await DaemonRequestContext.$current.withValue(context) {
                    try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in
                        throw SafariBrowserError.processTimedOut(command: "original", seconds: 30)
                    }) {
                        try await BackgroundTabDiagnostics.$query.withValue({ _ in
                            if staleURL { return "1\u{1d}3\u{1d}https://changed/" }
                            throw SafariBrowserError.fileNotFound("probe-error")
                        }) { try await SafariBridge.doJavaScript("1+1", target: matched) }
                    }
                }
                XCTFail("Expected original error")
            } catch SafariBrowserError.processTimedOut(let command, _) {
                XCTAssertEqual(command, "original")
            } catch { XCTFail("Replaced error: \(error)") }
            XCTAssertTrue(context.diagnostics.isEmpty)
        }
    }

    func testVisibleDialogAppearingAfterTimeoutTakesPrecedence() async {
        let sequence = ProbeSequence()
        let observations = ExecSubprocessOutputTests.Output()
        let context = DaemonRequestContext(probe: { _ in sequence.next() }, environment: [:])
        do {
            _ = try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in
                    throw SafariBrowserError.processTimedOut(command: "fixture", seconds: 30)
                }) {
                    try await BackgroundTabDiagnostics.$query.withValue({ source in
                        observations.append(source); return "1\u{1d}3\u{1d}https://fixture/"
                    }) { try await SafariBridge.doJavaScript("1+1", target: fixed) }
                }
            }
            XCTFail("Expected visible-dialog error")
        } catch SafariBrowserError.javaScriptDialogBlocking { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(observations.text.isEmpty)
        XCTAssertTrue(context.diagnostics.joined().contains("visible"))
        XCTAssertFalse(context.diagnostics.joined().contains("background"))
    }

    func testExplicitWarningWriterReceivesEmptyTextHint() async throws {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let output = ExecSubprocessOutputTests.Output()
        let result = try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in "" }) {
                try await BackgroundTabDiagnostics.$query.withValue({ _ in "1\u{1d}3\u{1d}https://fixture/" }) {
                    try await SafariBridge.getCurrentText(target: fixed, warnWriter: { output.append($0) })
                }
            }
        }
        XCTAssertEqual(result, "")
        XCTAssertTrue(output.text.contains("safari-browser tab focus"))
        XCTAssertTrue(context.diagnostics.isEmpty)
    }

    private final class ProbeSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func next() -> BlockingDialogState {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return calls == 1 ? .clear : .present(SafariBridge.BlockingDialog(message: "visible", buttons: ["OK"]))
        }
    }

}
