import XCTest
@testable import SafariBrowser

final class FileDialogDiagnosticsTests: XCTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    func testLargeStderrBeforeStdoutDoesNotBlockCompletion() async throws {
        let result = try await SafariBridge.runShell(
            "/usr/bin/awk", ["BEGIN { for (i = 0; i < 20000; i++) print \"confirmation diagnostic\" > \"/dev/stderr\"; print \"completed\" }"],
            timeout: 3)
        XCTAssertEqual(result, "completed")
    }

    func testLargeBothPipesArePreservedWhenWriterRequested() async throws {
        let captured = Capture()
        let result = try await SafariBridge.runShell(
            "/usr/bin/awk", ["BEGIN { for (i = 0; i < 20000; i++) { print \"diagnostic\" > \"/dev/stderr\"; print \"output\" } }"],
            timeout: 5, stderrWriter: { captured.append($0) })
        XCTAssertEqual(result, String(repeating: "output\n", count: 20000).dropLast().description)
        XCTAssertEqual(captured.values, [String(repeating: "diagnostic\n", count: 20000)])
    }

    func testSuccessfulAppleScriptKeepsStdoutAndRelaysLog() async throws {
        let captured = Capture()
        let output = try await SafariBridge.runFileDialogScript(
            "log \"confirmation AXPress\"\nreturn \"saved\"", warnWriter: { captured.append($0) })
        XCTAssertEqual(output, "saved")
        XCTAssertEqual(captured.values.count, 1)
        XCTAssertTrue(captured.values[0].hasPrefix("file dialog trace: "))
        XCTAssertTrue(captured.values[0].contains("confirmation AXPress"))
    }

    func testAppleScriptFailureRelaysLogBeforeOriginalError() async throws {
        let captured = Capture()
        do {
            try await SafariBridge.runFileDialogScript(
                "log \"attempted confirmation\"\nerror \"confirmation failed\" number 7",
                warnWriter: { captured.append($0) })
            XCTFail("Expected AppleScript failure")
        } catch let error as SafariBrowserError {
            guard case .appleScriptFailed(let message) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertTrue(message.contains("confirmation failed"))
            XCTAssertTrue(captured.values.joined().contains("attempted confirmation"))
        }
    }

    func testTimeoutRelaysCapturedStderrWithoutChangingCategory() async throws {
        let captured = Capture()
        do {
            try await SafariBridge.runShell("/bin/sh", ["-c", "printf 'before timeout' >&2; exec /bin/sleep 30"],
                                            timeout: 0.3, stderrWriter: { captured.append($0) })
            XCTFail("Expected timeout")
        } catch let error as SafariBrowserError {
            guard case .processTimedOut(_, let seconds) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(seconds, 1)
            XCTAssertEqual(captured.values, ["before timeout"])
        }
    }

    func testSubprocessFailureKeepsCategoryAndUnmodifiedStderr() async throws {
        let captured = Capture()
        do {
            try await SafariBridge.runShell("/bin/sh", ["-c", "printf 'diagnostic\\n' >&2; exit 7"],
                                            stderrWriter: { captured.append($0) })
            XCTFail("Expected nonzero exit")
        } catch let error as SafariBrowserError {
            guard case .subprocessFailed(let executable, let message) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(executable, "/bin/sh")
            XCTAssertEqual(message, "diagnostic")
            XCTAssertEqual(captured.values, ["diagnostic\n"])
        }
    }

    func testFileScriptTimeoutAlsoDeliversSafeTrace() async throws {
        let captured = Capture()
        do {
            try await SafariBridge.runFileDialogScript("log \"before file timeout\"\ndelay 30",
                                                       timeout: 1, warnWriter: { captured.append($0) })
            XCTFail("Expected timeout")
        } catch let error as SafariBrowserError {
            guard case .processTimedOut = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(captured.values.count, 1)
            XCTAssertTrue(captured.values[0].contains("before file timeout"))
            XCTAssertTrue(captured.values[0].hasPrefix("file dialog trace: "))
        }
    }

    func testDaemonCapturesFileTraceButOrdinaryRunShellRemainsSilent() async throws {
        let context = DaemonRequestContext()
        try await DaemonRequestContext.$current.withValue(context) {
            let ordinary = try await SafariBridge.runShell("/bin/sh", ["-c", "printf 'unrelated' >&2; printf 'ok'"])
            XCTAssertEqual(ordinary, "ok")
            XCTAssertTrue(context.diagnostics.isEmpty)
            _ = try await SafariBridge.runFileDialogScript("log \"file operation\"\nreturn \"ok\"")
        }
        XCTAssertEqual(context.diagnostics.count, 1)
        XCTAssertTrue(context.diagnostics[0].contains("file operation"))
    }

    func testCustomWriterTakesPrecedenceOverDaemonContext() async throws {
        let context = DaemonRequestContext()
        let captured = Capture()
        try await DaemonRequestContext.$current.withValue(context) {
            _ = try await SafariBridge.runFileDialogScript("log \"file operation\"",
                                                          warnWriter: { captured.append($0) })
        }
        XCTAssertTrue(context.diagnostics.isEmpty)
        XCTAssertEqual(captured.values.count, 1)
    }

    func testTraceEscapesControlSequencesAndRendersOnlyOneLine() throws {
        let line = try XCTUnwrap(FileDialogDiagnostics.trace("name\u{1B}[2J\nnext\t\u{202E}name\u{7}\r"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertFalse(line.contains("\u{1B}"))
        XCTAssertFalse(line.contains("\u{202E}"))
        XCTAssertTrue(line.contains("\\u{1B}[2J\\nnext\\t\\u{202E}name\\u{7}\\r"))
    }

    func testTraceBoundsRenderedScalarsIncludingCombiningMarksAndSignalsTruncation() throws {
        for raw in [String(repeating: "\u{1B}", count: 5000), "a" + String(repeating: "\u{301}", count: 5000)] {
            let line = try XCTUnwrap(FileDialogDiagnostics.trace(raw))
            XCTAssertLessThanOrEqual(line.unicodeScalars.count, 4096)
            XCTAssertTrue(line.hasSuffix("…[truncated]\n"))
        }
        XCTAssertNil(FileDialogDiagnostics.trace(""))
    }
}
