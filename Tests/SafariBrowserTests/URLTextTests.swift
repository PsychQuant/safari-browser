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

    /// The outer authority is there only when the text opens with `scheme://`. A `://` further in
    /// belongs to a URL inside the path, and what comes before it is path — parameters included.
    func testPathParametersBeforeAnEmbeddedURLAreReplacedToo() {
        XCTAssertEqual(URLText.redactURL("file:/app;jsessionid=SECRET/https://host.example/x"), "file:/app;…/https://host.example/x")
        XCTAssertEqual(URLText.redactURL("about:blank;jsessionid=SECRET/https://x.example/p"), "about:blank;…/https://x.example/p")
        XCTAssertEqual(URLText.redactURL("https://a.example/app;x=https://u:SECRET@h.example/"), "https://a.example/app;…//…@h.example/",
                       "credentials are removed before parameters are: swapping the order loses the nested authority")
        XCTAssertEqual(URLText.redactURL("https://proxy.example/fetch/https://user;x=1:SECRET@host.example/p"), "https://proxy.example/fetch/https://…@host.example/p")
    }

    /// A URL parser ignores leading C0 controls and spaces, so those do not hide a payload URL.
    func testLeadingWhitespaceDoesNotHideAPayloadScheme() {
        for lead in [" ", "\t", "\n", "\r\n ", "\u{0}"] {
            XCTAssertEqual(URLText.redactURL(lead + "data:text/plain,SECRET"), "data:…", lead.debugDescription)
            XCTAssertEqual(URLText.redactURL(lead + "javascript:alert('SECRET')"), "javascript:…", lead.debugDescription)
        }
        XCTAssertEqual(URLText.redactURL(" https://a.example/p?x=1"), " https://a.example/p?…", "an ordinary URL keeps what it had")
    }

    /// A URL parser removes ASCII tab, LF and CR from anywhere in the input, so a scheme broken up
    /// by them is still `data:` or `javascript:` — and the payload is not an address.
    func testControlsInsideASchemeDoNotHideAPayloadScheme() {
        for scheme in ["da\tta", "d\na\rta", "java\nscript", "ja\tva\tscript", "DA\tTA"] {
            let shown = URLText.redactURL(scheme + ":text/plain,SECRETVALUE")
            XCTAssertFalse(shown.contains("SECRETVALUE"), "\(scheme.debugDescription) → \(shown.debugDescription)")
            XCTAssertTrue(shown.hasSuffix(":…"), shown)
        }
        // The controls a parser removes are not shown, and an ordinary URL is otherwise as before.
        XCTAssertEqual(URLText.redactURL("ht\ntps://a.example/p?x=1"), "https://a.example/p?…")
        // Only a real scheme makes a payload: a space inside, or a digit first, is not one.
        XCTAssertEqual(URLText.redactURL("da ta:x,VISIBLE"), "da ta:x,VISIBLE")
        XCTAssertEqual(URLText.redactURL("1data:x,VISIBLE"), "1data:x,VISIBLE")
        // Through the type that goes into `targetTabChanged`, and through what the error prints.
        let error = SafariBrowserError.targetTabChanged(expected: "x", actualURL: RedactedURL("da\tta:text/plain,SECRETVALUE"))
        XCTAssertFalse("\(error)".contains("SECRETVALUE"), "\(error)")
        XCTAssertFalse((error.errorDescription ?? "").contains("SECRETVALUE"), error.errorDescription ?? "")
    }

    /// A URL parser reads a backslash as a slash and skips extra ones after a scheme, so the
    /// authority of a URL inside a path can start after more than two of them. Where the readings
    /// differ the text takes the one that removes more.
    func testCredentialsAfterExtraSlashesOrBackslashesAreReplaced() {
        for separator in ["////", "///", "\\\\", "/\\", "\\/", "//\\/"] {
            let shown = URLText.redactURL("https://proxy.example/fetch/https:\(separator)user:SECRETVALUE@host.example/x")
            XCTAssertFalse(shown.contains("SECRETVALUE"), "\(separator) → \(shown)")
            XCTAssertTrue(shown.contains("…@host.example/x"), shown)
        }
        XCTAssertEqual(URLText.redactURL("https:////user:SECRETVALUE@host.example/x"), "https:////…@host.example/x")
        XCTAssertEqual(URLText.redactURL("https://a.example\\p;jsessionid=SECRET/x"), "https://a.example\\p;…/x",
                       "a backslash ends the authority for path parameters: the text after it is path")
        // A backslash inside the credentials does not end the authority for them: the longer reading removes more.
        XCTAssertFalse(URLText.redactURL("https://user\\name:SECRETVALUE@host.example/x").contains("SECRETVALUE"))
        // One slash, or none, is not recognised as an authority; the doc comment of `redactURL` says so.
        XCTAssertEqual(URLText.redactURL("https://proxy.example/https:/host.example/x"), "https://proxy.example/https:/host.example/x")
    }

    /// The same controls next to the authority separator: a parser removes them first, so these are
    /// `https://user:pw@host/` and the credentials go.
    func testControlsNextToTheAuthoritySeparatorDoNotHideCredentials() {
        for input in ["https:\t//user:SECRETVALUE@host.example/x", "https:/\n/user:SECRETVALUE@host.example/x",
                      "https:\r\n//user:SECRETVALUE@host.example/x", "https:/\t/user:SECRETVALUE@host.example/x",
                      "https://proxy.example/fetch/https:/\t/user:SECRETVALUE@host.example/x"] {
            let shown = URLText.redactURL(input)
            XCTAssertFalse(shown.contains("SECRETVALUE"), "\(input.debugDescription) → \(shown.debugDescription)")
            XCTAssertTrue(shown.contains("…@host.example/x"), shown)
        }
    }

    /// With three or more slashes the path parameters of the first segment are still removed: the
    /// authority whose parameters are removed starts after exactly two slashes (round 4 took the
    /// whole run of slashes for it, and `file:///app;jsessionid=…` kept its session).
    func testPathParametersAfterThreeOrMoreSlashesAreReplaced() {
        XCTAssertEqual(URLText.redactURL("file:///app;jsessionid=SECRET/x"), "file:///app;…/x")
        XCTAssertEqual(URLText.redactURL("x:///y;SECRET/z"), "x:///y;…/z")
        XCTAssertEqual(URLText.redactURL("x:////a;SECRET/b"), "x:////a;…/b")
        XCTAssertEqual(URLText.redactURL("https:///a.example;jsessionid=SECRET/x"), "https:///a.example;…/x")
    }

    /// What ordinary URLs look like through the redaction: unchanged. The one documented exception is
    /// an `@` in the first path segment of a `file:///` URL, which reads as credentials.
    func testOrdinaryURLsAreRenderedAsBefore() {
        for url in ["https://a.example/p", "file:///Users/x/a.pdf", "file:///C:/Users/x/a.pdf", "file:///Volumes/A@B/x", "http://[::1]:8080/p",
                    "chrome-extension://id/page", "x-apple:///y", "https://medium.com/@user/post",
                    "https://web.archive.org/web/2020/https://example.com/", "about:blank"] {
            XCTAssertEqual(URLText.redactURL(url), url)
        }
        XCTAssertEqual(URLText.redactURL("file:///a@b.pdf"), "file:///…@b.pdf", "the over-redaction that is accepted: a file directly in / whose name has an @")
    }

    /// Linear, including for texts made of many authorities with no `/` between them, which a search
    /// for each authority's end turned quadratic. 250 000 scalars took minutes that way.
    func testRedactionIsLinearOnManyAuthoritiesWithoutASlash() {
        let inputs = ["https://h/" + String(repeating: "x:\\\\h", count: 40_000),
                      "https://h/" + String(repeating: "x:////h@", count: 30_000),
                      "https://h/" + String(repeating: ":\\\\", count: 60_000)]
        let start = Date()
        for input in inputs { _ = URLText.redactURL(input) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "three inputs of about 250 000 scalars")
    }

    /// Only a real scheme opens the text with an authority whose parameters are left alone: for text
    /// that does not open with one, every `;` in it starts a parameter that is removed.
    func testOnlyARealSchemeHasAnAuthorityForPathParameters() {
        XCTAssertEqual(URLText.redactURL("ab://h;x/p;y"), "ab://h;x/p;…")
        XCTAssertEqual(URLText.redactURL("1a://h;x/p;y"), "1a://h;…/p;…", "a digit cannot start a scheme")
        XCTAssertEqual(URLText.redactURL("a b://h;x/p;y"), "a b://h;…/p;…", "a space is not a scheme character")
    }

    /// The documented limit, pinned where it matters: an embedded URL with one slash after its
    /// scheme is not recognised as having an authority, so its credentials are shown.
    func testAnEmbeddedURLWithOneSlashKeepsItsCredentialsAsDocumented() {
        let input = "https://proxy.example/fetch/https:/user:SECRETVALUE@host.example/x"
        XCTAssertEqual(URLText.redactURL(input), input)
    }

    /// The cap, by its number and not by the constant the code holds: 200 shown at most, 199 of
    /// the text and the `…` that says something was cut.
    func testTheCapIsTwoHundredScalars() {
        XCTAssertEqual(URLText.maxLength, 200)
        let base = "https://a.example/"
        let atTwoHundred = base + String(repeating: "p", count: 200 - base.count)
        XCTAssertEqual(URLText.redactURL(atTwoHundred), atTwoHundred, "exactly 200 is shown whole")
        let cut = URLText.redactURL(atTwoHundred + "p")
        XCTAssertEqual(cut.unicodeScalars.count, 200)
        XCTAssertEqual(String(cut.unicodeScalars.dropLast()), String(atTwoHundred.unicodeScalars.prefix(199)))
        XCTAssertTrue(cut.hasSuffix("…"))
    }

    /// The redaction is a fixed point. The two ways it used to fail: the cap cut right after a
    /// `;…` marker, and the cap dropped the `://` the parameter step had used to find the authority.
    func testRedactionIsAFixedPointOnTheKnownCounterexamples() {
        let inputs = [
            "https://a.example/" + String(repeating: "p", count: 179) + ";jsessionid=SECRET/x",
            "https://a.example/" + String(repeating: "k", count: 179) + ";x=1/next",
            "file:/app;jsessionid=SECRET/" + String(repeating: "x", count: 220) + "/https://host/x",
            "about:a@b.example;…/a;b=SECRET/x://h/",
        ]
        for input in inputs {
            let once = URLText.redactURL(input)
            XCTAssertEqual(URLText.redactURL(once), once, input)
            XCTAssertFalse(once.contains("SECRET"), once)
        }
    }

    /// A seeded sweep over URL-shaped and random strings, most of them near the cap. It checks the
    /// result is stable, not that the repeat loop is needed: on this generator a second pass almost
    /// never changes anything, and the counterexamples above are what pin the loop.
    func testRedactionIsAFixedPointOverASeededSweep() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let alphabet = Array("htps:/\\@;?#=…ab1 .-\u{0301}\t\n")
        let heads = ["https://a.example/", "file:/", "about:blank", "https://u:p@h.example/x", "data:x", "", "https://p.example/https://q:r@s.example/"]
        for _ in 0..<6000 {
            var text = heads[next(heads.count)]
            let length = next(4) == 0 ? next(60) : 150 + next(90)
            for _ in 0..<length { text.unicodeScalars.append(alphabet[next(alphabet.count)].unicodeScalars.first!) }
            let once = URLText.redactURL(text)
            if URLText.redactURL(once) != once {
                return XCTFail("not a fixed point: \(text.debugDescription) -> \(once.debugDescription) -> \(URLText.redactURL(once).debugDescription)")
            }
        }
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
        XCTAssertTrue(captured[0].contains(URLText.shortenedNote), "two entries that differ only in a hidden query must not read as a repeated line: \(captured[0])")
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

    /// The upload's navigation check, driven for real: a fake page whose URL changes after the
    /// first read, and a file large enough (11 chunks) for the check that runs every 10 chunks.
    /// What reaches the person is the error built from the redacted URLs.
    func testTheUploadNavigationBranchReportsRedactedURLs() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("upload-nav-\(UUID().uuidString).bin").path
        try Data(repeating: 0x41, count: 1_650_000).write(to: URL(fileURLWithPath: file))
        defer { try? FileManager.default.removeItem(atPath: file) }
        final class Reads: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func next() -> Int { lock.withLock { n += 1; return n } }
        }
        let reads = Reads()
        let secret = self.secret
        let runner: @Sendable (String) async throws -> String = { script in
            guard script.contains("location.href.split") else { return "" }
            return reads.next() == 1 ? "https://app.example/a?token=A\(secret)" : "https://app.example/b?token=B\(secret)"
        }
        var command = try UploadCommand.parse(["input", file, "--js"])
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        do {
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue(runner) { try await command.run() }
            }
            XCTFail("the page navigated: the upload must abort")
        } catch {
            assertNoSecret(error, "upload navigated away")
            XCTAssertTrue("\(error)".contains("was: https://app.example/a?…, now: https://app.example/b?…"), "\(error)")
        }
    }

    /// `targetTabChanged` carries its URL as a `RedactedURL`, which redacts what it is built from:
    /// a raw string cannot get into the payload, so what `"\(error)"` (a daemon's wire error and log
    /// line) prints and what `errorDescription` prints are both redacted. No producer in Sources
    /// passes a URL yet (all three pass `nil`); this is the guarantee for the first one that does.
    func testTargetTabChangedCannotCarryAnUnredactedURL() {
        let error = SafariBrowserError.targetTabChanged(
            expected: "url contains \"cdn\"", actualURL: RedactedURL("https://cdn.example.org/f.pdf?k=\(secret)#\(secret)"))
        assertNoSecret(error, "targetTabChanged")
        let text = error.errorDescription ?? ""
        XCTAssertTrue(text.contains("Target position now shows: https://cdn.example.org/f.pdf?…"), text)
        XCTAssertTrue(text.contains("url contains \"cdn\""), "the expectation is the person's own pattern: \(text)")
        XCTAssertEqual(RedactedURL("https://a.example/p?x=1").text, "https://a.example/p?…")
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
                XCTAssertTrue(text.contains("URLs are shown shortened"), "\(label): \(text)")
            }
        }
        // Nothing listed, nothing shortened.
        let empty = SafariBrowserError.documentNotFound(pattern: "x", availableDocuments: []).errorDescription ?? ""
        XCTAssertFalse(empty.contains("URLs are shown shortened"), empty)
    }

    func testURLsWithoutAQueryAreRenderedAsBefore() {
        let text = SafariBrowserError.documentNotFound(
            pattern: "plud", availableDocuments: ["https://web.plaud.ai/", "https://platform.claude.com/oauth/"]).errorDescription ?? ""
        XCTAssertTrue(text.contains("https://web.plaud.ai/") && text.contains("https://platform.claude.com/oauth/"), text)
        for url in ["https://web.plaud.ai/", "https://platform.claude.com/oauth/"] { XCTAssertEqual(URLText.redactURL(url), url) }
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
        let flat = hint.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("copy only what precedes its first marker"), hint)
        XCTAssertTrue(flat.contains("if any are listed"), "an empty listing has no URLs: \(hint)")
    }

    /// What the hint tells a person to do, for each kind of marker: the text before the FIRST `…` of
    /// an entry is verbatim from the URL it stands for, so it is a prefix of it (and can be short:
    /// before `…@` it is only `https://`), while the whole entry is not a substring of any URL, and
    /// matches neither exactly nor by suffix.
    func testTheAdviceOnAMarkedEntryHoldsForEveryKindOfMarker() {
        let raws = ["https://a.example/p?sig=SECRET&x=1", "https://a.example/p#token=SECRET", "https://u:pw@h.example/cb?code=1",
                    "https://a.example/app;jsessionid=S/next?x=1", "https://a.example/" + String(repeating: "p", count: 300) + "?q=1"]
        for raw in raws {
            let entry = URLText.redactURL(raw)
            let beforeTheFirstMarker = String(entry.split(separator: "…", maxSplits: 1, omittingEmptySubsequences: false)[0])
            XCTAssertTrue(raw.hasPrefix(beforeTheFirstMarker), "\(beforeTheFirstMarker) must be a prefix of \(raw)")
            XCTAssertTrue(SafariBridge.UrlMatcher.contains(beforeTheFirstMarker).matches(raw))
            XCTAssertFalse(SafariBridge.UrlMatcher.contains(entry).matches(raw), "the whole entry is not part of the URL: \(entry)")
            XCTAssertFalse(SafariBridge.UrlMatcher.exact(entry).matches(raw))
            XCTAssertFalse(SafariBridge.UrlMatcher.endsWith(entry).matches(raw))
        }
    }

    /// A listing can be scoped to one window, and `--document N` numbers the tabs as `documents`
    /// does, so the hints do not promise that `[N]` is a document number.
    func testTheHintsDoNotPromiseThatTheListedNumberIsADocumentNumber() {
        for pattern in ["some-substring", "window 9", "document 9"] {
            let flat = SafariBrowserError.targetingHint(for: pattern).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            XCTAssertFalse(flat.contains("for the [N] index"), "\(pattern): \(flat)")
            XCTAssertTrue(flat.contains("can differ from the [N] shown above"), "\(pattern): \(flat)")
        }
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
        let interpolatedURL = try NSRegularExpression(pattern: #"\\\(.*\.url\b"#)
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
        let counts = [("SafariBridge.swift", 11), ("Commands/JSCommand.swift", 1), ("Commands/UploadCommand.swift", 2), ("Utilities/Errors.swift", 1)]
        for (file, expected) in counts {
            let found = try source(file).components(separatedBy: "URLText.redactURL(").count - 1
            XCTAssertEqual(found, expected, "\(file): a redaction site was added or removed — decide it, then update this count")
        }
    }

    // The `targetTabChanged` payload needs no tripwire: its URL is a `RedactedURL`, which has no
    // string-literal conversion, so a producer cannot pass a raw string (it does not compile).
}
