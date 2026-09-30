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

    /// A `data:` or `javascript:` URL is a payload, not an address: what follows the colon is all
    /// content, and it can be unbounded and secret whether or not it has a `?` in it.
    func testPayloadSchemesShowNothingAfterTheColon() {
        XCTAssertEqual(URLText.redactURL("data:text/plain,a?SECRET"), "data:…")
        XCTAssertEqual(URLText.redactURL("data:text/html;base64,U0VDUkVU"), "data:…")
        XCTAssertEqual(URLText.redactURL("javascript:fetch('/x?t=SECRET')"), "javascript:…")
        XCTAssertEqual(URLText.redactURL("DATA:text/plain,SECRET"), "DATA:…", "scheme names are case-insensitive")
        // Only these two: any other scheme is an address and keeps its path.
        XCTAssertEqual(URLText.redactURL("blob:https://a.example/0b6c-1"), "blob:https://a.example/0b6c-1")
        XCTAssertEqual(URLText.redactURL("view-source:https://a.example/p?x=1"), "view-source:https://a.example/p?…")
        // A path that merely starts with the word is not a scheme.
        XCTAssertEqual(URLText.redactURL("https://a.example/data:x"), "https://a.example/data:x")
        XCTAssertEqual(URLText.redactURL("data"), "data")
    }

    /// `;jsessionid=…` and similar path parameters are recognisable and often a session credential.
    func testPathParametersAreReplacedUpToTheNextSlash() {
        XCTAssertEqual(URLText.redactURL("https://a.example/app/page;jsessionid=SECRET"), "https://a.example/app/page;…")
        XCTAssertEqual(URLText.redactURL("https://a.example/app;jsessionid=SECRET/next?x=1"), "https://a.example/app;…/next?…")
        XCTAssertEqual(URLText.redactURL("https://a.example/a;x=1/b;y=2"), "https://a.example/a;…/b;…")
        XCTAssertEqual(URLText.redactURL("https://a.example/p"), "https://a.example/p")
    }

    /// A URL inside the path (a proxy, a redirect target) is an authority of its own.
    func testCredentialsOfAURLInsideThePathAreReplacedToo() {
        XCTAssertEqual(URLText.redactURL("https://proxy.example/fetch/https://user:SECRET@host.example/x"), "https://proxy.example/fetch/https://…@host.example/x")
        XCTAssertEqual(URLText.redactURL("https://u:SECRET@proxy.example/https://v:SECRET@host.example/"), "https://…@proxy.example/https://…@host.example/")
        XCTAssertEqual(URLText.redactURL("https://a.example/redirect/https://b.example/users/@me"), "https://a.example/redirect/https://b.example/users/@me")
    }

    func testALongURLIsCutAtTheCapAndNeverGrows() {
        let long = "https://a.example/" + String(repeating: "p", count: 500)
        let shown = URLText.redactURL(long)
        XCTAssertEqual(shown.unicodeScalars.count, URLText.maxLength)
        XCTAssertTrue(shown.hasPrefix("https://a.example/ppp") && shown.hasSuffix("…"), shown)
        // The marker comes after the cut body and is not counted in the cap.
        let withQuery = URLText.redactURL(long + "?sig=SECRET")
        XCTAssertEqual(withQuery, shown + "?…")
        let atTheCap = "https://a.example/" + String(repeating: "p", count: URLText.maxLength - "https://a.example/".count)
        XCTAssertEqual(URLText.redactURL(atTheCap), atTheCap, "a URL of exactly the cap is shown whole")
    }

    func testRedactionIsIdempotent() {
        let long = "https://a.example/" + String(repeating: "p", count: 500)
        for url in ["https://a.example/p?sig=SECRET", "https://u:p@a.example/x#f", "about:blank#x", "https://a.example/p",
                    "data:text/plain,a?SECRET", "DATA:x", "javascript:alert(1)", "https://a.example/a;x=1/b;y=2?z",
                    "https://proxy.example/https://u:p@h.example/x;s=1", long, long + "?q=1", long + ";x=1/y#f",
                    "https://a.example/p?\u{0301}sig=SECRET", ""] {
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

    func testTheNavigationNoteCarriesNoQueryOrFragment() {
        let note = JSCommand.navigationNote(for: "https://app.example/cb?code=\(secret)#access_token=\(secret)")
        XCTAssertFalse(note.contains(secret), note)
        XCTAssertTrue(note.contains("now at https://app.example/cb?…)"), note)
    }

    /// The upload error is built from two page URLs that were already stripped of their fragment,
    /// so what differs between them is usually the query, which is not shown.
    func testTheUploadNavigatedAwayErrorCarriesNoQueryAndSaysWhenTheTwoLookAlike() {
        let moved = UploadCommand.navigatedAwayMessage(
            initialURL: "https://app.example/a?token=\(secret)", currentURL: "https://app.example/b?token=\(secret)")
        XCTAssertFalse(moved.contains(secret), moved)
        XCTAssertTrue(moved.contains("was: https://app.example/a?…, now: https://app.example/b?…)"), moved)
        XCTAssertFalse(moved.contains("not shown"), "the two differ visibly, so there is nothing to explain: \(moved)")

        let sameLooking = UploadCommand.navigatedAwayMessage(
            initialURL: "https://app.example/a?token=A\(secret)", currentURL: "https://app.example/a?token=B\(secret)")
        XCTAssertFalse(sameLooking.contains(secret), sameLooking)
        XCTAssertTrue(sameLooking.contains("was: https://app.example/a?…, now: https://app.example/a?…"), sameLooking)
        XCTAssertTrue(sameLooking.contains("they differ in a part that is not shown here"), sameLooking)
        XCTAssertTrue(sameLooking.hasSuffix("Upload aborted."), sameLooking)
    }

    func testTargetTabChangedRedactsItsURLAtRenderingToo() {
        let text = SafariBrowserError.targetTabChanged(expected: "url contains \"cdn\"", actualURL: "https://cdn.example.org/f.pdf?k=\(secret)").errorDescription ?? ""
        XCTAssertFalse(text.contains(secret), text)
        XCTAssertTrue(text.contains("Target position now shows: https://cdn.example.org/f.pdf?…"), text)
        XCTAssertTrue(text.contains("url contains \"cdn\""), "the expectation is the person's own pattern: \(text)")
        XCTAssertNoThrow(SafariBrowserError.targetTabChanged(expected: "x", actualURL: nil).errorDescription)
    }

    /// The `-1719` / `-1728` translation in `runTargetedAppleScript` is its own producer of the
    /// listing, reached only when Safari itself reports the target missing.
    func testTheTranslatedAppleScriptFailureListsTabsWithoutTheirQuery() async {
        let record = ["1", "1", "1", "https://cdn.example.org/a.pdf?X-Signature=\(secret)", "T", "", "71"].joined(separator: "\u{1D}") + "\u{1E}"
        // A context with a probe that answers, so the dialog gate does not scan the real Safari.
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        do {
            _ = try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                    if source.contains("get URL of") { throw SafariBrowserError.appleScriptFailed("Safari got an error: Can't get window 7. (-1728)") }
                    return record
                }) { try await SafariBridge.getCurrentURL(target: .windowIndex(7)) }
            }
            XCTFail("expected the translated miss")
        } catch SafariBrowserError.documentNotFound(_, let listing) {
            XCTAssertEqual(listing, ["window 1 tab 1: https://cdn.example.org/a.pdf?…"])
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// The note that URLs are shortened is on every listing, including a positional miss, whose
    /// listing is the one a person is most likely to act on by copying a URL.
    func testEveryNotFoundListingSaysThatURLsAreShownShortened() throws {
        for (label, target) in [("url miss", SafariBridge.TargetDocument.urlMatch(.contains("nothing"))),
                                ("window miss", .windowIndex(9)), ("window+tab miss", .windowTab(window: 1, tabInWindow: 9))] {
            do {
                _ = try SafariBridge.pickNativeTarget(target, in: signedWindows)
                XCTFail("\(label): expected a miss")
            } catch SafariBrowserError.documentNotFound(let pattern, let listing) {
                let text = SafariBrowserError.documentNotFound(pattern: pattern, availableDocuments: listing).errorDescription ?? ""
                XCTAssertTrue(text.contains("URLs are shown without their query or fragment"), "\(label): \(text)")
            }
        }
        // Nothing listed, nothing shortened.
        let empty = SafariBrowserError.documentNotFound(pattern: "x", availableDocuments: []).errorDescription ?? ""
        XCTAssertFalse(empty.contains("URLs are shown without"), empty)
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
        // Not `capture()`: that scans the developer's real Safari through Accessibility.
        let rows = DocumentsCommand.jsonRows([doc], observation: WindowDialogObservation.unavailable(reason: "test"))
        XCTAssertEqual(rows.first?["url"] as? String, "https://cdn.example.org/f.pdf?X-Signature=\(secret)#frag")
    }

    func testTheHintsSayThatEntriesAreShortenedAndWhereTheFullURLsAre() {
        let hint = SafariBrowserError.targetingHint(for: "some-substring")
        XCTAssertTrue(hint.contains("safari-browser documents"), hint)
        XCTAssertTrue(hint.contains("without"), hint)
        // A copied entry with its marker fails every URL matcher, not only --url-exact.
        let flat = hint.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("`?…` or `#…` marker matches none of --url, --url-exact or --url-endswith"), hint)
    }

    /// `--window N` counts the windows of the `--profile` when there is one, while the listings
    /// show Safari's own window numbers, so "the numbers listed" is only true without it.
    func testTheNumbersToRetargetWithAreNotPromisedUnderAProfile() {
        func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
        let ambiguous = SafariBrowserError.ambiguousWindowMatch(pattern: "cdn", matches: [(windowIndex: 3, tabIndex: 1, url: "https://a.example/")]).errorDescription ?? ""
        XCTAssertTrue(flat(ambiguous).contains("with --profile, n counts only that profile's windows"), ambiguous)
        for pattern in ["some-substring", "window 9"] {
            let hint = SafariBrowserError.targetingHint(for: pattern)
            XCTAssertTrue(flat(hint).contains("with --profile, n counts only that profile's windows"), "\(pattern): \(hint)")
        }
    }

    // MARK: - Tripwires: a place that shows a tab URL must redact

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SafariBrowser")
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: sourcesRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Not a proof: it fails when someone interpolates a tab's `.url` into text in one of the
    /// files that build these errors, warnings and notes without going through `URLText`, so the
    /// omission has to be a visible decision. Comment lines are skipped.
    func testEveryInterpolationOfATabURLInTheErrorBuildingFilesGoesThroughTheRedaction() throws {
        let interpolatedURL = try NSRegularExpression(pattern: #"\\\([^)]*\.url\b"#)
        for file in ["SafariBridge.swift", "Commands/JSCommand.swift", "Commands/UploadCommand.swift", "Utilities/Errors.swift"] {
            for (number, line) in try source(file).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(text.startIndex..., in: text)
                guard interpolatedURL.firstMatch(in: text, range: range) != nil else { continue }
                XCTAssertTrue(text.contains("URLText.redactURL"), "\(file):\(number + 1) interpolates a tab URL without redacting it: \(text)")
            }
        }
    }

    /// The count is the number of places that show a tab URL, so removing one is a failure too.
    func testTheNumberOfRedactionSitesIsWhatWasReviewed() throws {
        let counts = [("SafariBridge.swift", 11), ("Commands/JSCommand.swift", 1), ("Commands/UploadCommand.swift", 2), ("Utilities/Errors.swift", 2)]
        for (file, expected) in counts {
            let found = try source(file).components(separatedBy: "URLText.redactURL(").count - 1
            XCTAssertEqual(found, expected, "\(file): a redaction site was added or removed — decide it, then update this count")
        }
    }

    /// `targetTabChanged` carries a URL in its payload, and a daemon prints the payload. Every
    /// producer passes none today; one that passes one must redact it where it builds it.
    func testEveryTargetTabChangedProducerPassesNoURLOrARedactedOne() throws {
        let producer = try NSRegularExpression(pattern: #"SafariBrowserError\.targetTabChanged\(\s*expected:[^,]+,\s*actualURL:\s*([^\s)]+)"#)
        var found = 0
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in producer.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                found += 1
                let argument = String(text[try XCTUnwrap(Range(match.range(at: 1), in: text))])
                XCTAssertTrue(argument == "nil" || argument.hasPrefix("URLText.redactURL"), "\(file.lastPathComponent): actualURL: \(argument)")
            }
        }
        XCTAssertGreaterThanOrEqual(found, 3, "the scan found no producers — the pattern no longer matches the code")
    }
}
