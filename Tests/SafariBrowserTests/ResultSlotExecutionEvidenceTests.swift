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

    func testAnEmptyResultFromAStatementFormIsAnEmptyResultToo() async throws {
        let page = FakePage()
        let output = try await run(["--large"] + target + ["__count(); return '';"], page: page)
        XCTAssertEqual(output.stdout, "")
        XCTAssertEqual(page.executions, 1)
    }

    func testACodeThatStartedWithNoResultAndNoErrorFailsInsteadOfBeingRunAgain() async {
        // not something a wrapper produces; if a page ever makes it happen, the answer is an error, not a second run
        let page = FakePage()
        page.forced = { js in js.contains("(s.started ? 'started:' : 'idle:')") ? "started:undefined" : nil }
        let message = await failure(["--large"] + target + ["(__count(), __reload(), 'x'.repeat(5)).length"], page: page)
        XCTAssertTrue(message?.contains("started but no result was recorded") == true, message ?? "no error")
        XCTAssertEqual(page.executions, 1)
    }

    func testAReadOfTheProgressThatWasLostIsTreatedAsAPageThatWasReplacedNotAsNothingRan() async {
        let page = FakePage()
        page.forced = { js in js.contains("(s.started ? 'started:' : 'idle:')") ? "" : nil }
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

    func testTheSlotIsGoneAfterEveryOutcome() async {
        for code in ["throw 'x'", "(__count(), __reload(), 1)", "1 +", "'ok'.repeat(3)"] {
            let page = FakePage()
            _ = await failure(["--large"] + target + [code], page: page)
            XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [], code)
        }
    }
}
