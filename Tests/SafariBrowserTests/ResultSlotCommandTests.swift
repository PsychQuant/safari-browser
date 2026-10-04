import XCTest
@testable import SafariBrowser

/// #190 at the level of the commands: `js` against a page that really runs what it is sent, with the
/// rest of Safari (windows, tabs) answered by the fake of `JSCommandRoundTripTests`.
final class ResultSlotCommandTests: XCTestCase, @unchecked Sendable {

    private let target = ["--window", "1", "--tab-in-window", "53"]

    @discardableResult
    private func run(_ args: [String], page: FakePage, fake: JSCommandRoundTripTests.FakeSafari = .init()) async throws -> (stdout: String, stderr: String) {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let command = try JSCommand.parse(args)
        let out = JSCommandRoundTripTests.FDCapture(STDOUT_FILENO), err = JSCommandRoundTripTests.FDCapture(STDERR_FILENO)
        out.start(); err.start()
        do {
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ script in
                    script.contains("do JavaScript") ? try page.respond(script) : try fake.respond(script)
                }) {
                    try await command.run()
                }
            }
        } catch {
            _ = err.stop(); _ = out.stop()
            throw error
        }
        let stderr = err.stop()
        return (out.stop(), stderr)
    }

    private func failure(_ args: [String], page: FakePage) async -> String? {
        do { try await run(args, page: page); return nil }
        catch let error as SafariBrowserError { if case .appleScriptFailed(let m) = error { return m }; return "\(error)" }
        catch { return "\(error)" }
    }

    private func assertNoSharedNames(_ page: FakePage, file: StaticString = #filePath, line: UInt = #line) {
        for script in page.javaScripts {
            for old in ["__sbResult", "__sbResultLen", "__sbLargeErr", "__sbLen"] {
                XCTAssertFalse(script.contains(old), "\(old) is shared by every call: \(script.prefix(140))", file: file, line: line)
            }
        }
    }

    // MARK: - js --large

    func testLargeReturnsItsValueAndLeavesNothingInThePage() async throws {
        let page = FakePage()
        let output = try await run(["--large"] + target + ["'x'.repeat(300000)"], page: page)
        XCTAssertEqual(output.stdout, String(repeating: "x", count: 300_000) + "\n")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
        assertNoSharedNames(page)
    }

    func testLargeStatementFormRunsWhenTheExpressionFormDoesNotParse() async throws {
        let page = FakePage()
        let output = try await run(["--large"] + target + ["var a = 'q'.repeat(10); return a + a"], page: page)
        XCTAssertEqual(output.stdout, String(repeating: "q", count: 20) + "\n")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
    }

    func testLargeRuntimeErrorIsReportedAndTheSlotIsRemoved() async {
        let page = FakePage()
        let message = await failure(["--large"] + target + ["(function(){ throw new Error('boom') })()"], page: page)
        XCTAssertEqual(message, "JavaScript error: boom")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
    }

    func testLargeSyntaxErrorIsReportedAndTheSlotIsRemoved() async {
        let page = FakePage()
        let message = await failure(["--large"] + target + ["1 +"], page: page)
        XCTAssertTrue(message?.hasPrefix("JavaScript syntax error:") == true, message ?? "nil")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
    }

    func testLargeEmptyResultIsEmptyNotAnError() async throws {
        let page = FakePage()
        let output = try await run(["--large"] + target + ["''"], page: page)
        XCTAssertEqual(output.stdout, "")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
    }

    func testLargeOutputIsNotDisturbedByAnotherCallStoringInTheMiddle() async throws {
        let page = FakePage()
        var intruded = false
        page.beforeRun = { script in
            if !intruded, script.contains("a = \(ResultSlot.chunkSize),") {
                intruded = true
                _ = page.evaluate(ResultSlot.make().storeScript("'INTRUDER'"))
                _ = page.evaluate("window.__sbResult = 'INTRUDER'; window.__sbResultLen = 8;")
            }
        }
        let output = try await run(["--large"] + target + ["'a'.repeat(\(ResultSlot.chunkSize)) + 'b'.repeat(100)"], page: page)
        XCTAssertTrue(intruded)
        XCTAssertEqual(output.stdout, String(repeating: "a", count: ResultSlot.chunkSize) + String(repeating: "b", count: 100) + "\n")
    }

    // MARK: - a result over the inline limit

    func testABigInlineResultIsReadFromItsOwnSlotAndRemoved() async throws {
        let page = FakePage()
        let output = try await run(target + ["'y'.repeat(200000)"], page: page)
        XCTAssertEqual(output.stdout, String(repeating: "y", count: 200_000) + "\n")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
        assertNoSharedNames(page)
        XCTAssertFalse(output.stderr.contains("used chunked read"), "every chunked read is checked now; there is no unchecked first read to fall back from")
    }

    func testABigInlineResultCostsTheWrapperOneReadPerChunkAndTheCleanup() async throws {
        // 131073 to 262144 units are one chunk: wrapper, one read, cleanup. Three chunks: wrapper, three reads, cleanup.
        for (units, reads) in [(200_000, 1), (3 * ResultSlot.chunkSize - 10, 3)] {
            let page = FakePage()
            _ = try await run(target + ["'y'.repeat(\(units))"], page: page)
            XCTAssertEqual(page.javaScripts.count, 1 + reads + 1, "\(units) units:\n\(page.javaScripts.map { String($0.prefix(90)) }.joined(separator: "\n"))")
        }
    }

    func testABigInlineResultIsNotDisturbedByAnotherCallsBigResult() async throws {
        let page = FakePage()
        var intruded = false
        page.beforeRun = { script in
            // A's wrapper has answered; before A reads, another `js` parks a big result of its own
            if !intruded, script.contains("a = 0,") {
                intruded = true
                _ = page.evaluate(JSWrapper.inlineExpression("'z'.repeat(200000)"))
                _ = page.evaluate("window.__sbResult = 'INTRUDER'; window.__sbLen = 8;")
            }
        }
        let output = try await run(target + ["'y'.repeat(200000)"], page: page)
        XCTAssertTrue(intruded)
        XCTAssertEqual(output.stdout, String(repeating: "y", count: 200_000) + "\n")
        // the intruder's slot is somebody else's: this call must not remove it
        XCTAssertEqual(page.keys(withPrefix: "__sbr_").count, 1)
    }

    func testTheSameJsCommandSendsTheSameScriptEveryTime() async throws {
        // A name per call inside the wrapper would make every script unique and defeat the daemon's compile cache.
        let page = FakePage()
        _ = try await run(target + ["'y'.repeat(200000)"], page: page)
        let first = page.javaScripts.first
        _ = try await run(target + ["'y'.repeat(200000)"], page: page)
        let second = page.javaScripts.dropFirst(page.javaScripts.count / 2).first
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    func testABigReplyNamingAnUnexpectedSlotIsAnErrorAndTheCodeIsNotRunAgain() async {
        let page = FakePage()
        page.forced = { js in js.contains("SB1:BIG") ? "SB1:BIG:200000:__sbr_x';alert(1);'" : nil }
        let message = await failure(target + ["'y'.repeat(200000)"], page: page)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("slot") == true && message?.contains("not run again") == true, message ?? "nil")
        XCTAssertEqual(page.javaScripts.count, 1, "no second form, no read of a name that was never validated")
    }
}
