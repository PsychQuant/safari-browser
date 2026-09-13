import XCTest
@testable import SafariBrowser

final class BackgroundTabDiagnosticsTests: XCTestCase {
    private let target = BackgroundTabDiagnosticTarget(
        windowID: 71, tabIndex: 2, matcher: .exact("https://example.test/target"))

    private func inspect(_ response: String,
                         target: BackgroundTabDiagnosticTarget? = nil) async -> BackgroundTabDiagnostics.Observation {
        let resolved = target ?? self.target
        return await BackgroundTabDiagnostics.$query.withValue({ _ in response }) {
            await BackgroundTabDiagnostics.inspect(resolved)
        }
    }

    func testFreshObservationDistinguishesBackgroundAndCurrent() async {
        let background = await inspect("1\u{1D}3\u{1D}https://example.test/target")
        let current = await inspect("2\u{1D}3\u{1D}https://example.test/target")
        XCTAssertEqual(background, .background)
        XCTAssertEqual(current, .current)
    }

    func testMalformedAndOutOfRangeResponsesRemainUnknown() async {
        for response in [
            "", "1", "1\u{1D}3", "1\u{1D}3\u{1D}",
            "1\u{1D}3\u{1D}https://example.test/target\u{1D}extra",
            "0\u{1D}3\u{1D}https://example.test/target",
            "4\u{1D}3\u{1D}https://example.test/target",
            "-1\u{1D}3\u{1D}https://example.test/target",
            "1\u{1D}1\u{1D}https://example.test/target",
            "1\u{1D}0\u{1D}https://example.test/target",
            "1\u{1D}-3\u{1D}https://example.test/target",
            "one\u{1D}3\u{1D}https://example.test/target",
            "1.0\u{1D}3\u{1D}https://example.test/target",
            "+1\u{1D}3\u{1D}https://example.test/target",
            " 1\u{1D}3\u{1D}https://example.test/target",
            "1\u{1D}03\u{1D}https://example.test/target",
            "1\u{1D}999999999999999999999999\u{1D}https://example.test/target",
        ] {
            let result = await inspect(response)
            XCTAssertEqual(result, .unknown, "Unexpected accepted response: \(response.debugDescription)")
        }
    }

    func testEveryMatcherIsRecheckedAgainstFreshURL() async throws {
        let matchers: [SafariBridge.UrlMatcher] = [
            .contains("example.test"), .exact("https://example.test/target"),
            .endsWith("/target"), .regex(try NSRegularExpression(pattern: "^https://example\\.test/target$")),
        ]
        for matcher in matchers {
            let target = BackgroundTabDiagnosticTarget(windowID: 71, tabIndex: 2, matcher: matcher)
            let matching = await inspect("1\u{1D}3\u{1D}https://example.test/target", target: target)
            let stale = await inspect("1\u{1D}3\u{1D}https://different.test/other", target: target)
            XCTAssertEqual(matching, .background)
            XCTAssertEqual(stale, .unknown)
        }
    }

    func testFixedTargetWithoutMatcherStillRequiresCompleteObservation() async {
        let target = BackgroundTabDiagnosticTarget(windowID: 71, tabIndex: 2, matcher: nil)
        let complete = await inspect("1\u{1D}3\u{1D}about:blank", target: target)
        let missingURL = await inspect("1\u{1D}3\u{1D}", target: target)
        XCTAssertEqual(complete, .background)
        XCTAssertEqual(missingURL, .unknown)
    }

    func testUnavailableOrInvalidTargetDoesNotQuery() async {
        let invalid: [BackgroundTabDiagnosticTarget?] = [
            nil,
            .init(windowID: 0, tabIndex: 2, matcher: nil),
            .init(windowID: -1, tabIndex: 2, matcher: nil),
            .init(windowID: 71, tabIndex: 0, matcher: nil),
            .init(windowID: 71, tabIndex: -1, matcher: nil),
        ]
        for target in invalid {
            let result = await BackgroundTabDiagnostics.$query.withValue({ _ in
                XCTFail("Invalid coordinates must not query Safari")
                return "1\u{1D}3\u{1D}about:blank"
            }) {
                await BackgroundTabDiagnostics.inspect(target)
            }
            XCTAssertEqual(result, .unknown)
            if let target { XCTAssertNil(BackgroundTabDiagnostics.script(for: target)) }
        }
    }

    func testQueryFailuresAndCancellationRemainUnknown() async {
        let timeout = await BackgroundTabDiagnostics.$query.withValue({ _ in
            throw SafariBrowserError.processTimedOut(command: "osascript", seconds: 1)
        }) {
            await BackgroundTabDiagnostics.inspect(target)
        }
        let cancelled = await BackgroundTabDiagnostics.$query.withValue({ _ in
            throw CancellationError()
        }) {
            await BackgroundTabDiagnostics.inspect(target)
        }
        XCTAssertEqual(timeout, .unknown)
        XCTAssertEqual(cancelled, .unknown)
    }

    func testScriptOnlyReadsStableWindowAndFixedTab() throws {
        let script = try XCTUnwrap(BackgroundTabDiagnostics.script(for: target))
        XCTAssertTrue(script.contains("window id 71"))
        XCTAssertTrue(script.contains("tab 2"))
        XCTAssertTrue(script.contains("count of tabs"))
        XCTAssertTrue(script.contains("index of current tab"))
        XCTAssertTrue(script.contains("URL of tab 2"))
        XCTAssertTrue(script.contains("character id 29"))
        XCTAssertFalse(script.contains("example.test"), "Matcher values must not enter AppleScript")
        for forbidden in ["do JavaScript", "System Events", "activate", "set current tab", "set index", "AX", "keystroke", "click"] {
            XCTAssertFalse(script.contains(forbidden), "Unexpected side effect: \(forbidden)")
        }
    }

    func testWarningIsLimitedToConfirmedBackgroundAndExplainsUncertainty() throws {
        XCTAssertNil(BackgroundTabDiagnostics.warning(for: .unknown))
        XCTAssertNil(BackgroundTabDiagnostics.warning(for: .current))
        let warning = try XCTUnwrap(BackgroundTabDiagnostics.warning(for: .background))
        for phrase in ["background", "pending dialog", "may", "hidden", "does not prove", "recheck", "tab focus", "same target flags", "dialog list"] {
            XCTAssertTrue(warning.lowercased().contains(phrase), "Missing recovery guidance: \(phrase)")
        }
        XCTAssertFalse(warning.contains("https://"))
    }
    func testGeneratedAppleScriptCompilesWithoutRunningSafari() throws {
        let source = try XCTUnwrap(BackgroundTabDiagnostics.script(for:
            BackgroundTabDiagnosticTarget(windowID: 71, tabIndex: 2, matcher: nil)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("probe.applescript")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", directory.appendingPathComponent("probe.scpt").path, file.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
    }

}
