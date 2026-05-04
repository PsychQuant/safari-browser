import XCTest
import ArgumentParser
@testable import SafariBrowser

/// Tests for `TargetOptions` validation and resolution logic. Covers:
/// - Composite targeting flag --tab-in-window (issue #28 gap #2 escape hatch)
/// - Mutual exclusivity rules between --url / --window / --tab / --document / --tab-in-window
/// - Positive-value guards for all index flags
/// - resolve() precedence mapping to TargetDocument cases
final class TargetOptionsTests: XCTestCase {

    // MARK: - Helpers

    /// `TargetOptions` is an `@OptionGroup`-ready ParsableArguments with
    /// all fields Optional-default-nil, so a zero-arg initializer works
    /// for direct property mutation in tests.
    private func makeOptions(
        url: String? = nil,
        urlExact: String? = nil,
        urlEndswith: String? = nil,
        urlRegex: String? = nil,
        window: Int? = nil,
        tab: Int? = nil,
        document: Int? = nil,
        tabInWindow: Int? = nil,
        firstMatch: Bool = false,
        markTab: Bool = false,
        markTabPersist: Bool = false
    ) -> TargetOptions {
        var opts = TargetOptions()
        opts.url = url
        opts.urlExact = urlExact
        opts.urlEndswith = urlEndswith
        opts.urlRegex = urlRegex
        opts.window = window
        opts.tab = tab
        opts.document = document
        opts.tabInWindow = tabInWindow
        opts.firstMatch = firstMatch
        opts.markTab = markTab
        opts.markTabPersist = markTabPersist
        return opts
    }

    // MARK: - --tab-in-window validation

    func testTabInWindowRequiresWindow() {
        // --tab-in-window without --window must fail validation with a
        // message mentioning the required --window flag.
        let opts = makeOptions(tabInWindow: 2)
        XCTAssertThrowsError(try opts.validate()) { error in
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("--tab-in-window"))
            XCTAssertTrue(msg.contains("--window"),
                          "Error must mention that --window is required")
        }
    }

    func testTabInWindowPairedWithWindowValidates() throws {
        let opts = makeOptions(window: 1, tabInWindow: 2)
        try opts.validate()  // expect no throw
    }

    func testTabInWindowZeroRejected() {
        let opts = makeOptions(window: 1, tabInWindow: 0)
        XCTAssertThrowsError(try opts.validate())
    }

    func testTabInWindowNegativeRejected() {
        let opts = makeOptions(window: 1, tabInWindow: -1)
        XCTAssertThrowsError(try opts.validate())
    }

    // MARK: - Mutual exclusivity

    func testWindowCannotCombineWithUrl() {
        // --window + --url should error because --window already provides
        // a target and --url asks for a different disambiguation mechanism.
        let opts = makeOptions(url: "plaud", window: 1)
        XCTAssertThrowsError(try opts.validate()) { error in
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("mutually exclusive") || msg.contains("--window"))
        }
    }

    func testWindowCannotCombineWithDocument() {
        let opts = makeOptions(window: 1, document: 2)
        XCTAssertThrowsError(try opts.validate())
    }

    func testUrlAndDocumentMutuallyExclusive() {
        let opts = makeOptions(url: "plaud", document: 2)
        XCTAssertThrowsError(try opts.validate())
    }

    func testTabAndDocumentMutuallyExclusive() {
        let opts = makeOptions(tab: 1, document: 2)
        XCTAssertThrowsError(try opts.validate())
    }

    func testWindowTabInWindowNotConsideredMutuallyExclusive() throws {
        // The (--window, --tab-in-window) pair is a composite mode, not
        // a conflict. Regression guard against over-eager exclusivity.
        let opts = makeOptions(window: 2, tabInWindow: 3)
        try opts.validate()
    }

    // MARK: - resolve() precedence

    func testResolveCompositeWindowTab() {
        let opts = makeOptions(window: 1, tabInWindow: 2)
        let target = opts.resolve()
        guard case .windowTab(let w, let m) = target else {
            return XCTFail("Expected .windowTab, got \(target)")
        }
        XCTAssertEqual(w, 1)
        XCTAssertEqual(m, 2)
    }

    func testResolveUrl() {
        let opts = makeOptions(url: "plaud")
        if case .urlMatch(.contains(let p)) = opts.resolve() {
            XCTAssertEqual(p, "plaud")
        } else {
            XCTFail("Expected .urlMatch(.contains)")
        }
    }

    func testResolveWindowOnly() {
        let opts = makeOptions(window: 3)
        if case .windowIndex(let n) = opts.resolve() {
            XCTAssertEqual(n, 3)
        } else {
            XCTFail("Expected .windowIndex(3)")
        }
    }

    func testResolveTabAliasesDocumentIndex() {
        let opts = makeOptions(tab: 4)
        if case .documentIndex(let n) = opts.resolve() {
            XCTAssertEqual(n, 4)
        } else {
            XCTFail("Expected .documentIndex(4)")
        }
    }

    func testResolveDocument() {
        let opts = makeOptions(document: 5)
        if case .documentIndex(let n) = opts.resolve() {
            XCTAssertEqual(n, 5)
        } else {
            XCTFail("Expected .documentIndex(5)")
        }
    }

    func testResolveNoFlagFallsToFrontWindow() {
        let opts = makeOptions()
        if case .frontWindow = opts.resolve() {
            // expected
        } else {
            XCTFail("Expected .frontWindow")
        }
    }

    // MARK: - Precise URL matching (#34)

    func testResolveUrlExactMapsToExactMatcher() {
        let opts = makeOptions(urlExact: "https://web.plaud.ai/")
        guard case .urlMatch(.exact(let u)) = opts.resolve() else {
            return XCTFail("Expected .urlMatch(.exact)")
        }
        XCTAssertEqual(u, "https://web.plaud.ai/")
    }

    func testResolveUrlEndswithMapsToEndsWithMatcher() {
        let opts = makeOptions(urlEndswith: "/play")
        guard case .urlMatch(.endsWith(let s)) = opts.resolve() else {
            return XCTFail("Expected .urlMatch(.endsWith)")
        }
        XCTAssertEqual(s, "/play")
    }

    func testResolveUrlRegexMapsToRegexMatcher() {
        let opts = makeOptions(urlRegex: "lesson/[a-f0-9-]+$")
        guard case .urlMatch(.regex(let r)) = opts.resolve() else {
            return XCTFail("Expected .urlMatch(.regex)")
        }
        XCTAssertEqual(r.pattern, "lesson/[a-f0-9-]+$")
    }

    // MARK: - URL-matching flag mutual exclusion (#34)

    func testMultipleUrlFlagsMutuallyExclusive() {
        let opts = makeOptions(url: "plaud", urlEndswith: "/play")
        XCTAssertThrowsError(try opts.validate()) { error in
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("--url"))
            XCTAssertTrue(msg.contains("--url-endswith"))
            XCTAssertTrue(msg.contains("mutually exclusive"),
                          "Error must identify the conflicting flags as mutually exclusive")
        }
    }

    func testUrlExactConflictsWithUrlRegex() {
        let opts = makeOptions(urlExact: "https://x/", urlRegex: "^.*$")
        XCTAssertThrowsError(try opts.validate())
    }

    func testUrlFlagConflictsWithWindow() {
        let opts = makeOptions(urlEndswith: "/play", window: 2)
        XCTAssertThrowsError(try opts.validate()) { error in
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("--window"))
        }
    }

    // MARK: - Validation edge cases (#34)

    func testEmptyUrlEndswithRejected() {
        let opts = makeOptions(urlEndswith: "")
        XCTAssertThrowsError(try opts.validate()) { error in
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("--url-endswith"))
            XCTAssertTrue(msg.contains("non-empty"),
                          "Error must explain that empty suffix is rejected")
        }
    }

    func testInvalidUrlRegexRejectedAtValidateTime() {
        let opts = makeOptions(urlRegex: "[")
        XCTAssertThrowsError(try opts.validate()) { error in
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("--url-regex"),
                          "Error must identify which flag failed to compile")
        }
    }

    func testValidUrlRegexCompiles() throws {
        let opts = makeOptions(urlRegex: "^https://x/[a-z]+$")
        try opts.validate()  // expect no throw
    }

    // MARK: - resolveWithFirstMatch helper (#33)

    func testResolveWithFirstMatchBundlesTargetFirstMatchAndWriter() {
        let opts = makeOptions(url: "plaud", firstMatch: true)
        let bundle = opts.resolveWithFirstMatch()
        if case .urlMatch(.contains(let p)) = bundle.target {
            XCTAssertEqual(p, "plaud")
        } else {
            XCTFail("Expected .urlMatch(.contains)")
        }
        XCTAssertTrue(bundle.firstMatch)
        // warnWriter is non-nil and callable — concrete stderr behavior
        // is outside the unit boundary (would couple test to FileHandle).
        bundle.warnWriter("test message\n")  // should not crash
    }

    func testResolveWithFirstMatchDefaultsFirstMatchFalse() {
        let opts = makeOptions(url: "plaud")
        XCTAssertFalse(opts.resolveWithFirstMatch().firstMatch)
    }

    // MARK: - Parse-level integration via OpenCommand (hosts TargetOptions via @OptionGroup)

    func testCLIParseAcceptsWindowAndTabInWindow() throws {
        let cmd = try OpenCommand.parse([
            "https://example.com",
            "--window", "1",
            "--tab-in-window", "2",
        ])
        XCTAssertEqual(cmd.target.window, 1)
        XCTAssertEqual(cmd.target.tabInWindow, 2)
    }

    func testCLIValidateRejectsSoloTabInWindow() {
        // ParsableCommand.parse() automatically calls validate() on the
        // command and its @OptionGroup members, so a solo --tab-in-window
        // fails at the parse boundary rather than later at run-time.
        XCTAssertThrowsError(try OpenCommand.parse([
            "https://example.com",
            "--tab-in-window", "2",
        ])) { error in
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("--tab-in-window"),
                          "Error must mention the offending flag, got: \(msg)")
        }
    }

    // MARK: - --profile flag (Issue #47)

    func testProfileFlagParsesValue() throws {
        let cmd = try OpenCommand.parse([
            "https://example.com",
            "--profile", "個人",
        ])
        XCTAssertEqual(cmd.target.profile, "個人")
        XCTAssertEqual(cmd.target.resolveProfile(), "個人")
    }

    func testProfileFlagDefaultIsNil() throws {
        let cmd = try OpenCommand.parse(["https://example.com"])
        XCTAssertNil(cmd.target.profile)
        XCTAssertNil(cmd.target.resolveProfile())
    }

    func testProfileFlagCombinesWithUrl() throws {
        // --profile is orthogonal to the URL-matching flags;
        // combining them is the primary use case.
        let cmd = try OpenCommand.parse([
            "https://example.com",
            "--profile", "工作",
            "--url", "plaud",
        ])
        XCTAssertEqual(cmd.target.profile, "工作")
        XCTAssertEqual(cmd.target.url, "plaud")
        XCTAssertEqual(cmd.target.resolveProfile(), "工作")
        switch cmd.target.resolve() {
        case .urlMatch(.contains(let s)):
            XCTAssertEqual(s, "plaud")
        default:
            XCTFail("Expected urlMatch(.contains)")
        }
    }

    func testProfileFlagSoloIsValid() throws {
        // --profile alone (no URL match, no --window) is allowed:
        // filtering happens at SafariBridge.pickNativeTarget;resolution
        // falls back to .frontWindow within that profile.
        let cmd = try OpenCommand.parse([
            "https://example.com",
            "--profile", "X",
        ])
        XCTAssertNoThrow(try cmd.target.validate())
        XCTAssertEqual(cmd.target.resolveProfile(), "X")
    }
}
