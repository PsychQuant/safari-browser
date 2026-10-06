import XCTest
@testable import SafariBrowser

/// #190 review: the wrappers run the user's code INSIDE a function of their own, so any `var` the wrapper
/// declares in that function shadows a global of the same name in the page, and the user's code silently
/// reads `undefined`. Before this change none of the large-path wrappers declared a variable (they used two
/// page globals), so a page with a global `s`, `r` or `k` (an analytics object, a loop variable left behind)
/// answered correctly; the slot wrappers must not take that away.
final class ResultSlotShadowingTests: XCTestCase, @unchecked Sendable {

    private let target = ["--window", "1", "--tab-in-window", "53"]

    /// A page that already has globals with the names the wrappers are tempted to use.
    private func pageWithGlobals() -> FakePage {
        let page = FakePage()
        _ = page.evaluate("var s = { pageName: 'PAGE' }; var r = 'PAGE-R'; var k = 'PAGE-K'; var e = 'PAGE-E'; var m = 'PAGE-M';")
        return page
    }

    @discardableResult
    private func run(_ args: [String], page: FakePage) async throws -> String {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let command = try JSCommand.parse(args)
        let fake = JSCommandRoundTripTests.FakeSafari()
        let out = JSCommandRoundTripTests.FDCapture(STDOUT_FILENO), err = JSCommandRoundTripTests.FDCapture(STDERR_FILENO)
        out.start(); err.start()
        do {
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ script in
                    script.contains("do JavaScript") ? try page.respond(script) : try fake.respond(script)
                }) { try await command.run() }
            }
        } catch { _ = err.stop(); _ = out.stop(); throw error }
        _ = err.stop()
        return out.stop()
    }

    func testTheStoreScriptDoesNotShadowAPageGlobal() async throws {
        let page = pageWithGlobals()
        let result = try await withBridge(page) {
            try await SafariBridge.doJavaScriptLarge("JSON.stringify(s) + r")
        }
        XCTAssertEqual(result, "{\"pageName\":\"PAGE\"}PAGE-R")
    }

    func testLargeExpressionReadsPageGlobalsNamedLikeTheWrapperLocals() async throws {
        let page = pageWithGlobals()
        let out = try await run(["--large"] + target + ["JSON.stringify(s) + r + k"], page: page)
        XCTAssertEqual(out, "{\"pageName\":\"PAGE\"}PAGE-RPAGE-K\n")
    }

    func testLargeStatementReadsPageGlobalsNamedLikeTheWrapperLocals() async throws {
        let page = pageWithGlobals()
        let out = try await run(["--large"] + target + ["return JSON.stringify(s) + r;"], page: page)
        XCTAssertEqual(out, "{\"pageName\":\"PAGE\"}PAGE-R\n")
    }

    func testLargeRuntimeErrorStillReachesTheSlotWhenThePageHasAGlobalS() async {
        let page = pageWithGlobals()
        do {
            _ = try await run(["--large"] + target + ["(function(){ throw new Error('boom') })()"], page: page)
            XCTFail("a runtime error must be reported")
        } catch let error as SafariBrowserError {
            guard case .appleScriptFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "JavaScript error: boom")
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
    }

    func testABigInlineResultReadsAPageGlobalNamedK() async throws {
        let page = pageWithGlobals()
        let out = try await run(target + ["k + 'x'.repeat(200000)"], page: page)
        XCTAssertEqual(out, "PAGE-K" + String(repeating: "x", count: 200_000) + "\n")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
    }

    func testTheBigInlineWrapperLeavesThePageGlobalsAlone() async throws {
        let page = pageWithGlobals()
        _ = try await run(target + ["'x'.repeat(200000)"], page: page)
        XCTAssertEqual(page.evaluate("k"), "PAGE-K", "the wrapper must not assign a global named k")
        XCTAssertEqual(page.evaluate("typeof s"), "object")
    }

    /// A page may stub the clock and the random source (fake timers in a test page, a privacy extension);
    /// the name the page picks must stay unique and must still pass the CLI's check.
    func testAPageThatStubsTheClockAndRandomStillGetsAUsableUniqueName() async throws {
        let page = FakePage()
        _ = page.evaluate("Date.now = function(){ return 0 }; Math.random = function(){ return 0 };")
        var names = Set<String>()
        for _ in 0..<3 {
            let reply = try XCTUnwrap(page.evaluate(JSWrapper.inlineExpression("'x'.repeat(200000)")))
            guard case .stored(let slot, _) = JSWrapper.parseInline(reply) else { return XCTFail("not accepted as a slot: \(reply.prefix(60))") }
            names.insert(slot.key)
        }
        XCTAssertEqual(names.count, 3)
    }

    func testAPageWhoseCounterWasTamperedWithStillGetsAUsableName() async throws {
        let page = FakePage()
        for tamper in ["window.__sbn = -5;", "window.__sbn = 'abc';", "window.__sbn = 1.5;", "window.__sbn = Infinity;"] {
            _ = page.evaluate(tamper)
            let reply = try XCTUnwrap(page.evaluate(JSWrapper.inlineExpression("'x'.repeat(200000)")))
            guard case .stored = JSWrapper.parseInline(reply) else { return XCTFail("\(tamper) → \(reply.prefix(60))") }
        }
    }

    // MARK: - the inline wrappers (#259)

    /// #259: `inlineExpression` / `inlineStatement` ran the user's code inside a function that declared `var r`
    /// (the result) and, through `inlineCatch`, `var m` (the message). `var` is function-scoped, so a page that
    /// had a global `r` or `m` made the user's expression read `undefined`, with no error. The slot wrappers
    /// were fixed in #190 by passing the code as an argument of a function that has its own parameter; the
    /// inline ones were not.
    ///
    /// Every single-letter global is defined, not only the two names the wrapper used: the next variable a
    /// wrapper declares will be another short name, and a test that names only the known ones does not see it.
    private static let letters = Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
    private static let allLetters = letters.map { "PAGE-\($0)" }.joined(separator: ",")
    private static var readAllLetters: String { "[\(letters.joined(separator: ","))].join(',')" }

    private func pageWithEveryLetter() -> FakePage {
        let page = FakePage()
        _ = page.evaluate(Self.letters.map { "var \($0) = 'PAGE-\($0)';" }.joined())
        return page
    }

    func testInlineExpressionReadsEveryPageGlobalNamedWithOneLetter() async throws {
        let out = try await run(target + [Self.readAllLetters], page: pageWithEveryLetter())
        XCTAssertEqual(out, Self.allLetters + "\n")
    }

    func testInlineStatementReadsEveryPageGlobalNamedWithOneLetter() async throws {
        let out = try await run(target + ["return \(Self.readAllLetters);"], page: pageWithEveryLetter())
        XCTAssertEqual(out, Self.allLetters + "\n")
    }

    func testABigInlineResultReadsEveryPageGlobalNamedWithOneLetter() async throws {
        let page = pageWithEveryLetter()
        let out = try await run(target + [Self.readAllLetters + " + 'x'.repeat(200000)"], page: page)
        XCTAssertEqual(out, Self.allLetters + String(repeating: "x", count: 200_000) + "\n")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
    }

    func testAnInlineErrorMessageIsBuiltFromTheUsersCodeNotFromAShadowedGlobal() async {
        let page = pageWithEveryLetter()
        do {
            _ = try await run(target + ["(function(){ throw new Error(\(Self.readAllLetters)) })()"], page: page)
            XCTFail("a runtime error must be reported")
        } catch let error as SafariBrowserError {
            guard case .appleScriptFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "JavaScript error: " + Self.allLetters)
        } catch { XCTFail("\(error)") }
    }

    /// The wrapper must not leave anything behind in the page either: it assigns no global of its own except
    /// the counter that names a big result's slot and the slot, and it does not change one the page already has.
    /// The big result is part of this: its naming function declares `n`, `t` and `k` (#259 verify: a mutant that
    /// dropped the `var` of those two survived a test that never ran that branch).
    func testTheInlineWrappersDoNotChangeThePageGlobals() async throws {
        let page = pageWithEveryLetter()
        let before = page.windowKeys()
        _ = try await run(target + ["1 + 1"], page: page)
        _ = try await run(target + ["return 2;"], page: page)
        _ = try? await run(target + ["(function(){ throw new Error('x') })()"], page: page)
        let reply = try XCTUnwrap(page.evaluate(JSWrapper.inlineExpression("'x'.repeat(200000)")))
        guard case .stored(let slot, _) = JSWrapper.parseInline(reply) else { return XCTFail("not parked: \(reply.prefix(60))") }
        XCTAssertEqual(page.evaluate(Self.readAllLetters), Self.allLetters)
        XCTAssertEqual(page.windowKeys().subtracting(before), ["__sbn", slot.key])
    }

    // MARK: -

    private func withBridge<T: Sendable>(_ page: FakePage, _ body: @Sendable () async throws -> T) async rethrows -> T {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        return try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try page.respond($0) }) { try await body() }
        }
    }
}
