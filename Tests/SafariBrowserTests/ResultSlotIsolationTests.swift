import XCTest
@testable import SafariBrowser

/// #190 at the level of the bridge: `doJavaScriptLarge` against a page that really runs what it is sent.
///
/// Every test that interleaves does it the way #190 saw it: another call stores its result in the page
/// WHILE this call is between its store and its last read.
final class ResultSlotIsolationTests: XCTestCase, @unchecked Sendable {

    /// The runner installed for the bridge: the page answers `do JavaScript`, anything else (a target
    /// read) is answered empty.
    private func withPage<T: Sendable>(_ page: FakePage, _ body: @Sendable () async throws -> T) async rethrows -> T {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        return try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try page.respond($0) }) {
                try await body()
            }
        }
    }

    private func large(_ expression: String, _ page: FakePage) async throws -> String {
        try await withPage(page) { try await SafariBridge.doJavaScriptLarge(expression) }
    }

    private let intruder = "window.__sbResult = 'INTRUDER'; window.__sbResultLen = 8; window.__sbLen = 8;"

    // MARK: - the #190 shape

    func testAnotherCallStoringInTheMiddleOfAReadDoesNotChangeTheResult() async throws {
        let page = FakePage()
        let expected = String(repeating: "a", count: ResultSlot.chunkSize) + String(repeating: "b", count: 1000)
        var intruded = false
        page.beforeRun = { script in
            // just before the SECOND chunk is read, a different call stores its own result
            if !intruded, script.contains("a = \(ResultSlot.chunkSize),") {
                intruded = true
                _ = page.evaluate(ResultSlot.make().storeScript("'INTRUDER'"))
                _ = page.evaluate(self.intruder)
            }
        }
        let result = try await large("'a'.repeat(\(ResultSlot.chunkSize)) + 'b'.repeat(1000)", page)
        XCTAssertTrue(intruded, "the second chunk read was never reached, so nothing was tested")
        XCTAssertEqual(result, expected)
    }

    func testTwoCallsThatEachStoreBeforeEitherReadsGetTheirOwnResults() async throws {
        let page = FakePage()
        var second: String?
        var started = false
        page.beforeRun = { script in
            // call 2 runs completely, in the middle of call 1's first read
            if !started, script.contains("a = 0,") {
                started = true
                let slot = ResultSlot.make()
                _ = page.evaluate(slot.storeScript("'second call'"))
                second = page.evaluate(slot.readScript(offset: 0, total: 11))
                _ = page.evaluate(slot.cleanupScript)
            }
        }
        let first = try await large("'first call'", page)
        XCTAssertEqual(first, "first call")
        XCTAssertEqual(second, "11:second call\u{1E}")
    }

    func testNothingIsLeftBehindInThePage() async throws {
        let page = FakePage()
        let before = page.windowKeys()
        _ = try await large("'x'.repeat(300000)", page)
        XCTAssertEqual(page.windowKeys(), before, "any new property on window is a leftover, not only one with the slot prefix")
        _ = try await large("''", page)
        XCTAssertEqual(page.windowKeys(), before, "an empty result used to be the one case the cleanup skipped")
    }

    func testTheOldSharedNamesAreNeverTouched() async throws {
        let page = FakePage()
        _ = try await large("'x'.repeat(300000)", page)
        for script in page.javaScripts {
            for old in ["__sbResult", "__sbResultLen", "__sbLargeErr", "__sbLen"] {
                XCTAssertFalse(script.contains(old), "\(old) in: \(script.prefix(160))")
            }
        }
    }

    // MARK: - a read that cannot be trusted is an error

    func testAPageThatWentAwayMidReadFailsInsteadOfReturningAShorterResult() async {
        let page = FakePage()
        var removed = false
        page.beforeRun = { script in
            if !removed, script.contains("a = \(ResultSlot.chunkSize),") {
                removed = true
                _ = page.evaluate("Object.getOwnPropertyNames(window).filter(function(k){return k.indexOf('__sbr_')===0}).forEach(function(k){delete window[k]})")
            }
        }
        do {
            let result = try await large("'a'.repeat(\(ResultSlot.chunkSize + 500))", page)
            XCTFail("a result cut at the first chunk must not come back as a result: \(result.count) units")
        } catch let error as SafariBrowserError {
            guard case .appleScriptFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("incomplete"), message)
            XCTAssertTrue(message.contains("not run again"), message)
        } catch { XCTFail("\(error)") }
    }

    func testAFailedReadStillCleansUpTheSlotItOwns() async {
        let page = FakePage()
        var removed = false
        page.beforeRun = { script in
            if !removed, script.contains("a = \(ResultSlot.chunkSize),") {
                removed = true
                // the slot is replaced by one of another length, which the read refuses
                _ = page.evaluate("Object.getOwnPropertyNames(window).filter(function(k){return k.indexOf('__sbr_')===0}).forEach(function(k){window[k].text='short'})")
            }
        }
        _ = try? await large("'a'.repeat(\(ResultSlot.chunkSize + 500))", page)
        XCTAssertTrue(removed, "the second chunk was never read, so nothing was tested")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [], "a slot the call made must not outlive the call")
    }

    // MARK: - what the transport does to the end of an answer

    func testTextEndingInWhitespaceSurvivesAChunkBoundaryInBothTransports() async throws {
        for transport in [FakePage.Transport.stateless, .daemon] {
            let page = FakePage()
            page.transport = transport
            let text = String(repeating: "a", count: ResultSlot.chunkSize - 3) + "  \n" + "tail"
            let result = try await large("'a'.repeat(\(ResultSlot.chunkSize - 3)) + '  \\n' + 'tail'", page)
            XCTAssertEqual(result, text, "\(transport)")
        }
    }

    func testResultThatEndsInOneNewlineLosesIt_AsItAlwaysDid() async throws {
        // The runner removed the result's own last newline; keeping that keeps what `js --large` prints.
        let page = FakePage()
        let result = try await large("'x\\n'", page)
        XCTAssertEqual(result, "x")
        let two = try await large("'x\\n\\n'", FakePage())
        XCTAssertEqual(two, "x\n")
    }

    func testALoneSurrogateComesBackAsTheReplacementCharacter() async throws {
        let result = try await large("'ab' + '\\uD83D' + 'cd'", FakePage())
        XCTAssertEqual(result, "ab\u{FFFD}cd")
    }

    func testEmptyAndMissingResultsAreEmptyNotErrors() async throws {
        let empty = try await large("''", FakePage())
        XCTAssertEqual(empty, "")
        let thrown = try await large("(function(){ throw new Error('x') })()", FakePage())
        XCTAssertEqual(thrown, "", "unchanged: a throwing internal expression has always read as empty here; JSCommand's wrappers catch their own")
    }
}
