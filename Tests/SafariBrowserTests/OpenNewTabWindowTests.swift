import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #351 (folded into #352): `open --new-tab` created the tab in another window.
///
/// - `--window N`: the script ran `activate` and then `tell window N`. `window N` is a z-order position, and activating
///   Safari can bring another window forward first, so N named a different window (three misses on a real Safari with
///   several windows while Safari was not frontmost). The script now reads `id of window N` **before** `activate`.
/// - `--profile`: `OpenCommand` resolved the profile's window through `resolveToConcreteTarget`, whose window-level
///   result is `.windowIndex(<position>)` — the id the enumeration had read was dropped (`concreteTarget`), and the
///   position was looked up again after `activate`. It now takes the id from `resolveNativeTarget`.
/// - `--window-id W` (#352): `tell window id W`, without `activate`; the new tab is still made current.
final class OpenNewTabWindowTests: XCTestCase, @unchecked Sendable {
    typealias Fake = WindowIDCommandTests.TwoProfileFake

    // MARK: 3.2 the script

    func testAWindowNumberIsTurnedIntoAnIdBeforeSafariIsActivated() throws {
        let script = SafariBridge.openURLInNewTabScript("https://a.example/", window: .index(2))
        // the branch that creates a tab (the other one makes a new document when there is no window)
        let creating = try XCTUnwrap(script.components(separatedBy: "\n    else\n").last, script)
        let idRead = try XCTUnwrap(creating.range(of: "set _w to id of window 2"), script)
        let activate = try XCTUnwrap(creating.range(of: "activate"), script)
        XCTAssertLessThan(idRead.lowerBound, activate.lowerBound, "the window must be pinned before activate can reorder windows:\n\(script)")
        XCTAssertTrue(script.contains("tell window id _w"), script)
        XCTAssertFalse(script.contains("tell window 2"), "the tab must not be created in a position looked up after activate:\n\(script)")
    }

    func testAWindowIdIsUsedAsIsAndActivatesByDefault() {
        let script = SafariBridge.openURLInNewTabScript("https://a.example/", window: .id(9005))
        XCTAssertTrue(script.contains("tell window id 9005"), script)
        XCTAssertTrue(script.contains("activate"), script)
        XCTAssertFalse(script.contains("front window"), script)
    }

    /// `--window-id`: the maintainer's ruling (2026-11-05) — do not bring Safari forward, but the new tab is still the
    /// window's current tab.
    func testAWindowIdWithoutActivateNeverActivatesButStillMakesTheTabCurrent() {
        let script = SafariBridge.openURLInNewTabScript("https://a.example/", window: .id(9005, activate: false))
        XCTAssertTrue(script.contains("tell window id 9005"), script)
        XCTAssertFalse(script.contains("activate"), script)
        XCTAssertTrue(script.contains("set current tab to newTab"), script)
        XCTAssertFalse(script.contains("make new document"), "a missing id must fail, not open a window:\n\(script)")
    }

    /// The default path (no target) keeps the front window, as before.
    func testNoWindowKeepsTheFrontWindow() {
        let script = SafariBridge.openURLInNewTabScript("https://a.example/", window: .front)
        XCTAssertTrue(script.contains("tell front window"), script)
        XCTAssertFalse(script.contains("window id"), script)
    }

    /// Each variant compiles (compile only, nothing runs; same check as `JSInlineProtocolTests`).
    func testEveryVariantCompiles() {
        for window in [SafariBridge.NewTabWindow.front, .index(2), .id(9005), .id(9005, activate: false)] {
            var error: NSDictionary?
            let ok = NSAppleScript(source: SafariBridge.openURLInNewTabScript("https://a.example/\"x", window: window))?
                .compileAndReturnError(&error) ?? false
            XCTAssertTrue(ok, "\(window): \(String(describing: error))")
        }
    }

    /// The URL still goes through AppleScript escaping.
    func testTheURLIsEscaped() {
        let script = SafariBridge.openURLInNewTabScript("https://a.example/\"x\\y", window: .index(1))
        XCTAssertTrue(script.contains("https://a.example/\\\"x\\\\y"), script)
    }

    // MARK: 3.1 / 3.3 what `open` sends

    private func open(_ args: [String], on fake: Fake) async throws {
        var command = try OpenCommand.parse(args)
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        try await DaemonRequestContext.$current.withValue(context) {
            try await WindowDialogObservation.$provider.withValue({ WindowDialogObservation.unavailable(reason: "test") }) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                    try await command.run()
                }
            }
        }
    }

    private func newTabScripts(_ fake: Fake) -> [String] { fake.scripts.filter { $0.contains("make new tab") } }

    func testNewTabWithAWindowIDCreatesTheTabThereWithoutActivating() async throws {
        let fake = Fake()
        try await open(["https://n.example/", "--new-tab", "--window-id", "202"], on: fake)
        XCTAssertEqual(newTabScripts(fake),
                       [SafariBridge.openURLInNewTabScript("https://n.example/", window: .id(202, activate: false))])
    }

    func testNewTabWithAWindowIDOutsideTheProfileOpensNothing() async throws {
        let fake = Fake()
        do {
            try await open(["https://n.example/", "--new-tab", "--window-id", "202", "--profile", "個人"], on: fake)
            XCTFail("window 202 is not in 個人")
        } catch SafariBrowserError.documentNotFound {}
        XCTAssertEqual(newTabScripts(fake), [])
    }

    /// The id the profile-scoped enumeration read is the one the tab is created in (not a position read again after
    /// `activate`).
    func testNewTabWithAProfileUsesTheEnumerationsWindowID() async throws {
        for (args, id) in [(["--profile", "Work"], 202), (["--profile", "個人", "--window", "1"], 101)] {
            let fake = Fake()
            try await open(["https://n.example/", "--new-tab"] + args, on: fake)
            XCTAssertEqual(newTabScripts(fake), [SafariBridge.openURLInNewTabScript("https://n.example/", window: .id(id))], "\(args)")
        }
    }

    func testNewTabWithAWindowNumberPinsItBeforeActivate() async throws {
        let fake = Fake()
        try await open(["https://n.example/", "--new-tab", "--window", "2"], on: fake)
        XCTAssertEqual(newTabScripts(fake), [SafariBridge.openURLInNewTabScript("https://n.example/", window: .index(2))])
    }

    func testNewTabRejectsTargetsOtherThanTheWindowFlagsAndProfile() {
        for args in [["--url", "x"], ["--url-exact", "https://x/"], ["--url-endswith", "/x"], ["--url-regex", "x"],
                     ["--tab", "1"], ["--document", "1"], ["--window", "1", "--tab-in-window", "1"]] {
            XCTAssertThrowsError(try OpenCommand.parse(["https://n.example/", "--new-tab"] + args), "\(args)") { error in
                let text = OpenCommand.message(for: error)
                XCTAssertTrue(text.contains("--window-id") && text.contains("--profile"), "\(args): \(text)")
            }
        }
    }

    /// 3.1: `open` without `--new-tab` navigates the tab a targeting flag names. `--window-id` and the URL flags that
    /// `open`'s own check used to leave out (safari-browser#233) no longer fall through to opening a new tab.
    func testOpenWithATargetNavigatesThatTabInsteadOfOpeningANewOne() async throws {
        for (args, ref) in [(["--window-id", "202"], "document of window id 202"),
                            (["--url-endswith", "work.example/1"], "window id 202")] {
            let fake = Fake()
            try await open(["https://n.example/"] + args, on: fake)
            XCTAssertEqual(newTabScripts(fake), [], "\(args)")
            XCTAssertTrue(fake.scripts.contains { $0.contains("window.location.href") && $0.contains(ref) },
                          "\(args):\n\(fake.scripts.joined(separator: "\n---\n"))")
        }
    }
}
