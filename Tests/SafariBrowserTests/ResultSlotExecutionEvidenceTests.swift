import XCTest
@testable import SafariBrowser

/// #257 B2, the half that was left (#260): for the paths that park a result in the page AND run the user's
/// code (`js --large`, `js --output`), the slot is also the evidence that the code started. Whether to try
/// the second form, and whether to run anything again, is decided from that evidence and not from the
/// absence of a result.
final class ResultSlotExecutionEvidenceTests: XCTestCase, @unchecked Sendable {

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
                }) { try await command.run() }
            }
        } catch { _ = err.stop(); _ = out.stop(); throw error }
        let stderr = err.stop()
        return (out.stop(), stderr)
    }

    private func failure(_ args: [String], page: FakePage, fake: JSCommandRoundTripTests.FakeSafari = .init()) async -> String? {
        do { try await run(args, page: page, fake: fake); return nil }
        catch let error as SafariBrowserError { if case .appleScriptFailed(let m) = error { return m }; return "\(error)" }
        catch { return "\(error)" }
    }

    // MARK: - a thrown value is an error whatever it is (#260)

    func testAThrownStringIsReportedLikeThePlainPathReportsIt() async {
        let message = await failure(["--large"] + target + ["throw 'boom'"], page: FakePage())
        XCTAssertEqual(message, "JavaScript error: boom")
    }

    func testAThrownNullIsReportedAndTheCodeRanOnce() async {
        let page = FakePage()
        let message = await failure(["--large"] + target + ["(__count(), (function(){ throw null })())"], page: page)
        XCTAssertEqual(message, "JavaScript error: null")
        XCTAssertEqual(page.executions, 1, "the code was run a second time, as the statement form, after the first threw")
    }

    func testAThrownEmptyStringIsStillAnError() async {
        let message = await failure(["--large"] + target + ["throw ''"], page: FakePage())
        XCTAssertEqual(message, "JavaScript error: ")
    }

    func testAThrownValueThatCannotBeTurnedIntoTextStillGetsAnError() async {
        let message = await failure(["--large"] + target + ["throw Symbol('s')"], page: FakePage())
        XCTAssertEqual(message, "JavaScript error: Symbol(s)")
    }

    func testAnOutputFileIsKeptWhenTheCodeThrew() async throws {
        let path = NSTemporaryDirectory() + "sb-evidence-\(UUID().uuidString).txt"
        try "OLD".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = await failure(["--output", path] + target + ["throw 'boom'"], page: FakePage())
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "OLD")
    }

    // MARK: - the code is not run again

    func testCodeThatReloadsThePageIsNotRunAgainAndTheFileIsKept() async throws {
        let path = NSTemporaryDirectory() + "sb-evidence-\(UUID().uuidString).txt"
        try "OLD".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let page = FakePage()
        let message = await failure(["--output", path] + target + ["__count(), __reload(), 'x'.repeat(10)"], page: page)
        XCTAssertEqual(page.executions, 1, "a lost result on an unchanged address used to run the code a second time")
        XCTAssertTrue(message?.contains("was not run again") == true, message ?? "no error")
        XCTAssertTrue(message?.contains("cannot be known") == true, message ?? "no error")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "OLD")
    }

    func testStatementCodeThatReloadsThePageIsNotRunAgain() async {
        let page = FakePage()
        let message = await failure(["--large"] + target + ["__count(); __reload(); return 'x';"], page: page)
        XCTAssertEqual(page.executions, 1)
        XCTAssertTrue(message?.contains("was not run again") == true, message ?? "no error")
    }

    func testCodeThatNavigatedIsStillANavigationNotAnError() async throws {
        let page = FakePage()
        let fake = JSCommandRoundTripTests.FakeSafari()
        fake.navigatedURL = "https://w1.example/done"
        fake.navigatesFromURLRead = 2
        let output = try await run(["--large"] + target + ["__count(), __reload(), 'x'"], page: page, fake: fake)
        XCTAssertEqual(output.stdout, "")
        XCTAssertTrue(output.stderr.contains("navigated"), output.stderr)
        XCTAssertEqual(page.executions, 1)
    }

    // MARK: - what still works

    func testStatementFormRunsOnceWhenTheExpressionFormDoesNotParse() async throws {
        let page = FakePage()
        let output = try await run(["--large"] + target + ["__count(); return 'five';"], page: page)
        XCTAssertEqual(output.stdout, "five\n")
        XCTAssertEqual(page.executions, 1, "the expression form never started, so only the statement form ran")
    }

    func testCodeThatParsesNeitherWayIsASyntaxErrorAndNeverRuns() async {
        let page = FakePage()
        let message = await failure(["--large"] + target + ["__count(); 1 +"], page: page)
        XCTAssertTrue(message?.contains("syntax error") == true, message ?? "no error")
        XCTAssertEqual(page.executions, 0)
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
    }

    func testAnEmptyResultIsStillAnEmptyResult() async throws {
        let page = FakePage()
        let output = try await run(["--large"] + target + ["(__count(), '')"], page: page)
        XCTAssertEqual(output.stdout, "")
        XCTAssertEqual(page.executions, 1)
    }

    func testAResultThatIsOnlyOneNewlineIsAnEmptyResultNotAnError() async throws {
        // The slot holds one unit; the one trailing newline the output has always lost leaves nothing. That is the
        // recorded result, not "the code started and recorded nothing". (Found on a real Safari, not by the unit tests.)
        for code in ["'\\n'", "(__count(), '\\n')"] {
            let page = FakePage()
            let output = try await run(["--large"] + target + [code], page: page)
            XCTAssertEqual(output.stdout, "", code)
        }
        let page = FakePage()
        let two = try await run(["--large"] + target + ["'\\n\\n'"], page: page)
        XCTAssertEqual(two.stdout, "\n\n", "two newlines lose one and print the other")
    }

    func testAnEmptyResultFromAStatementFormIsAnEmptyResultToo() async throws {
        let page = FakePage()
        let output = try await run(["--large"] + target + ["__count(); return '';"], page: page)
        XCTAssertEqual(output.stdout, "")
        XCTAssertEqual(page.executions, 1)
    }

    func testACodeThatStartedWithNoResultAndNoErrorFailsInsteadOfBeingRunAgain() async {
        // not something a wrapper produces; if a page ever makes it happen, the answer is an error, not a second run
        let page = FakePage()
        page.forced = { js in js.contains("'idle:'") ? "started:undefined" : nil }
        let message = await failure(["--large"] + target + ["(__count(), __reload(), 'x'.repeat(5)).length"], page: page)
        XCTAssertTrue(message?.contains("started but no result was recorded") == true, message ?? "no error")
        XCTAssertEqual(page.executions, 1)
    }

    func testAReadOfTheProgressThatWasLostIsTreatedAsAPageThatWasReplacedNotAsNothingRan() async {
        let page = FakePage()
        page.forced = { js in js.contains("'idle:'") ? "" : nil }
        let message = await failure(["--large"] + target + ["(__count(), __reload(), 'x')"], page: page)
        XCTAssertTrue(message?.contains("cannot be known") == true, message ?? "no error")
        XCTAssertEqual(page.executions, 1, "an answer that is not understood must never let the code run again")
    }

    func testAPageReplacedBetweenThePresetAndTheStoreStillReportsWhatTheCodeThrew() async {
        // The slot the preset made went with the old document. The store makes it again BEFORE the code runs, so the
        // new document records the mark and the error. Made after, an error thrown here would be lost and read as nothing.
        let page = FakePage()
        var replaced = false
        page.beforeRun = { script in
            if !replaced, script.contains("s.text = r") { replaced = true; page.replaceDocument() }
        }
        let message = await failure(["--large"] + target + ["(__count(), (function(){ throw 'boom' })())"], page: page)
        XCTAssertTrue(replaced, "the store was never reached, so nothing was tested")
        XCTAssertEqual(message, "JavaScript error: boom")
        XCTAssertEqual(page.executions, 1)
    }

    // MARK: - an error is never read as "no error" (second review)

    func testAMessageThatStartsWithACombiningMarkIsStillTheMessage() async {
        // `E:` followed by a combining scalar is ONE Character; the prefix is read by scalar, never by Character (#255)
        for lead in ["\\u0301", "\\u200D", "\\uFE0F"] {
            let message = await failure(["--large"] + target + ["throw '\(lead)boom'"], page: FakePage())
            XCTAssertNotNil(message, "an error whose message starts with \(lead) was read as no error")
            // compared by scalar: a space followed by a combining mark is one Character, which is the point
            XCTAssertTrue(message?.unicodeScalars.starts(with: "JavaScript error: ".unicodeScalars) == true, message ?? "no error")
            XCTAssertTrue(message?.unicodeScalars.reversed().starts(with: "boom".unicodeScalars.reversed()) == true, message ?? "")
        }
    }

    func testAThrownObjectWhoseTextCannotBeReadStillGivesAnError() async {
        let page = FakePage()
        let hostile = "throw { get message() { throw 1 }, toString() { return Symbol('s') } }"
        let message = await failure(["--large"] + target + [hostile], page: page)
        XCTAssertEqual(message, "JavaScript error: unprintable exception")
        let undefinedText = await failure(["--large"] + target + ["throw { get message() { throw 1 }, toString() { return undefined } }"], page: FakePage())
        XCTAssertEqual(undefinedText, "JavaScript error: undefined")
    }

    func testAnEnormousMessageIsCutSoItCanBeReadInOneAnswer() async {
        let page = FakePage()
        page.maxAnswerUnits = 131_072         // a longer plain answer comes back empty, as on the Safari that made #1 add chunks
        let message = await failure(["--large"] + target + ["throw 'x'.repeat(300000)"], page: page)
        XCTAssertTrue(message?.hasPrefix("JavaScript error: xxx") == true, "an over-long message was read as no error: \(String(describing: message?.prefix(80)))")
        XCTAssertLessThan(message?.count ?? 0, 20_000)
        XCTAssertTrue(message?.hasSuffix("…") == true)
    }

    func testAnErrorWhoseMessageCannotBeReadBackIsStillAnErrorAndRanOnce() async {
        let page = FakePage()
        page.forced = { js in js.contains("'E:' + s.err") ? "" : nil }       // the message read is lost
        let message = await failure(["--large"] + target + ["(__count(), (function(){ throw 'boom' })())"], page: page)
        XCTAssertTrue(message?.hasPrefix("JavaScript error: the code threw") == true, message ?? "no error")
        XCTAssertEqual(page.executions, 1)
    }

    func testASlotThatHoldsAResultThatWasNotReadBackIsAnErrorNotAnEmptyResult() async {
        let page = FakePage()
        page.forced = { js in js.contains("'' + s.len : 'undefined'") ? "" : nil }   // the length read is lost; the result is in the slot
        let message = await failure(["--large"] + target + ["(__count(), 'hello')"], page: page)
        XCTAssertTrue(message?.hasPrefix(ResultSlot.incompleteTransferPrefix) == true, message ?? "an unread result printed nothing and exited 0")
        XCTAssertEqual(page.executions, 1)
    }

    // MARK: - the invariant, over every moment the page can be replaced (second review)

    func testNoMomentOfReplacementMakesTheCodeRunTwiceAndNoneLeavesAFileOverwritten() async throws {
        let codes = ["(__count(), 'x'.repeat(5))", "__count(); return 'x'.repeat(5);", "(__count(), (function(){ throw 'boom' })())", "(__count(), '')"]
        for code in codes {
            for moment in 0..<9 {
                let page = FakePage()
                var scripts = 0
                page.beforeRun = { _ in
                    if scripts == moment { page.replaceDocument() }
                    scripts += 1
                }
                let path = NSTemporaryDirectory() + "sb-matrix-\(UUID().uuidString).txt"
                try "OLD".write(toFile: path, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(atPath: path) }
                let message = await failure(["--output", path] + target + [code], page: page)
                XCTAssertLessThanOrEqual(page.executions, 1, "\(code) replaced before script \(moment): the code ran \(page.executions) times")
                if message != nil {
                    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "OLD", "\(code) replaced before script \(moment): failed, but the file was written")
                }
                XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [], "\(code) replaced before script \(moment): a slot was left")
            }
        }
    }

    func testStatementCodeWhosePageIsReplacedBeforeTheFirstStoreStillRunsOnce() async throws {
        // Only the form that compiles here is sent, so the form that cannot parse is not what meets the replaced page.
        let page = FakePage()
        var replaced = false
        page.beforeRun = { script in
            if !replaced, script.contains("s.text = r") { replaced = true; page.replaceDocument() }
        }
        let output = try await run(["--large"] + target + ["__count(); return 'five';"], page: page)
        XCTAssertTrue(replaced)
        XCTAssertEqual(output.stdout, "five\n")
        XCTAssertEqual(page.executions, 1)
    }

    // MARK: - a read that fails is never a reason to run the code again

    private func failureWithRunner(_ args: [String], page: FakePage, failing marker: String, with error: SafariBrowserError) async -> Error? {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let fake = JSCommandRoundTripTests.FakeSafari()
        do {
            let command = try JSCommand.parse(args)
            let out = JSCommandRoundTripTests.FDCapture(STDOUT_FILENO), err = JSCommandRoundTripTests.FDCapture(STDERR_FILENO)
            out.start(); err.start()
            defer { _ = err.stop(); _ = out.stop() }
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ script in
                    if script.contains("do JavaScript"), script.contains(marker) { throw error }
                    return script.contains("do JavaScript") ? try page.respond(script) : try fake.respond(script)
                }) { try await command.run() }
            }
            return nil
        } catch { return error }
    }

    func testAReadOfTheProgressThatTimesOutDoesNotRunTheCodeAgain() async {
        let page = FakePage()
        let outcome = await failureWithRunner(["--large"] + target + ["(__count(), __reload(), 'x')"], page: page,
                                              failing: "'idle:'", with: .processTimedOut(command: "osascript", seconds: 30))
        guard case SafariBrowserError.processTimedOut? = outcome as? SafariBrowserError else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(page.executions, 1)
    }

    func testAReadOfTheErrorThatFailsDoesNotRunTheCodeAgain() async {
        let page = FakePage()
        let outcome = await failureWithRunner(["--large"] + target + ["(__count(), (function(){ throw 'boom' })())"], page: page,
                                              failing: "'E:' + s.err", with: .appleScriptFailed("execution error: Safari got an error: Can’t get tab. Invalid index. (-1719)"))
        XCTAssertNotNil(outcome)
        XCTAssertEqual(page.executions, 1)
    }

    func testAReadOfTheLengthThatFailsDoesNotRunTheCodeAgain() async {
        let page = FakePage()
        let outcome = await failureWithRunner(["--large"] + target + ["(__count(), 'hello')"], page: page,
                                              failing: "'' + s.len : 'undefined'", with: .processTimedOut(command: "osascript", seconds: 30))
        XCTAssertNotNil(outcome)
        XCTAssertEqual(page.executions, 1)
    }

    // MARK: - what the transport does to the end of the answer

    func testAMessageThatIsOnlyWhitespaceIsStillAnErrorOnBothTransports() async {
        for transport in [FakePage.Transport.stateless, .daemon] {
            for thrown in ["' '", "'\\n'", "'  \\n\\n'"] {
                let page = FakePage()
                page.transport = transport
                let message = await failure(["--large"] + target + ["throw \(thrown)"], page: page)
                XCTAssertTrue(message?.hasPrefix("JavaScript error:") == true, "\(transport) throw \(thrown): \(message ?? "no error")")
            }
        }
    }

    // MARK: - a limit that stays, pinned

    func testCodeThatThrowsAndThenNavigatesIsReportedAsANavigation() async throws {
        // The error was recorded in the document that went away. This is a known limit (design.md), pinned so a change to it is deliberate.
        let page = FakePage()
        let fake = JSCommandRoundTripTests.FakeSafari()
        fake.navigatedURL = "https://w1.example/done"
        fake.navigatesFromURLRead = 2
        let output = try await run(["--large"] + target + ["(__count(), __reload(), (function(){ throw 'x' })())"], page: page, fake: fake)
        XCTAssertEqual(output.stdout, "")
        XCTAssertTrue(output.stderr.contains("navigated"), output.stderr)
        XCTAssertEqual(page.executions, 1)
    }

    func testTheSlotIsGoneAfterEveryOutcome() async {
        for code in ["throw 'x'", "(__count(), __reload(), 1)", "1 +", "'ok'.repeat(3)"] {
            let page = FakePage()
            _ = await failure(["--large"] + target + [code], page: page)
            XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [], code)
        }
    }
}
