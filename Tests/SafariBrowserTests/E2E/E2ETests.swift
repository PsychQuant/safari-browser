import XCTest

/// E2E tests that invoke the safari-browser binary and require Safari to be running.
/// These tests use Process to call the CLI directly.
///
/// Opt-in only: set `RUN_E2E=1` to run them. By default they are skipped so
/// plain `swift test` never activates Safari or steals focus from the user
/// (#22). This mirrors the non-interference principle in
/// `openspec/specs/non-interference/spec.md`.
///
///   RUN_E2E=1 swift test --filter E2ETests
///
/// Requires: Safari running, Accessibility permissions granted, binary
/// installed at `~/bin/safari-browser`.
/// NOTE: These tests may fail in sandboxed environments (Xcode, swift test via IDE).
/// Run from Terminal directly for best results.
final class E2ETests: XCTestCase {

    override class var defaultTestSuite: XCTestSuite {
        // Default to skipped — see class docstring and #22.
        // SKIP_E2E is kept as an explicit opt-out for callers that previously
        // relied on it; RUN_E2E=1 is the new opt-in.
        let env = ProcessInfo.processInfo.environment
        let isOptIn = env["RUN_E2E"] == "1"
        let isOptedOut = env["SKIP_E2E"] != nil
        guard isOptIn, !isOptedOut else {
            return XCTestSuite(name: "E2ETests (skipped — set RUN_E2E=1 to run)")
        }
        return super.defaultTestSuite
    }

    static let binary = "/Users/che/bin/safari-browser"
    static let testPage = "file://" + URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/test-page.html")
        .path

    // MARK: - Helpers

    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval = 10) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.binary)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { process.terminate() }
        timer.resume()

        process.waitUntilExit()
        timer.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            stdout: String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            exitCode: process.terminationStatus
        )
    }

    // MARK: - Setup

    override func setUp() async throws {
        // Open test page before each test
        try run(["open", Self.testPage])
        try await Task.sleep(nanoseconds: 2_000_000_000) // wait for page load
    }

    // MARK: - 3.1 E2E Navigation Test

    func testNavigationOpenAndGetURL() throws {
        let result = try run(["get", "url"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("test-page.html"), "URL should contain test-page.html, got: \(result.stdout)")
    }

    // MARK: - 3.2 E2E JavaScript Execution Test

    func testJSReturnsValue() throws {
        let result = try run(["js", "1 + 1"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("2"), "JS 1+1 should return 2, got: \(result.stdout)")
    }

    func testJSReturnsDocumentTitle() throws {
        let result = try run(["js", "document.title"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Safari Browser Test Page"), "Title should match, got: \(result.stdout)")
    }

    // MARK: - 3.3 E2E Snapshot and Ref Test

    func testSnapshotFindsElements() throws {
        let result = try run(["snapshot"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("@e1"), "Snapshot should contain @e1, got: \(result.stdout)")
    }

    // MARK: - 3.4 E2E Get Info Test

    func testGetTitle() throws {
        let result = try run(["get", "title"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Safari Browser Test Page"), "Title should match, got: \(result.stdout)")
    }

    func testGetTextWithSelector() throws {
        let result = try run(["get", "text", "h1"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.isEmpty, "get text h1 should return non-empty")
    }

    // MARK: - 3.5 E2E Wait Test

    func testWaitDuration() throws {
        let start = Date()
        let result = try run(["wait", "500"])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(elapsed, 0.4, "Should wait at least 400ms")
    }

    // MARK: - 3.6 E2E Error Handling Test

    func testClickNonexistentElement() throws {
        let result = try run(["click", ".nonexistent-element-xyz"])
        XCTAssertNotEqual(result.exitCode, 0, "Should fail for nonexistent element")
        XCTAssertTrue(result.stderr.contains("Element not found"), "Should report element not found, got: \(result.stderr)")
    }

    func testClickInvalidRef() throws {
        let result = try run(["click", "@e99"])
        XCTAssertNotEqual(result.exitCode, 0, "Should fail for invalid ref")
    }
}
