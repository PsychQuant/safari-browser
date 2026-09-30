import XCTest
@testable import SafariBrowser

/// #227: the shared targeting errors and the `--first-match` warning list the URLs of open
/// tabs. A query string can be a credential (signed links keep their signature there), so
/// those listings show scheme, host and path, with a marker where something was removed.
final class URLTextTests: XCTestCase {

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

    /// `String.firstIndex(of: "?")` compares grapheme clusters, so `?` followed by a combining
    /// mark is a different Character and the query behind it would be kept (found in #210).
    func testADelimiterFollowedByACombiningMarkIsStillFound() {
        XCTAssertEqual(URLText.redactURL("https://a.example/p?\u{0301}sig=SECRET"), "https://a.example/p?…")
        XCTAssertEqual(URLText.redactURL("https://a.example/p#\u{0301}SECRET"), "https://a.example/p#…")
    }

    // MARK: - Inside a line of text

    func testEveryLabelShapeTheResolversProduceKeepsItsLabelAndLosesTheQuery() {
        let cases: [(String, String)] = [
            ("window 1: https://a.example/p?sig=SECRET (3 tab(s))", "window 1: https://a.example/p?… (3 tab(s))"),
            ("window 2 tab 3: https://b.example/#frag", "window 2 tab 3: https://b.example/#…"),
            ("window 1 [Work]: https://c.example/x?a=1&b=SECRET", "window 1 [Work]: https://c.example/x?…"),
            ("window 2 (Safari window 5): https://d.example/?t=SECRET", "window 2 (Safari window 5): https://d.example/?…"),
            ("https://e.example/only?SECRET", "https://e.example/only?…"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(URLText.redactingURLs(in: input), expected, input)
        }
    }

    func testTextThatIsNotAURLIsLeftAloneExactly() {
        for text in ["window 1: (0 tabs)", "window 3: (unknown)", "why? because #1", "about:blank?x=1",
                     "  double  space\tand\nnewline ", "", "javascript:void(0)?"] {
            XCTAssertEqual(URLText.redactingURLs(in: text), text, text)
        }
    }

    func testWhitespaceBetweenTokensIsPreservedByteForByte() {
        let input = "a  https://x.example/p?SECRET \t b\nhttps://y.example/#f  "
        XCTAssertEqual(URLText.redactingURLs(in: input), "a  https://x.example/p?… \t b\nhttps://y.example/#…  ")
    }

    /// `"…//\u{0301}"` puts the second `/` and the mark in one Character, so a `Character`-level
    /// `contains("://")` would not see the separator and the whole token would be printed.
    func testASchemeSeparatorFollowedByACombiningMarkIsStillRecognised() {
        let input = "https://\u{0301}x.example/p?SECRET"
        XCTAssertFalse(input.contains("://"), "premise: a Character-level search misses it")
        XCTAssertEqual(URLText.redactingURLs(in: input), "https://\u{0301}x.example/p?…")
    }

    // MARK: - The errors

    private let signed = "https://cdn.example.org/f.pdf?X-Signature=SECRETVALUE"

    func testDocumentNotFoundListsOpenTabsWithoutTheirQuery() {
        let error = SafariBrowserError.documentNotFound(
            pattern: "typo",
            availableDocuments: ["window 1: \(signed) (2 tab(s))", "window 2 tab 1: https://plain.example/a"])
        let text = error.errorDescription ?? ""
        XCTAssertFalse(text.contains("SECRETVALUE"), text)
        XCTAssertFalse(text.contains("X-Signature"), text)
        XCTAssertTrue(text.contains("[1] window 1: https://cdn.example.org/f.pdf?… (2 tab(s))"), text)
        XCTAssertTrue(text.contains("https://plain.example/a"), text)
        XCTAssertTrue(text.contains("typo"), "the pattern was typed by the person and stays: \(text)")
    }

    func testAmbiguousWindowMatchListsCandidatesWithoutTheirQuery() {
        let error = SafariBrowserError.ambiguousWindowMatch(
            pattern: "cdn", matches: [(windowIndex: 1, url: signed), (windowIndex: 2, url: signed + "&x=SECRETVALUE")])
        let text = error.errorDescription ?? ""
        XCTAssertFalse(text.contains("SECRETVALUE"), text)
        XCTAssertTrue(text.contains("[window 1] https://cdn.example.org/f.pdf?…"), text)
        XCTAssertTrue(text.contains("[window 2] https://cdn.example.org/f.pdf?…"), text)
    }

    func testTargetTabChangedShowsWhereTheTargetWentWithoutItsQuery() {
        let error = SafariBrowserError.targetTabChanged(expected: "url contains \"cdn\"", actualURL: signed)
        let text = error.errorDescription ?? ""
        XCTAssertFalse(text.contains("SECRETVALUE"), text)
        XCTAssertTrue(text.contains("Target position now shows: https://cdn.example.org/f.pdf?…"), text)
        XCTAssertTrue(text.contains("url contains \"cdn\""), "the expectation is the person's own pattern: \(text)")
        XCTAssertNoThrow(SafariBrowserError.targetTabChanged(expected: "x", actualURL: nil).errorDescription)
    }

    func testURLsWithoutAQueryAreRenderedAsBefore() {
        let text = SafariBrowserError.documentNotFound(
            pattern: "plud", availableDocuments: ["https://web.plaud.ai/", "https://platform.claude.com/oauth/"]).errorDescription ?? ""
        XCTAssertTrue(text.contains("https://web.plaud.ai/") && text.contains("https://platform.claude.com/oauth/"), text)
    }

    // MARK: - The --first-match warning

    func testTheFirstMatchWarningListsCandidatesWithoutTheirQuery() throws {
        var captured: [String] = []
        let tabs = [SafariBridge.TabInWindow(tabIndex: 1, url: signed + "&a=SECRETVALUE", title: "", isCurrent: true),
                    SafariBridge.TabInWindow(tabIndex: 2, url: "https://cdn.example.org/g.pdf?token=SECRETVALUE", title: "", isCurrent: false)]
        let windows = [SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1, tabs: tabs)]
        _ = try SafariBridge.pickFirstMatchFallback(matcher: .contains("cdn"), in: windows, warnWriter: { captured.append($0) })
        XCTAssertEqual(captured.count, 1)
        XCTAssertFalse(captured[0].contains("SECRETVALUE"), captured[0])
        XCTAssertTrue(captured[0].contains("window 1 tab 2: https://cdn.example.org/g.pdf?…"), captured[0])
        XCTAssertTrue(captured[0].contains("'cdn'"), "the matcher is the person's own pattern: \(captured[0])")
    }
}
