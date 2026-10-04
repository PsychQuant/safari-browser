import XCTest
@testable import SafariBrowser

/// #190: `get text <selector>` and `get html <selector>` fall back to a chunked read when the plain answer
/// comes back empty although the element has content. They used to park the text under the shared names
/// first and then read it back by name; they now hand the expression to the chunked read, which parks it in
/// a slot of its own.
final class ResultSlotGetTests: XCTestCase, @unchecked Sendable {

    private func page(text: String, html: String) -> FakePage {
        let page = FakePage()
        // A plain answer longer than a chunk comes back empty, as an over-long one did when #1 added the
        // chunked read; the chunks themselves (one chunk plus its framing) are short enough to come back.
        page.maxAnswerUnits = ResultSlot.chunkSize + 1000
        let data = try! JSONSerialization.data(withJSONObject: [text, html], options: [])
        _ = page.evaluate("var __v = \(String(decoding: data, as: UTF8.self)); var document = { querySelector: function(){ return { textContent: __v[0], innerHTML: __v[1] }; } };")
        return page
    }

    private func printed(_ page: FakePage, _ body: @escaping @Sendable () async throws -> Void) async throws -> String {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let out = JSCommandRoundTripTests.FDCapture(STDOUT_FILENO)
        out.start()
        do {
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try page.respond($0) }) { try await body() }
            }
        } catch { _ = out.stop(); throw error }
        return out.stop()
    }

    func testGetTextWithASelectorReadsALargeElementFromItsOwnSlot() async throws {
        let text = String(repeating: "t", count: 700_000)
        let page = page(text: text, html: "")
        let output = try await printed(page) { try await GetText.parse(["#big"]).run() }
        XCTAssertEqual(output, text + "\n")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
        for script in page.javaScripts { XCTAssertFalse(script.contains("__sbResult"), "a name every call shares (#190)") }
    }

    func testGetHTMLWithASelectorReadsALargeElementFromItsOwnSlot() async throws {
        let html = "<p>" + String(repeating: "h", count: 400_000) + "</p>"
        let page = page(text: "", html: html)
        let output = try await printed(page) { try await GetHTML.parse(["#big"]).run() }
        XCTAssertEqual(output, html + "\n")
        XCTAssertEqual(page.keys(withPrefix: "__sbr_"), [])
        for script in page.javaScripts { XCTAssertFalse(script.contains("__sbResult"), "a name every call shares (#190)") }
    }

    func testAnotherCallStoringInTheMiddleDoesNotChangeWhatGetTextPrints() async throws {
        let text = String(repeating: "t", count: 2 * ResultSlot.chunkSize + 500)
        let page = page(text: text, html: "")
        var intruded = false
        page.beforeRun = { script in
            if !intruded, script.contains("a = \(ResultSlot.chunkSize),") {
                intruded = true
                _ = page.evaluate(ResultSlot.make().storeScript("'INTRUDER'"))
                _ = page.evaluate("window.__sbResult = 'INTRUDER'; window.__sbResultLen = 8;")
            }
        }
        let output = try await printed(page) { try await GetText.parse(["#big"]).run() }
        XCTAssertTrue(intruded)
        XCTAssertEqual(output, text + "\n")
    }
}
