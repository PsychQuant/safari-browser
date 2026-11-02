import XCTest
@testable import SafariBrowser

/// What `pdf-cache` tells the caller to do next, and what it prints.
///
/// An agent reads the CLI's words at the moment of failure. On 2026-11-02 one was sent to the listing, picked a
/// row with the same displayed URL, and copied a different PDF with exit 0 (#340). A listing row is not tied to
/// any tab, and the URL it shows has no query.
final class PDFCacheGuidanceTests: XCTestCase {
    private func cached(_ key: String, _ url: String) -> WebKitCachedPDF {
        WebKitCachedPDF(
            key: key, partitionDirectory: "partition", partition: "", requestURL: url,
            bodyURL: URL(fileURLWithPath: "/nonexistent/\(key)-blob"),
            recordURL: URL(fileURLWithPath: "/nonexistent/\(key)"), size: 10, modified: nil)
    }

    private func temporary(_ folder: String, _ name: String) -> TemporaryPDF {
        TemporaryPDF(folder: folder, name: name, url: URL(fileURLWithPath: "/nonexistent/\(folder)/\(name)"), size: 10, date: nil)
    }

    private func message(_ work: () throws -> Any) -> String {
        do { _ = try work(); XCTFail("expected a refusal"); return "" }
        catch { return (error as? SafariBrowserError)?.errorDescription ?? "\(error)" }
    }

    // MARK: - #340: the listing is for a person, not a next step

    func testATabMissDoesNotSendTheCallerToPickFromTheListing() {
        let text = message { try PDFCacheSelection.select(tabURL: "https://e.org/a.pdf", from: []) }
        XCTAssertFalse(text.contains("to see what is cached"), text)
        XCTAssertTrue(text.contains("so that a person can identify"), text)
        XCTAssertTrue(text.contains("not tied to any tab"), text)
        XCTAssertTrue(text.contains("same URL there can be a different PDF"), text)
        XCTAssertTrue(text.contains("safari-browser save-pdf"), text)
    }

    func testTwoRecordsForATabDoNotSayPickAKey() {
        let text = message {
            try PDFCacheSelection.select(tabURL: "https://e.org/a.pdf",
                                         from: [self.cached(String(repeating: "A", count: 40), "https://e.org/a.pdf"),
                                                self.cached(String(repeating: "B", count: 40), "https://e.org/a.pdf")])
        }
        XCTAssertFalse(text.contains("Re-run with --key <prefix> naming one of them."), text)
        XCTAssertTrue(text.contains("Nothing here says which one the tab displays"), text)
        XCTAssertTrue(text.contains("safari-browser save-pdf"), text)
        XCTAssertTrue(text.contains("a person has identified"), text)
    }

    func testAKeyPrefixMatchingSeveralAsksForALongerOne() {
        let text = PDFCacheFailure.ambiguous(subject: "key prefix AAAAAAAA", candidates: ["x"]).message
        XCTAssertTrue(text.contains("longer --key prefix"), text)
        XCTAssertFalse(text.contains("save-pdf"), text)
    }

    func testTheNoteAboutUnreadBodiesDoesNotPointAtAListingWithoutThem() {
        let scan = WebKitCacheReader.Scan(pdfs: [], unreadableKeys: ["A"])
        let note = PDFCacheSelection.unreadNote(scan) ?? ""
        XCTAssertFalse(note.contains("see `pdf-cache list`"), note)
        XCTAssertTrue(note.contains("`pdf-cache list` does not show them"), note)
    }

    func testTheLegendsSayARowIsForAPersonToIdentify() {
        let cache = PDFCacheFormat.cacheListing([], limit: 1, timeZone: .gmt).legend
        XCTAssertTrue(cache.contains("not tied to any tab"), cache)
        XCTAssertTrue(cache.contains("a person has identified"), cache)
        XCTAssertFalse(cache.contains("select one with"), cache)
        let files = PDFCacheFormat.temporaryListing([], limit: 1, timeZone: .gmt).legend
        XCTAssertTrue(files.contains("a person has identified"), files)
        XCTAssertTrue(files.contains("<folder>/<name>"), files)
    }

    // MARK: - #337: duplicates in the WebKitPDFs folders can be selected

    func testTheSameNameInTwoFoldersIsRefusedWithAWayThatWorks() {
        let pdfs = [temporary("WebKitPDFs-A", "a.pdf"), temporary("WebKitPDFs-B", "a.pdf")]
        let text = message { try PDFCacheSelection.select(fileName: "a.pdf", from: pdfs) }
        XCTAssertFalse(text.contains("--key"), text)
        XCTAssertTrue(text.contains("--file <folder>/<name>"), text)
        XCTAssertTrue(text.contains("the same name"), text)
    }

    func testFolderAndNameSelectsOne() throws {
        let pdfs = [temporary("WebKitPDFs-A", "a.pdf"), temporary("WebKitPDFs-B", "a.pdf")]
        XCTAssertEqual(try PDFCacheSelection.select(fileName: "WebKitPDFs-B/a.pdf", from: pdfs), pdfs[1])
    }

    /// A candidate line escapes the name, so the way out cannot be "paste what is shown": a name with a dash or
    /// a double space would then match nothing. The folder is shown as it is, and the name is what was typed.
    func testTheWayOutWorksForANameACandidateLineEscapes() throws {
        let name = "Paper \u{2014}  Final.pdf"
        let pdfs = [temporary("WebKitPDFs-A", name), temporary("WebKitPDFs-B", name)]
        let line = PDFCacheFormat.candidateLine(pdfs[1])
        XCTAssertFalse(line.contains(name), "this test is about a name the line changes: \(line)")
        let folder = String(line.components(separatedBy: "/")[0])
        XCTAssertEqual(folder, "WebKitPDFs-B")
        XCTAssertEqual(try PDFCacheSelection.select(fileName: "\(folder)/\(name)", from: pdfs), pdfs[1])
    }

    /// The name part matches as a bare name does, so a form of the name that selects one also selects within a folder.
    func testTheNamePartMatchesAsABareNameDoes() throws {
        let composed = "caf\u{00E9}.pdf"
        let decomposed = "cafe\u{0301}.pdf"
        let pdfs = [temporary("WebKitPDFs-A", decomposed)]
        XCTAssertEqual(try PDFCacheSelection.select(fileName: composed, from: pdfs), pdfs[0])
        XCTAssertEqual(try PDFCacheSelection.select(fileName: "WebKitPDFs-A/\(composed)", from: pdfs), pdfs[0])
    }

    func testAskingForASelectionDoesNotOfferTheListingAsTheWay() {
        let text = PDFCacheFailure.selectionRequired.message
        XCTAssertTrue(text.contains("a person has identified"), text)
        XCTAssertTrue(text.contains("not tied to any tab"), text)
        XCTAssertTrue(text.contains("safari-browser save-pdf"), text)
    }

    func testTheHelpAndTheJSONCautionSayTheSame() {
        XCTAssertTrue(PDFCacheFormat.listingCaution.contains("not tied to any tab"))
        let help = PDFCacheGet.helpMessage()
        XCTAssertTrue(help.contains("not tied to any tab"), help)
        XCTAssertTrue(help.contains("a person has identified"), help)
    }

    func testAFolderThatWasNotListedMatchesNothing() {
        let pdfs = [temporary("WebKitPDFs-A", "a.pdf")]
        for wanted in ["WebKitPDFs-B/a.pdf", "../WebKitPDFs-A/a.pdf", "WebKitPDFs-A/../WebKitPDFs-A/a.pdf", "/a.pdf"] {
            XCTAssertThrowsError(try PDFCacheSelection.select(fileName: wanted, from: pdfs), wanted) { error in
                guard case SafariBrowserError.pdfCache(.noMatch) = error else { return XCTFail("\(wanted): \(error)") }
            }
        }
    }

    func testAFileMissPointsAtTheListingOfThoseFiles() {
        let text = message { try PDFCacheSelection.select(fileName: "a.pdf", from: []) }
        XCTAssertTrue(text.contains("pdf-cache list --source webkit-pdfs"), text)
        XCTAssertFalse(text.contains("A tab is matched"), text)
    }

    // MARK: - #342: the same secrets go as in error messages

    func testPathParametersAndCredentialsAreNotShown() {
        for url in ["https://pub.example/doi/pdf/x;jsessionid=SECRET/main.pdf", "https://user:SECRET@pub.example/main.pdf"] {
            XCTAssertFalse(PDFCacheURL.redact(url).display.contains("SECRET"), url)
        }
    }

    func testHasQueryStaysAFieldAndNoMarkerIsAddedToTheDisplay() {
        let redacted = PDFCacheURL.redact("https://e.org/a.pdf?sig=SECRET#page=2")
        XCTAssertEqual(redacted, .init(display: "https://e.org/a.pdf", hadQuery: true))
    }

    func testListingsAndCandidatesCarryNoPathParameter() throws {
        let pdf = cached(String(repeating: "A", count: 40), "https://pub.example/x;jsessionid=SECRET/main.pdf?sig=SECRET")
        let rows = PDFCacheFormat.cacheListing([pdf], limit: 1, timeZone: .gmt).rows.joined()
        XCTAssertFalse(rows.contains("SECRET"), rows)
        XCTAssertFalse(PDFCacheFormat.candidateLine(pdf).contains("SECRET"))
        let json = String(decoding: try PDFCacheFormat.cacheListingJSON([pdf], limit: 1), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET"), json)
    }

    /// Display only: matching stays on the whole string.
    func testATabIsStillMatchedByItsWholeURL() throws {
        let url = "https://pub.example/x;jsessionid=AB/main.pdf"
        let pdf = cached(String(repeating: "A", count: 40), url)
        XCTAssertEqual(try PDFCacheSelection.select(tabURL: url, from: [pdf]), pdf)
        XCTAssertThrowsError(try PDFCacheSelection.select(tabURL: "https://pub.example/x;jsessionid=CD/main.pdf", from: [pdf]))
    }
}
