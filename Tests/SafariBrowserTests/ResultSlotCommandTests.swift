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

    // MARK: - --output when the code navigated the page

    private func navigatingSafari() -> JSCommandRoundTripTests.FakeSafari {
        let fake = JSCommandRoundTripTests.FakeSafari()
        fake.navigatedURL = "https://w1.example/done"
        fake.navigatesFromURLRead = 2          // the first URL read is before the code ran
        return fake
    }

    func testOutputKeepsTheFileWhenTheCodeNavigatedAndFails() async throws {
        let path = NSTemporaryDirectory() + "sb-output-nav-\(UUID().uuidString).txt"
        try "OLD CONTENT".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let page = FakePage()
        do {
            // does not parse in this page, and the tab is somewhere else when the check is made: the code ran and left
            try await run(["--output", path] + target + ["1 +"], page: page, fake: navigatingSafari())
            XCTFail("no result exists to write, which must not be a success")
        } catch let error as SafariBrowserError {
            guard case .appleScriptFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("navigated"), message)
            XCTAssertTrue(message.contains(path), "the message names the file that was left as it was: \(message)")
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "OLD CONTENT",
                       "the file was truncated to zero bytes before this change")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
    }

    func testLargeWithoutOutputStillTreatsANavigationAsAnOutcomeNotAnError() async throws {
        let output = try await run(["--large"] + target + ["1 +"], page: FakePage(), fake: navigatingSafari())
        XCTAssertEqual(output.stdout, "", "a navigation prints no value (#82)")
        XCTAssertTrue(output.stderr.contains("navigated"), output.stderr)
    }

    // MARK: - the page is left between the length read and the first chunk

    /// Runs `body` after the wrapper stored its result and before the first chunk is read: the page is replaced.
    private func leavingThePageBeforeTheFirstChunk(_ page: FakePage, then url: String? = nil) {
        var left = false
        page.beforeRun = { script in
            if !left, script.contains("a = 0,") {
                left = true
                _ = page.evaluate("Object.getOwnPropertyNames(window).filter(function(k){return k.indexOf('__sbr_')===0}).forEach(function(k){delete window[k]})")
            }
        }
    }

    func testABigResultWhosePageWasLeftBeforeItWasReadIsANavigationNotADamagedTransfer() async throws {
        let page = FakePage()
        leavingThePageBeforeTheFirstChunk(page)
        let fake = JSCommandRoundTripTests.FakeSafari()
        fake.navigatedURL = "https://w1.example/done"
        let output = try await run(target + ["'x'.repeat(200000)"], page: page, fake: fake)
        XCTAssertEqual(output.stdout, "", "a navigation prints no value (#82)")
        XCTAssertTrue(output.stderr.contains("navigated"), output.stderr)
    }

    func testABigResultWhoseSlotWentAwayWithoutANavigationStaysAnError() async {
        let page = FakePage()
        leavingThePageBeforeTheFirstChunk(page)
        let message = await failure(target + ["'x'.repeat(200000)"], page: page)
        XCTAssertTrue(message?.hasPrefix(ResultSlot.incompleteTransferPrefix) == true, message ?? "no error")
    }

    func testALargeResultWhosePageWasLeftBeforeItWasReadIsANavigation() async throws {
        let page = FakePage()
        leavingThePageBeforeTheFirstChunk(page)
        let fake = JSCommandRoundTripTests.FakeSafari()
        fake.navigatedURL = "https://w1.example/done"
        fake.navigatesFromURLRead = 2
        let output = try await run(["--large"] + target + ["'x'.repeat(300000)"], page: page, fake: fake)
        XCTAssertEqual(output.stdout, "")
        XCTAssertTrue(output.stderr.contains("navigated"), output.stderr)
    }

    // MARK: - what a failure leaves behind

    func testABigResultWhoseReadFailedStillRemovesItsSlot() async {
        let page = FakePage()
        var tampered = false
        page.beforeRun = { script in
            if !tampered, script.contains("a = \(ResultSlot.chunkSize),") {
                tampered = true
                // another length: the second chunk read is refused
                _ = page.evaluate("Object.getOwnPropertyNames(window).filter(function(k){return k.indexOf('__sbr_')===0}).forEach(function(k){window[k].text='short'})")
            }
        }
        _ = await failure(target + ["'x'.repeat(\(ResultSlot.chunkSize + 500))"], page: page)
        XCTAssertTrue(tampered, "the second chunk was never read, so nothing was tested")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
    }

    func testAnEmojiAcrossAChunkEdgeComesBackIntactOnEveryPathAndTransport() async throws {
        let code = "'a'.repeat(\(ResultSlot.chunkSize - 1)) + '\\u{1F600}' + 'b'.repeat(10)"
        let expected = String(repeating: "a", count: ResultSlot.chunkSize - 1) + "\u{1F600}" + String(repeating: "b", count: 10) + "\n"
        for transport in [FakePage.Transport.stateless, .daemon] {
            for flags in [["--large"], []] {
                let page = FakePage()
                page.transport = transport
                let output = try await run(flags + target + [code], page: page)
                XCTAssertEqual(output.stdout, expected, "\(transport) \(flags)")
            }
        }
    }

    func testNoCleanupIsAttemptedAfterATimeout() async {
        // The page's main thread is busy after a timeout; removing the slot would wait out a timeout of its own.
        let page = FakePage()
        page.forced = { script in script.contains(".len = r.length") ? "" : nil }
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let cleanups = LockedCounter()
        let outcome: Error? = await {
            do {
                try await DaemonRequestContext.$current.withValue(context) {
                    try await DaemonRequestContext.$appleScriptRunner.withValue({ script in
                        if script.contains("do JavaScript") {
                            if script.contains("delete window.__sbr_") { cleanups.increment() }
                            if script.contains(".len = r.length") { throw SafariBrowserError.processTimedOut(command: "osascript", seconds: 30) }
                        }
                        return try page.respond(script)
                    }) { _ = try await SafariBridge.doJavaScriptLarge("'x'.repeat(10)") }
                }
                return nil
            } catch { return error }
        }()
        guard case SafariBrowserError.processTimedOut? = outcome as? SafariBrowserError else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(cleanups.value, 0, "a removal after a timeout doubles the wait for the same error")
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
