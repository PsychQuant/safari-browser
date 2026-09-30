import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #231: a command whose target came from `resolveProfileScoped` (or `resolve()`) handed the
/// target to the bridge unresolved, and the reads that follow take no `firstMatch`, so an
/// ambiguous `--url` threw although `--first-match` was given — the defect `get text` had until
/// #220. The `document-targeting` requirement says every command that composes `TargetOptions`
/// honours the flag. `get text`, `get html`, `save-image` and `upload --js` now take their target
/// from `TargetOptions.resolveFirstMatchOnce`; `cookies get`, `console` and `errors` pass the flag
/// to the bridge.
final class FirstMatchResolutionTests: XCTestCase, @unchecked Sendable {
    typealias FakeSafari = ExecSharedTargetTests.Fake

    private func inContext<T>(_ fake: FakeSafari, _ body: () async throws -> T) async rethrows -> T {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        return try await DaemonRequestContext.$current.withValue(context) {
            try await WindowDialogObservation.$provider.withValue({ WindowDialogObservation.unavailable(reason: "test") }) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) { try await body() }
            }
        }
    }

    private func run<C: AsyncParsableCommand>(_ type: C.Type, _ args: [String], on fake: FakeSafari) async throws {
        var command = try C.parse(args)
        try await inContext(fake) { try await command.run() }
    }

    // MARK: - Every command that reads through the target

    private func uploadFixture() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("first-match-\(UUID().uuidString).txt").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Each command over the fake Safari (two windows; window 1 has 96 tabs that all match
    /// `w1.example`): without the flag an ambiguous `--url` fails, with it the ambiguity is gone.
    /// What happens after target resolution (reading an element, fetching a file) is not under
    /// test, so any later error is fine.
    func testEveryReadCommandHonoursFirstMatchAtTargetResolution() async throws {
        let upload = try uploadFixture()
        defer { try? FileManager.default.removeItem(atPath: upload) }
        let save = FileManager.default.temporaryDirectory.appendingPathComponent("save-image-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: save) }
        let cases: [(String, (FakeSafari, [String]) async throws -> Void)] = [
            ("get text", { try await self.run(GetText.self, ["#sel"] + $1, on: $0) }),
            ("get html", { try await self.run(GetHTML.self, ["#sel"] + $1, on: $0) }),
            ("save-image", { try await self.run(SaveImageCommand.self, [save, "--element", "svg"] + $1, on: $0) }),
            ("upload --js", { try await self.run(UploadCommand.self, ["input", upload, "--js"] + $1, on: $0) }),
            ("cookies get", { try await self.run(CookiesGet.self, $1, on: $0) }),
            ("console", { try await self.run(ConsoleCommand.self, $1, on: $0) }),
            ("errors", { try await self.run(ErrorsCommand.self, $1, on: $0) }),
        ]
        for (label, drive) in cases {
            do {
                try await drive(FakeSafari(), ["--url", "w1.example"])
                XCTFail("\(label): an ambiguous --url must fail without --first-match")
            } catch SafariBrowserError.ambiguousWindowMatch {
            } catch {
                XCTFail("\(label): expected ambiguousWindowMatch without the flag, got \(error)")
            }
            do {
                try await drive(FakeSafari(), ["--url", "w1.example", "--first-match"])
            } catch SafariBrowserError.ambiguousWindowMatch {
                XCTFail("\(label): --first-match was not honoured")
            } catch {
                // a later failure of the fake's canned answers is fine
            }
        }
    }

    /// `get html` end to end: the read goes to the FIRST matching tab.
    func testGetHTMLReadsTheFirstMatchingTab() async throws {
        let fake = FakeSafari()
        try await run(GetHTML.self, ["#sel", "--url", "w1.example", "--first-match"], on: fake)
        let transcript = fake.scripts.joined(separator: "\n---\n")
        XCTAssertEqual(fake.enumerations, 1, "one resolution for the whole command:\n\(transcript)")
        XCTAssertTrue(fake.scripts.contains { $0.contains("do JavaScript") && $0.contains("tab 1 of window id 101") }, transcript)
    }

    // MARK: - The helper

    private func resolve(_ args: [String], on fake: FakeSafari, warnings: WarningLog = WarningLog()) async throws -> SafariBridge.TargetDocument {
        let command = try GetHTML.parse(["#sel"] + args)
        return try await inContext(fake) { try await command.target.resolveFirstMatchOnce(warnWriter: { warnings.add($0) }) }
    }

    final class WarningLog: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ text: String) { lock.withLock { items.append(text) } }
        var all: [String] { lock.withLock { items } }
    }

    /// `--first-match` on a URL target without `--profile`: one enumeration, a concrete tab that is
    /// the FIRST match, and exactly one warning that lists the candidates.
    func testTheHelperResolvesAURLTargetOnceToTheFirstMatchWithOneWarning() async throws {
        let fake = FakeSafari()
        let warnings = WarningLog()
        let resolved = try await resolve(["--url", "w1.example", "--first-match"], on: fake, warnings: warnings)
        guard case .resolvedTab(let windowID, let tab, _, _) = resolved else { return XCTFail("expected a concrete tab, got \(resolved)") }
        XCTAssertEqual(windowID, 101)
        XCTAssertEqual(tab, 1, "the first match")
        XCTAssertEqual(fake.enumerations, 1)
        XCTAssertEqual(warnings.all.count, 1, "\(warnings.all)")
        XCTAssertTrue(warnings.all.joined().contains("window 1 tab 2"), "the warning lists the other candidates: \(warnings.all)")

        // A unique match with the flag is resolved too (no warning: nothing was ambiguous).
        let unique = FakeSafari(), quiet = WarningLog()
        let single = try await resolve(["--url", "w1.example/2", "--first-match"], on: unique, warnings: quiet)
        guard case .resolvedTab(_, let tab2, _, _) = single else { return XCTFail("expected a concrete tab, got \(single)") }
        XCTAssertEqual(tab2, 2)
        XCTAssertEqual(quiet.all, [])
    }

    /// Everything else is what `resolveProfileScoped` returned before: the flag without a URL
    /// flag is a no-op, and without the flag nothing is resolved until a read needs it.
    func testEveryOtherCombinationIsWhatResolveProfileScopedReturns() async throws {
        let combos: [[String]] = [
            ["--url", "w1.example"],                                   // no flag: unresolved
            ["--url", "w1.example/2"],                                 // unique match, no flag
            ["--document", "2", "--first-match"],                      // non-URL target, flag: no-op
            ["--window", "2", "--first-match"],
            ["--window", "1", "--tab-in-window", "3", "--first-match"],
            ["--first-match"],                                         // no target at all
            ["--profile", "個人", "--url", "w1.example", "--first-match"],   // profile + flag
            ["--profile", "個人", "--url", "w1.example/2"],            // profile, no flag
            ["--profile", "個人", "--document", "2", "--first-match"],
        ]
        func outcome(_ body: () async throws -> SafariBridge.TargetDocument) async -> String {
            do { return String(describing: try await body()) } catch { return "throws \(error)" }
        }
        for args in combos {
            let viaHelper = await outcome { try await resolve(args, on: FakeSafari()) }
            let command = try GetHTML.parse(["#sel"] + args)
            let viaProfileScoped = await outcome { try await inContext(FakeSafari()) { try await command.target.resolveProfileScoped() } }
            XCTAssertEqual(viaHelper, viaProfileScoped, "\(args)")
        }
    }

    /// The failures too, and the profile is never dropped: `--profile` resolves inside that profile
    /// (a profile with no window is a not-found, not a read of another profile's tab), and an
    /// ambiguous URL under `--profile` without the flag still fails.
    func testTheProfileIsNeverDroppedByTheHelper() async {
        do {
            _ = try await resolve(["--profile", "NoSuchProfile", "--url", "w1.example", "--first-match"], on: FakeSafari())
            XCTFail("a profile with no window must not be read through another profile's tab")
        } catch SafariBrowserError.documentNotFound {
        } catch { XCTFail("unexpected \(error)") }
        do {
            _ = try await resolve(["--profile", "個人", "--url", "w1.example"], on: FakeSafari())
            XCTFail("an ambiguous URL under --profile still fails without --first-match")
        } catch SafariBrowserError.ambiguousWindowMatch {
        } catch { XCTFail("unexpected \(error)") }
    }

    // MARK: - Tripwire

    /// Every command file that composes `TargetOptions` mentions `firstMatch` (or the helper), so
    /// a new command cannot forget the flag unnoticed. The list of files that do not is the debt
    /// that is known: `documents` is discovery, `exec` handles its own target, and the rest is
    /// tracked in the issue named next to it. A file is removed from the list when it is fixed.
    func testEveryCommandWithATargetMentionsFirstMatchExceptTheKnownOnes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SafariBrowser/Commands")
        let known: Set<String> = ["DocumentsCommand.swift", "ExecCommand.swift"]
        var missing: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() where file.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            guard text.contains("@OptionGroup var target: TargetOptions") else { continue }
            if !(text.contains("firstMatch") || text.contains("resolveFirstMatchOnce")), !known.contains(file) { missing.append(file) }
        }
        XCTAssertEqual(missing, [], "a command with a target that never reads --first-match")
    }
}
