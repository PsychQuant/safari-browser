import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #352: `--window-id W` end to end over a fake Safari — what AppleScript each command sends, and
/// that a missing id or a window of another profile fails closed instead of reaching the front
/// window. The fake has two windows: id 101 in the profile 個人 (`https://own.example/1…3`, tab 1
/// current) and id 202 in the profile Work (`https://work.example/1…2`).
final class WindowIDCommandTests: XCTestCase, @unchecked Sendable {

    final class TwoProfileFake: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String] = []
        let windows: [(id: Int, profile: String, tabs: [String])] = [
            (101, "個人", (1...3).map { "https://own.example/\($0)" }),
            (202, "Work", (1...2).map { "https://work.example/\($0)" }),
        ]
        var scripts: [String] { lock.withLock { sent } }

        func respond(_ script: String) throws -> String {
            lock.withLock { sent.append(script) }
            if script.contains("set windowCount to count of windows") {
                let gs = "\u{1D}", rs = "\u{1E}"
                var out = ""
                for (i, window) in windows.enumerated() {
                    for (j, url) in window.tabs.enumerated() {
                        out += ["\(i + 1)", "\(j + 1)", j == 0 ? "1" : "0", url,
                                "Tab \(j + 1)", "\(window.profile) — Tab 1", "\(window.id)"].joined(separator: gs) + rs
                    }
                }
                return out
            }
            // `windowAnchorScript(windowID:)`: "id GS current-tab-index", or an error for a missing id.
            if script.contains("set _id to "), let id = Self.int(after: "set _id to ", in: script) {
                guard windows.contains(where: { $0.id == id }) else {
                    throw SafariBrowserError.appleScriptFailed("execution error: Can’t get window id \(id). (-1728)")
                }
                return "\(id)\u{1D}1"
            }
            if let id = Self.int(after: "window id ", in: script), !windows.contains(where: { $0.id == id }) {
                throw SafariBrowserError.appleScriptFailed("execution error: Can’t get window id \(id). (-1728)")
            }
            return "https://own.example/1"
        }

        static func int(after marker: String, in text: String) -> Int? {
            guard let range = text.range(of: marker) else { return nil }
            return Int(text[range.upperBound...].prefix { $0.isNumber })
        }
    }

    private func run<C: AsyncParsableCommand>(_ type: C.Type, _ args: [String], on fake: TwoProfileFake) async throws {
        var command = try C.parse(args)
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        try await DaemonRequestContext.$current.withValue(context) {
            try await WindowDialogObservation.$provider.withValue({ WindowDialogObservation.unavailable(reason: "test") }) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                    try await command.run()
                }
            }
        }
    }

    private func transcript(_ fake: TwoProfileFake) -> String { fake.scripts.joined(separator: "\n---\n") }

    // MARK: 2.1 every reference names the window by id

    func testGetURLAndClickAddressTheWindowByIDNeverTheFrontWindow() async throws {
        for (label, drive) in [
            ("get url", { (fake: TwoProfileFake) in try await self.run(GetURL.self, ["--window-id", "101"], on: fake) }),
            ("click", { (fake: TwoProfileFake) in try await self.run(ClickCommand.self, ["button", "--window-id", "101"], on: fake) }),
        ] as [(String, (TwoProfileFake) async throws -> Void)] {
            let fake = TwoProfileFake()
            do { try await drive(fake) } catch { /* the fake's canned answers may fail later; the scripts are what matter */ }
            let targeted = fake.scripts.filter { $0.contains("tell application \"Safari\"") && !$0.contains("set windowCount") }
            XCTAssertFalse(targeted.isEmpty, "\(label): nothing was sent:\n\(transcript(fake))")
            XCTAssertTrue(targeted.allSatisfy { $0.contains("window id 101") }, "\(label):\n\(transcript(fake))")
            XCTAssertFalse(fake.scripts.contains { $0.contains("front window") }, "\(label):\n\(transcript(fake))")
        }
    }

    // MARK: 2.2 js anchors by id and fails closed without one

    func testJSWithAMissingWindowIDFailsBeforeAnyJavaScript() async throws {
        let fake = TwoProfileFake()
        do {
            try await run(JSCommand.self, ["--window-id", "9999", "1"], on: fake)
            XCTFail("a missing window id must fail")
        } catch let error as SafariBrowserError {
            XCTAssertTrue(error.localizedDescription.hasPrefix("No Safari document matches"), "\(error.localizedDescription)")
        }
        XCTAssertFalse(fake.scripts.contains { $0.contains("do JavaScript") }, transcript(fake))
    }

    func testJSWithAWindowIDRunsInThatWindowsCurrentTab() async throws {
        let fake = TwoProfileFake()
        do { try await run(JSCommand.self, ["--window-id", "202", "1"], on: fake) } catch {}
        let dispatches = fake.scripts.filter { $0.contains("do JavaScript") }
        XCTAssertFalse(dispatches.isEmpty, transcript(fake))
        XCTAssertTrue(dispatches.allSatisfy { $0.contains("window id 202") && !$0.contains("front window") }, transcript(fake))
    }

    /// `tabs` built its own target from `--window` and would have dropped `--window-id`, listing
    /// the front window's tabs instead.
    func testTabsListsTheWindowByIDAndFailsClosedForAMissingID() async throws {
        let fake = TwoProfileFake()
        do { try await run(TabsCommand.self, ["--window-id", "202"], on: fake) } catch {}
        let reads = fake.scripts.filter { $0.contains("count of tabs of") && !$0.contains("set windowCount") }
        XCTAssertFalse(reads.isEmpty, transcript(fake))
        XCTAssertTrue(reads.allSatisfy { $0.contains("window id 202") }, transcript(fake))

        let missing = TwoProfileFake()
        do {
            try await run(TabsCommand.self, ["--window-id", "9999"], on: missing)
            XCTFail("a missing window id must fail")
        } catch SafariBrowserError.documentNotFound {}
        XCTAssertFalse(missing.scripts.contains { $0.contains("count of tabs of") && !$0.contains("set windowCount") }, transcript(missing))
    }

    // MARK: 2.4 profile membership

    func testAWindowIDOfAnotherProfileFailsWithoutListingThatProfilesTabs() async throws {
        for args in [["--window-id", "202", "--profile", "個人"],
                     ["--window-id", "202", "--tab-in-window", "1", "--profile", "個人"]] {
            let fake = TwoProfileFake()
            do {
                try await run(GetURL.self, args, on: fake)
                XCTFail("\(args): window 202 is not in 個人")
            } catch let error as SafariBrowserError {
                guard case .documentNotFound = error else { return XCTFail("\(args): \(error)") }
                XCTAssertFalse(error.localizedDescription.contains("work.example"), error.localizedDescription)
            }
            XCTAssertFalse(fake.scripts.contains { $0.contains("window id 202") && !$0.contains("set windowCount") },
                           "\(args): nothing may be read from the other profile's window:\n\(transcript(fake))")
        }
    }

    func testAWindowIDOfTheRequestedProfileResolvesToThatTab() async throws {
        let fake = TwoProfileFake()
        try await run(GetURL.self, ["--window-id", "101", "--tab-in-window", "2", "--profile", "個人"], on: fake)
        let reads = fake.scripts.filter { !$0.contains("set windowCount") }
        XCTAssertFalse(reads.isEmpty, transcript(fake))
        XCTAssertTrue(reads.allSatisfy { $0.contains("tab 2 of window id 101") }, transcript(fake))
    }

    func testJSWithAWindowIDOfAnotherProfileFailsBeforeAnyJavaScript() async throws {
        let fake = TwoProfileFake()
        do {
            try await run(JSCommand.self, ["--window-id", "202", "--profile", "個人", "1"], on: fake)
            XCTFail("window 202 is not in 個人")
        } catch SafariBrowserError.documentNotFound {}
        XCTAssertFalse(fake.scripts.contains { $0.contains("do JavaScript") }, transcript(fake))
    }
}
