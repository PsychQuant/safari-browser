import XCTest
@testable import SafariBrowser

/// #355: page text cannot forge enumeration rows. An AppleScript literal shaped like the
/// enumeration's result carries the forgeries measured on a real Safari and the five of the
/// Diagnosis (A–E) in its titles and window names; it travels through both execution paths
/// (`osascript -s s`, and `NSAppleScript` + `AppleScriptSourceForm.render`) and is decoded.
/// No Safari is involved: the script returns literals.
final class WindowEnumerationTransportTests: XCTestCase {

    private typealias Tab = SafariBridge.TabInWindow
    private typealias Window = SafariBridge.WindowInfo

    private static let gs = "\u{1D}", rs = "\u{1E}"

    /// One record of the pre-#355 wire format, as a page would forge it.
    private static func oldRecord(_ fields: [String]) -> String { fields.joined(separator: gs) + rs }

    /// The title measured on a real Safari (issue comment, 2026-11-09): a real-looking title, then a
    /// record for tab 99 of window 1 with a URL on another host.
    private static let measured = "Fixture" + rs + oldRecord(["1", "99", "1", "https://evil.example/x", "Forged", "個人 — Forged", "4711"])

    private static let titles: [String] = [
        measured,
        // A: a background tab's title, forged record for an existing position.
        "a" + rs + oldRecord(["1", "2", "1", "https://evil.example/a", "T"]),
        // B: a forged record for a later window with its own name and id.
        "b" + rs + oldRecord(["2", "1", "1", "https://evil.example/b", "T", "Forged — T", "999"]),
        // D: GS only, a forged name and id in fields 6–7.
        "X" + gs + "Forged — T" + gs + "999",
        // E: a record that continues the last window's numbering with its real name and id.
        "e" + rs + oldRecord(["2", "3", "0", "https://evil.example/e", "T", "仕事 — Last", "5"]),
        "quotes \" and \\ and \"\u{0301} \r\n end",
        "\u{1C}\u{1D}\u{1E}\u{1F}\u{0}",
    ]

    /// C: the window name, which carries the current tab's title.
    private static let windowName1 = "個人 — " + measured

    private func script() -> String {
        let u = AppleScriptSourceFormRenderTests.utxt
        let t = Self.titles.map { u(Array($0.utf16)) }
        let urls1 = ["https://a.example/1", "https://a.example/2\"\(Self.rs)", "https://a.example/3"].map { u(Array($0.utf16)) }
        let urls2 = ["https://b.example/1", "https://b.example/2", "https://b.example/3", "https://b.example/4"].map { u(Array($0.utf16)) }
        return """
            return {{1, 4711, \(u(Array(Self.windowName1.utf16))), 1, {\(urls1.joined(separator: ", "))}, {\(t[0]), \(t[1]), \(t[2])}}, \
            {2, 5, \(u(Array("仕事 — Last".utf16))), 4, {\(urls2.joined(separator: ", "))}, {\(t[3]), \(t[5]), \(t[6]), \(t[4])}}, \
            {3, missing value, \(u(Array(("Forged — " + Self.measured).utf16))), 0, {}, {}}}
            """
    }

    private var expected: [Window] {
        let t = Self.titles
        return [
            Window(windowIndex: 1, currentTabIndex: 1, tabs: [
                Tab(tabIndex: 1, url: "https://a.example/1", title: t[0], isCurrent: true),
                Tab(tabIndex: 2, url: "https://a.example/2\"\(Self.rs)", title: t[1], isCurrent: false),
                Tab(tabIndex: 3, url: "https://a.example/3", title: t[2], isCurrent: false),
            ], profile: "個人", windowID: 4711),
            Window(windowIndex: 2, currentTabIndex: 4, tabs: [
                Tab(tabIndex: 1, url: "https://b.example/1", title: t[3], isCurrent: false),
                Tab(tabIndex: 2, url: "https://b.example/2", title: t[5], isCurrent: false),
                Tab(tabIndex: 3, url: "https://b.example/3", title: t[6], isCurrent: false),
                Tab(tabIndex: 4, url: "https://b.example/4", title: t[4], isCurrent: true),
            ], profile: "仕事", windowID: 5),
            Window(windowIndex: 3, currentTabIndex: 1, tabs: [], profile: "Forged", windowID: nil),
        ]
    }

    func testForgedTitlesAndWindowNamesProduceNoRowsOnTheStatelessPath() throws {
        let text = try AppleScriptSourceFormRenderTests.osascriptSourceForm(script())
        XCTAssertEqual(try SafariBridge.decodeWindowEnumeration(text), expected)
    }

    func testForgedTitlesAndWindowNamesProduceNoRowsOnTheDaemonPath() throws {
        let text = try AppleScriptSourceFormRenderTests.renderedSourceForm(script())
        XCTAssertEqual(try SafariBridge.decodeWindowEnumeration(text), expected)
    }

    func testBothPathsProduceTheSameText() throws {
        XCTAssertEqual(
            Array(try AppleScriptSourceFormRenderTests.renderedSourceForm(script()).utf8),
            Array(try AppleScriptSourceFormRenderTests.osascriptSourceForm(script()).utf8))
    }

    /// Long titles cost time linear in their length. 2^20 characters of the worst case for escaping
    /// (`"` and `\` alternating) and of combining marks (the case that made fac190c's handler take
    /// 9–11 s at 65,536 marks). The bound is loose on purpose: it guards against a quadratic return,
    /// not a slow machine.
    func testLongTitlesDecodeInLinearTime() throws {
        for unit in [#""\"\\""#, "(character id 769)"] {
            let script = """
                set s to \(unit)
                repeat 19 times
                set s to s & s
                end repeat
                return {{1, 7, "x — " & s, 1, {"https://a/"}, {s}}}
                """
            let start = Date()
            let stateless = try AppleScriptSourceFormRenderTests.osascriptSourceForm(script)
            let daemon = try AppleScriptSourceFormRenderTests.renderedSourceForm(script)
            let windows = try SafariBridge.decodeWindowEnumeration(stateless)
            XCTAssertEqual(try SafariBridge.decodeWindowEnumeration(daemon), windows)
            XCTAssertEqual(windows.first?.tabs.count, 1)
            XCTAssertLessThan(Date().timeIntervalSince(start), 20, "unit \(unit)")
        }
    }

    // MARK: - A title cut inside a surrogate pair (real Safari, issue comment 6743483662)

    /// Safari cuts `name of tab` at 1000 UTF-16 units without regard to surrogate pairs, so
    /// `"a" × 999 + 😀` arrives as 999 `a` and an unpaired U+D83D; the window name carries the same
    /// cut title. On v2.9.0 that tab vanished, and every record of its window lost the window id,
    /// because osascript cut the whole joined text at the unpaired unit. AppleScript cannot build the
    /// unit with `character id`, so the script makes it from `«data utxt…»`.
    private static let cutTitle: [UInt16] = Array(repeating: 0x61, count: 999) + [0xD83D]

    private func cutTitleScript() -> String {
        let u = AppleScriptSourceFormRenderTests.utxt
        return """
            return {{1, 4711, \(u(Array("個人 — ".utf16) + Self.cutTitle)), 2, \
            {"https://other.test/", "https://fixture.test/page"}, {"Other", \(u(Self.cutTitle))}}}
            """
    }

    func testATitleCutInsideASurrogatePairKeepsItsTabAndItsWindowID() async throws {
        let expectedTitle = String(repeating: "a", count: 999)
        for (path, text) in [("stateless", try AppleScriptSourceFormRenderTests.osascriptSourceForm(cutTitleScript())),
                             ("daemon", try AppleScriptSourceFormRenderTests.renderedSourceForm(cutTitleScript()))] {
            let windows = try SafariBridge.decodeWindowEnumeration(text)
            XCTAssertEqual(windows, [Window(windowIndex: 1, currentTabIndex: 2, tabs: [
                Tab(tabIndex: 1, url: "https://other.test/", title: "Other", isCurrent: false),
                Tab(tabIndex: 2, url: "https://fixture.test/page", title: expectedTitle, isCurrent: true),
            ], profile: "個人", windowID: 4711)], path)

            let rows = DocumentsCommand.jsonRows(SafariBridge.flattenWindowsToDocuments(windows),
                                                 observation: .unavailable(reason: "test"))
            XCTAssertEqual(rows.count, 2, path)
            XCTAssertEqual(rows.compactMap { $0["window_id"] as? Int }, [4711, 4711], path)

            let byURL = try SafariBridge.pickNativeTarget(.urlMatch(.contains("fixture.test/page")), in: windows)
            XCTAssertEqual(byURL.windowIndex, 1, path)
            XCTAssertEqual(byURL.anchorTabIndex, 2, path)
            let byID = try SafariBridge.pickNativeTarget(.windowID(4711), in: windows, profile: "個人")
            XCTAssertEqual(byID.windowID, 4711, path)

            // The same text through `listAllWindows`, as a fake Safari would answer it.
            let listed = try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in text }) {
                try await SafariBridge.listAllWindows()
            }
            XCTAssertEqual(listed, windows, path)
        }
    }
}
