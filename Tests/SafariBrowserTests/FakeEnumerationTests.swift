import XCTest
@testable import SafariBrowser

/// The fixture helper, the daemon's descriptor conversion and the real `osascript -s s` agree on
/// the enumeration text (#355), so a fake Safari answers exactly what a real one would.
final class FakeEnumerationTests: XCTestCase {

    private let windows: [FakeEnumeration.Window] = [
        .init(id: 4711, name: "個人 — A \"quoted\" \\ title", currentTab: 2,
              tabs: [(url: "https://a.example/?q=1", title: "One\u{1E}Two"), (url: "https://a.example/2", title: "A \"quoted\" \\ title")]),
        .init(id: nil, name: nil, tabs: []),
        .init(id: 9, name: "Plain", tabs: [(url: "", title: "\r\n\t\u{1D}")]),
    ]

    /// The same windows as an AppleScript literal, built without the helper.
    private var script: String {
        let u = { (s: String) in AppleScriptSourceFormRenderTests.utxt(Array(s.utf16)) }
        return """
            return {{1, 4711, \(u("個人 — A \"quoted\" \\ title")), 2, {\(u("https://a.example/?q=1")), \(u("https://a.example/2"))}, \
            {\(u("One\u{1E}Two")), \(u("A \"quoted\" \\ title"))}}, {2, missing value, missing value, 0, {}, {}}, \
            {3, 9, \(u("Plain")), 1, {\(u(""))}, {\(u("\r\n\t\u{1D}"))}}}
            """
    }

    func testTheHelperWritesWhatOsascriptAndTheDaemonWrite() throws {
        let helper = FakeEnumeration.sourceForm(windows)
        XCTAssertEqual(Array(helper.utf8), Array(try AppleScriptSourceFormRenderTests.osascriptSourceForm(script).utf8))
        XCTAssertEqual(Array(helper.utf8), Array(try AppleScriptSourceFormRenderTests.renderedSourceForm(script).utf8))
    }

    func testAnEnumerationThatComesBackEmptyFailsTheCommand() async throws {
        // A daemon path that returned a list's string value would hand back "". It must not read
        // as "Safari has no windows".
        do {
            _ = try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in "" }) {
                try await SafariBridge.listAllWindows()
            }
            XCTFail("an empty enumeration must fail")
        } catch SafariBrowserError.windowEnumerationCorrupt {
        }
    }

    func testListAllWindowsDecodesWhatTheScriptReturns() async throws {
        let text = FakeEnumeration.sourceForm(windows)
        let seen = try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
            guard FakeEnumeration.isEnumeration(source) else { throw SafariBrowserError.appleScriptFailed("unexpected script") }
            return text
        }) {
            try await SafariBridge.listAllWindows()
        }
        XCTAssertEqual(seen.map(\.windowIndex), [1, 2, 3])
        XCTAssertEqual(seen[0].tabs.map(\.title), ["One\u{1E}Two", "A \"quoted\" \\ title"])
        XCTAssertEqual(seen[0].currentTabIndex, 2)
        XCTAssertEqual(seen[0].profile, "個人")
        XCTAssertEqual(seen[1].windowID, nil)
        XCTAssertEqual(seen[2].tabs.first?.title, "\r\n\t\u{1D}")
    }

    func testListAllWindowsAsksForSourceFormNotText() async throws {
        // In the daemon both in-process runners are installed; the text runner answers a list
        // with its string value, "". The enumeration must go to the source form runner.
        let text = FakeEnumeration.sourceForm(windows)
        let seen = try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in "" }) {
            try await DaemonRequestContext.$appleScriptSourceFormRunner.withValue({ _ in text }) {
                try await SafariBridge.listAllWindows()
            }
        }
        XCTAssertEqual(seen.map(\.windowIndex), [1, 2, 3])
    }
}
