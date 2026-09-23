import Foundation
import XCTest
@testable import SafariBrowser

/// #180 verify round 1: the fix that took `js` from six window enumerations
/// per command to at most one lived in a single call site
/// (`JSCommand.run` → `resolveToAnchoredTarget`), and nothing tested it —
/// reverting that line to `resolveToConcreteTarget` left the whole suite green,
/// and the live `e2e-target-identity.sh` only exercises `--url` targets, which
/// were already anchored before #180.
///
/// These tests run the real `JSCommand` against a fake Safari (every AppleScript
/// goes through `DaemonRequestContext.appleScriptRunner`) shaped like the
/// machine in the issue: 5 windows, 96 + 2 + 6 + 1 + 4 = 109 tabs. They count
/// what the command actually sends, so the bound holds at 109 tabs without
/// opening 109 real tabs.
final class JSCommandRoundTripTests: XCTestCase, @unchecked Sendable {

    // MARK: - Fake Safari

    /// Thread-safe record of every AppleScript the command sent.
    final class FakeSafari: @unchecked Sendable {
        let tabCounts: [Int]
        /// Window id of AppleScript window N is `idBase + N`.
        let idBase = 100
        /// When set, `do JavaScript` scripts containing this marker raise -1719,
        /// as Safari does when the addressed tab no longer exists.
        let failJSContaining: String?
        private let lock = NSLock()
        private var sent: [String] = []

        init(tabCounts: [Int] = [96, 2, 6, 1, 4], failJSContaining: String? = nil) {
            self.tabCounts = tabCounts
            self.failJSContaining = failJSContaining
        }

        var scripts: [String] { lock.lock(); defer { lock.unlock() }; return sent }
        var enumerations: Int { scripts.filter { $0.contains("set windowCount to count of windows") }.count }
        /// `windowAnchorScript` only — the enumeration also reads
        /// `index of current tab of window w`, so match the anchor's own shape.
        var anchors: [String] { scripts.filter { $0.contains("return ((id of window") } }
        var javaScripts: [String] { scripts.filter { $0.contains("do JavaScript") } }
        /// One line per script sent, for assertion messages.
        var transcript: String {
            scripts.enumerated().map { "[\($0.offset)] " + $0.element
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: "").prefix(140) }.joined(separator: "\n")
        }

        /// The 7-field GS/RS wire format of `listAllWindowsScript`.
        var enumeration: String {
            let gs = "\u{1D}", rs = "\u{1E}"
            var out = ""
            for (offset, count) in tabCounts.enumerated() {
                let w = offset + 1
                for t in 1...count {
                    out += ["\(w)", "\(t)", t == 1 ? "1" : "0", "https://w\(w).example/\(t)",
                            "Tab \(t)", "個人 — Tab 1", "\(idBase + w)"].joined(separator: gs) + rs
                }
            }
            return out
        }

        func respond(_ script: String) throws -> String {
            lock.lock(); sent.append(script); lock.unlock()
            if script.contains("set windowCount to count of windows") { return enumeration }
            if script.contains("return ((id of window") {
                if let id = Self.firstInt(after: "window id ", in: script) { return "\(id)\u{1D}1" }
                if let n = Self.firstInt(after: "of window ", in: script) { return "\(idBase + n)\u{1D}1" }
                return ""
            }
            if script.contains("get id of window"), let n = Self.firstInt(after: "get id of window ", in: script) {
                return "\(idBase + n)"
            }
            if script.contains("do JavaScript") {
                if let marker = failJSContaining, script.contains(marker) {
                    throw SafariBrowserError.appleScriptFailed(
                        "execution error: Safari got an error: Can’t get tab. Invalid index. (-1719)")
                }
                if script.contains("window.__sbResult.substring(") { return "hello" }
                if script.contains("do JavaScript \"window.__sbResultLen\"") { return "5.0" }
                if script.contains("'' + window.__sbLen") { return "5.0" }
                if script.contains("do JavaScript \"window.__sbResult\"") { return "hello" }
                return ""
            }
            if script.contains("URL of") { return "https://w1.example/1" }
            return ""
        }

        private static func firstInt(after prefix: String, in text: String) -> Int? {
            guard let range = text.range(of: prefix) else { return nil }
            return Int(text[range.upperBound...].prefix(while: \.isNumber))
        }
    }

    /// Run `safari-browser js <args>` against `fake`, dialog probe answering clear.
    private func runJS(_ args: [String], on fake: FakeSafari) async throws {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let command = try JSCommand.parse(args)
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                try await command.run()
            }
        }
    }

    // MARK: - Round-trip bound at 109 tabs

    func testWindowTabTargetEnumeratesAtMostOnceAt109Tabs() async throws {
        let fake = FakeSafari()
        try await runJS(["--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
        XCTAssertEqual(fake.enumerations, 1,
                       "--window N --tab-in-window M must enumerate once, not once per protocol step")
        XCTAssertFalse(fake.javaScripts.isEmpty)
        for script in fake.javaScripts {
            XCTAssertTrue(script.contains("tab 53 of window id 101"),
                          "every step must address the anchored tab: \(script)")
        }
    }

    func testDefaultTargetNeverEnumerates() async throws {
        let fake = FakeSafari()
        try await runJS(["location.host"], on: fake)
        XCTAssertEqual(fake.enumerations, 0, "the default target needs no enumeration at all")
        XCTAssertEqual(fake.anchors.count, 1, "one anchor round-trip at the command boundary")
        for script in fake.javaScripts {
            XCTAssertTrue(script.contains("tab 1 of window id 101"), script)
        }
    }

    func testWindowIndexTargetNeverEnumerates() async throws {
        let fake = FakeSafari()
        try await runJS(["--window", "3", "location.host"], on: fake)
        XCTAssertEqual(fake.enumerations, 0)
        for script in fake.javaScripts {
            XCTAssertTrue(script.contains("tab 1 of window id 103"), script)
        }
    }

    func testLargePathEnumeratesAtMostOnce() async throws {
        let fake = FakeSafari()
        try await runJS(["--large", "--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
        XCTAssertEqual(fake.enumerations, 1)
        for script in fake.javaScripts {
            XCTAssertTrue(script.contains("tab 53 of window id 101"), script)
        }
    }

    // MARK: - --profile: anchor by the resolved window's id (verify R1 SEC-L1)

    func testProfileWindowTargetAnchorsByWindowIDNotIndex() async throws {
        let fake = FakeSafari()
        try await runJS(["--profile", "個人", "--window", "2", "location.host"], on: fake)
        XCTAssertEqual(fake.enumerations, 1, "the profile filter needs exactly one enumeration:\n\(fake.transcript)")
        XCTAssertEqual(fake.anchors.count, 1, fake.transcript)
        XCTAssertTrue(fake.anchors[0].contains("window id 102"),
                      "a z-order index read after the enumeration can point at another profile's window: \(fake.anchors[0])")
        for script in fake.javaScripts {
            XCTAssertTrue(script.contains("tab 1 of window id 102"), script)
        }
    }

    // MARK: - A vanished anchored tab must not list every window (verify R1 SEC-M1)

    func testVanishedDefaultTabDoesNotListOtherWindowsURLs() async {
        let fake = FakeSafari(failJSContaining: "'' + window.__sbLen")
        do {
            try await runJS(["location.host"], on: fake)
            XCTFail("expected the vanished tab to fail the command")
        } catch let error as SafariBrowserError {
            guard case .anchoredTabGone = error else {
                return XCTFail("expected anchoredTabGone, got \(error)")
            }
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("w2.example"), "must not list other windows' tabs:\n\(text)")
            XCTAssertFalse(text.contains("w1.example/2"), "must not list other tabs:\n\(text)")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testVanishedWindowTabNamesTheOriginalTarget() async {
        let fake = FakeSafari(failJSContaining: "'' + window.__sbLen")
        do {
            try await runJS(["--window", "1", "--tab-in-window", "53", "location.host"], on: fake)
            XCTFail("expected the vanished tab to fail the command")
        } catch let error as SafariBrowserError {
            guard case .anchoredTabGone(let target) = error else {
                return XCTFail("expected anchoredTabGone, got \(error)")
            }
            XCTAssertTrue(target.contains("window 1 tab 53"), target)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
