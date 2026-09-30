import XCTest
@testable import SafariBrowser

/// #227: the shared targeting errors, the `--first-match` warning and two navigation notes show
/// the URLs of tabs. A query string can be a credential (signed links keep their signature there;
/// an OAuth callback keeps its code or token in the query or fragment), so those places show
/// scheme, host and path with a marker where something was removed.
///
/// The redaction happens where the error payload is BUILT. A daemon's wire error and log line
/// print `"\(error)"`, not `errorDescription`, so these tests drive the real producers and check
/// the payload's own description as well as the rendered text.
final class URLTextTests: XCTestCase {
    private let secret = "SECRETVALUE"

    // MARK: - One URL

    func testAQueryAndAFragmentAreReplacedByMarkers() {
        XCTAssertEqual(URLText.redactURL("https://a.example/p?sig=SECRET"), "https://a.example/p?…")
        XCTAssertEqual(URLText.redactURL("https://a.example/p#frag"), "https://a.example/p#…")
        XCTAssertEqual(URLText.redactURL("https://a.example/p?sig=SECRET#frag"), "https://a.example/p?…")
        // A `?` after the `#` belongs to the fragment, not to a query.
        XCTAssertEqual(URLText.redactURL("https://a.example/p#frag?x=1"), "https://a.example/p#…")
        XCTAssertEqual(URLText.redactURL("https://a.example/p"), "https://a.example/p")
        XCTAssertEqual(URLText.redactURL(""), "")
    }

    /// No requirement that the text look like `scheme://…`: `about:` and `data:` URLs carry secrets too.
    func testTheCutDoesNotDependOnTheSchemeLookingHierarchical() {
        XCTAssertEqual(URLText.redactURL("about:blank#SECRET"), "about:blank#…")
        XCTAssertEqual(URLText.redactURL("data:text/plain,a?SECRET"), "data:text/plain,a?…")
        XCTAssertEqual(URLText.redactURL("mailto:a@b.example?subject=SECRET"), "mailto:a@b.example?…")
        XCTAssertEqual(URLText.redactURL("file:///tmp/x.html?SECRET"), "file:///tmp/x.html?…")
    }

    /// Whitespace inside a URL is just part of the string: nothing after it survives.
    func testWhitespaceInsideAURLDoesNotHideWhatFollowsIt() {
        XCTAssertEqual(URLText.redactURL("https://a.example/p?sig=\u{00A0}SECRET#PRIVATE"), "https://a.example/p?…")
        XCTAssertEqual(URLText.redactURL("https://a.example/p x?sig= SECRET"), "https://a.example/p x?…")
    }

    /// `String.firstIndex(of: "?")` compares grapheme clusters, so `?` followed by a combining
    /// mark is a different Character and the query behind it would be kept (found in #210).
    func testADelimiterFollowedByACombiningMarkIsStillFound() {
        XCTAssertEqual(URLText.redactURL("https://a.example/p?\u{0301}sig=SECRET"), "https://a.example/p?…")
        XCTAssertEqual(URLText.redactURL("https://a.example/p#\u{0301}SECRET"), "https://a.example/p#…")
    }

    func testCredentialsInTheAuthorityAreReplaced() {
        XCTAssertEqual(URLText.redactURL("https://user:pass@a.example/p"), "https://…@a.example/p")
        XCTAssertEqual(URLText.redactURL("https://user@a.example:8080/p?x=1"), "https://…@a.example:8080/p?…")
        XCTAssertEqual(URLText.redactURL("https://a@b@c.example/p"), "https://…@c.example/p", "the credentials end at the last @ of the authority")
        // An `@` after the authority is path text, and one in the query is gone with the query.
        XCTAssertEqual(URLText.redactURL("https://a.example/users/@me"), "https://a.example/users/@me")
        XCTAssertEqual(URLText.redactURL("https://a.example/p?to=x@y.example"), "https://a.example/p?…")
    }

    func testRedactionIsIdempotent() {
        for url in ["https://a.example/p?sig=SECRET", "https://u:p@a.example/x#f", "about:blank#x", "https://a.example/p"] {
            let once = URLText.redactURL(url)
            XCTAssertEqual(URLText.redactURL(once), once, url)
        }
    }

    // MARK: - Windows Safari could have open: real producers

    private func window(_ index: Int, _ urls: [String], profile: String? = nil) -> SafariBridge.WindowInfo {
        SafariBridge.WindowInfo(
            windowIndex: index, currentTabIndex: 1,
            tabs: urls.enumerated().map { SafariBridge.TabInWindow(tabIndex: $0.offset + 1, url: $0.element, title: "", isCurrent: $0.offset == 0) },
            profile: profile, windowID: 100 + index)
    }

    private var signedWindows: [SafariBridge.WindowInfo] {
        [window(1, ["https://cdn.example.org/a.pdf?X-Signature=\(secret)", "https://cdn.example.org/b.pdf?t=\(secret)#\(secret)"], profile: "Work"),
         window(2, ["https://user:\(secret)@host.example/x", "about:blank#\(secret)"], profile: "Home")]
    }

    /// Every rendering a person or a daemon could print: the payload's own description, the
    /// localized description, and the error's description.
    private func texts(of error: Error) -> [String] {
        [String(describing: error), "\(error)", error.localizedDescription, (error as? LocalizedError)?.errorDescription ?? ""]
    }

    private func assertNoSecret(_ error: Error, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for text in texts(of: error) {
            XCTAssertFalse(text.contains(secret), "\(label): \(text)", file: file, line: line)
            XCTAssertFalse(text.contains("X-Signature"), "\(label): \(text)", file: file, line: line)
        }
    }

    func testEveryProducerInThePureResolverRedactsWhatItListsInThePayloadItself() {
        let windows = signedWindows
        let cases: [(String, SafariBridge.TargetDocument, String?)] = [
            ("url miss", .urlMatch(.contains("nothing-matches-this")), nil),
            ("url ambiguous", .urlMatch(.contains("cdn.example.org")), nil),
            ("window out of range", .windowIndex(9), nil),
            ("window+tab: window out of range", .windowTab(window: 9, tabInWindow: 1), nil),
            ("window+tab: tab out of range", .windowTab(window: 1, tabInWindow: 9), nil),
            ("document out of range", .documentIndex(99), nil),
            ("document below 1", .documentIndex(0), nil),
            ("resolved tab whose window is gone", .resolvedTab(windowID: 999, tabInWindow: 1, rematch: nil, profile: nil), nil),
            ("profile with no window", .frontWindow, "Nobody"),
        ]
        for (label, target, profile) in cases {
            do {
                _ = try SafariBridge.pickNativeTarget(target, in: windows, profile: profile)
                XCTFail("\(label): expected a targeting error")
            } catch {
                guard case SafariBrowserError.documentNotFound = error else {
                    if case SafariBrowserError.ambiguousWindowMatch = error { assertNoSecret(error, label); continue }
                    XCTFail("\(label): unexpected \(error)"); continue
                }
                assertNoSecret(error, label)
                XCTAssertFalse(texts(of: error).joined().contains("user:"), "\(label): userinfo")
            }
        }
    }

    func testDocumentNotFoundKeepsItsLabelsAndTellsWhereToSeeTheFullURLs() throws {
        do {
            _ = try SafariBridge.pickNativeTarget(.urlMatch(.contains("nothing-matches-this")), in: signedWindows)
            XCTFail("expected a miss")
        } catch SafariBrowserError.documentNotFound(let pattern, let listing) {
            XCTAssertEqual(pattern, "nothing-matches-this", "the person's own pattern stays")
            XCTAssertTrue(listing.contains("window 1 tab 1: https://cdn.example.org/a.pdf?…"), "\(listing)")
            XCTAssertTrue(listing.contains("window 1 tab 2: https://cdn.example.org/b.pdf?…"), "\(listing)")
            XCTAssertTrue(listing.contains("window 2 tab 1: https://…@host.example/x"), "\(listing)")
            XCTAssertTrue(listing.contains("window 2 tab 2: about:blank#…"), "\(listing)")
            let text = SafariBrowserError.documentNotFound(pattern: pattern, availableDocuments: listing).errorDescription ?? ""
            XCTAssertTrue(text.contains("`safari-browser documents` prints them in full"), text)
        }
    }

    /// The common reason for an ambiguous match is tabs that differ only in their query. With the
    /// query gone, the tab number is what tells the candidates apart and what
    /// `--window N --tab-in-window M` needs.
    func testAmbiguousCandidatesInOneWindowAreToldApartByTheirTabNumber() throws {
        let windows = [window(1, ["https://cdn.example.org/f.pdf?id=A\(secret)", "https://cdn.example.org/f.pdf?id=B\(secret)"])]
        do {
            _ = try SafariBridge.pickNativeTarget(.urlMatch(.contains("cdn")), in: windows)
            XCTFail("expected ambiguity")
        } catch SafariBrowserError.ambiguousWindowMatch(_, let matches) {
            XCTAssertEqual(matches.map(\.tabIndex), [1, 2])
            XCTAssertEqual(matches.map(\.url), ["https://cdn.example.org/f.pdf?…", "https://cdn.example.org/f.pdf?…"])
            let text = SafariBrowserError.ambiguousWindowMatch(pattern: "cdn", matches: matches).errorDescription ?? ""
            XCTAssertTrue(text.contains("[window 1 tab 1] https://cdn.example.org/f.pdf?…"), text)
            XCTAssertTrue(text.contains("[window 1 tab 2] https://cdn.example.org/f.pdf?…"), text)
            XCTAssertTrue(text.contains("`safari-browser documents` prints them in full"), text)
            XCTAssertTrue(text.contains("--tab-in-window M"), text)
            XCTAssertFalse(text.contains(secret), text)
        }
    }

    func testTheFirstMatchWarningListsCandidatesWithoutTheirQuery() throws {
        var captured: [String] = []
        let tabs = [SafariBridge.TabInWindow(tabIndex: 1, url: "https://cdn.example.org/f.pdf?a=\(secret)", title: "", isCurrent: true),
                    SafariBridge.TabInWindow(tabIndex: 2, url: "https://cdn.example.org/g.pdf?token=\(secret)", title: "", isCurrent: false)]
        let windows = [SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1, tabs: tabs)]
        _ = try SafariBridge.pickFirstMatchFallback(matcher: .contains("cdn"), in: windows, warnWriter: { captured.append($0) })
        XCTAssertEqual(captured.count, 1)
        XCTAssertFalse(captured[0].contains(secret), captured[0])
        XCTAssertTrue(captured[0].contains("window 1 tab 2: https://cdn.example.org/g.pdf?…"), captured[0])
        XCTAssertTrue(captured[0].contains("'cdn'"), "the matcher is the person's own pattern: \(captured[0])")
    }

    func testTheFirstMatchMissListsTabsWithoutTheirQuery() {
        XCTAssertThrowsError(try SafariBridge.pickFirstMatchFallback(matcher: .contains("nothing"), in: signedWindows, warnWriter: nil)) {
            assertNoSecret($0, "first-match miss")
        }
    }

    // MARK: - Notes and the one structured field left

    func testTheNavigationNoteAndTheUploadWordingCarryNoQueryOrFragment() {
        let note = JSCommand.navigationNote(for: "https://app.example/cb?code=\(secret)#access_token=\(secret)")
        XCTAssertFalse(note.contains(secret), note)
        XCTAssertTrue(note.contains("now at https://app.example/cb?…)"), note)
    }

    func testTargetTabChangedRedactsItsURLAtRenderingToo() {
        let text = SafariBrowserError.targetTabChanged(expected: "url contains \"cdn\"", actualURL: "https://cdn.example.org/f.pdf?k=\(secret)").errorDescription ?? ""
        XCTAssertFalse(text.contains(secret), text)
        XCTAssertTrue(text.contains("Target position now shows: https://cdn.example.org/f.pdf?…"), text)
        XCTAssertTrue(text.contains("url contains \"cdn\""), "the expectation is the person's own pattern: \(text)")
        XCTAssertNoThrow(SafariBrowserError.targetTabChanged(expected: "x", actualURL: nil).errorDescription)
    }

    func testURLsWithoutAQueryAreRenderedAsBefore() {
        let text = SafariBrowserError.documentNotFound(
            pattern: "plud", availableDocuments: ["https://web.plaud.ai/", "https://platform.claude.com/oauth/"]).errorDescription ?? ""
        XCTAssertTrue(text.contains("https://web.plaud.ai/") && text.contains("https://platform.claude.com/oauth/"), text)
    }

    /// The other half of the contract: `documents` is what a person runs on purpose to see the URLs,
    /// and it prints them in full. A later refactor that shared the redaction with it would fail here.
    func testDocumentsStillPrintsTheFullURL() {
        let doc = SafariBridge.DocumentInfo(
            index: 1, window: 1, tabInWindow: 1, title: "T", url: "https://cdn.example.org/f.pdf?X-Signature=\(secret)#frag",
            isCurrent: true, profile: nil)
        XCTAssertTrue(DocumentsCommand.formatText([doc]).joined().contains("?X-Signature=\(secret)#frag"))
        let rows = DocumentsCommand.jsonRows([doc], observation: WindowDialogObservation.capture())
        XCTAssertEqual(rows.first?["url"] as? String, "https://cdn.example.org/f.pdf?X-Signature=\(secret)#frag")
    }

    func testTheHintsSayThatEntriesAreShortenedAndWhereTheFullURLsAre() {
        let hint = SafariBrowserError.targetingHint(for: "some-substring")
        XCTAssertTrue(hint.contains("safari-browser documents"), hint)
        XCTAssertTrue(hint.contains("without"), hint)
    }

    // MARK: - Tripwire: a place that builds a tab listing must redact

    /// Not a proof: it fails when someone adds a line that puts a tab URL into a "window …" listing
    /// without going through `URLText`, so the omission has to be a visible decision.
    func testEveryListingLineInTheBridgeGoesThroughTheRedaction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/SafariBrowser/SafariBridge.swift"), encoding: .utf8)
        let upload = try String(contentsOf: root.appendingPathComponent("Sources/SafariBrowser/Commands/UploadCommand.swift"), encoding: .utf8)
        let navigated = try XCTUnwrap(upload.split(separator: "\n").first { $0.contains("Page navigated away during upload") }, "the upload error moved")
        XCTAssertTrue(navigated.contains("URLText.redactURL(initialURL)") && navigated.contains("URLText.redactURL(currentURL)"), String(navigated))
        for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            guard text.contains("\"window "), text.contains(".url)") || text.contains("?.url") else { continue }
            XCTAssertTrue(text.contains("URLText.redactURL"), "SafariBridge.swift:\(number + 1) lists a tab URL without redacting it: \(text)")
        }
    }
}
