import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #231: a command whose target came from `resolveProfileScoped` (or `resolve()`) handed the
/// target to the bridge unresolved, and the reads that follow take no `firstMatch`, so an
/// ambiguous `--url` threw although `--first-match` was given — the defect `get text` had until
/// #220. The `document-targeting` requirement says every command that composes `TargetOptions`
/// honours the flag. `get text`, `get html`, `save-image` and `upload --js` take their target from
/// `TargetOptions.resolveFirstMatchOnce`; `cookies get`, `console` and `errors` pass the flag to
/// the bridge.
///
/// The fake Safari (`ExecSharedTargetTests.Fake`) has two windows of three tabs:
/// `https://w1.example/1…3` and `https://w2.example/1…3`, all in the profile 個人.
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

    /// What the body writes to standard error, through the process's real descriptor (the warning
    /// goes to `TargetOptions.stderrWarnWriter`, the default the commands use).
    private func capturedStderr(_ body: () async -> Void) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stderr-\(UUID().uuidString)")
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd); try? FileManager.default.removeItem(at: url) }
        fflush(nil)
        let saved = dup(STDERR_FILENO)
        defer { close(saved) }
        dup2(fd, STDERR_FILENO)
        await body()
        fflush(nil)
        dup2(saved, STDERR_FILENO)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Every command that reads through the target

    private func fixtureFile(bytes: Int = 1) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("first-match-\(UUID().uuidString).txt").path
        try Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// One case per way a command reaches its read: a command and the arguments before `--url`.
    private func cases(upload: String, save: String) -> [(String, (FakeSafari, [String]) async throws -> Void)] {
        [
            ("get text", { try await self.run(GetText.self, ["#sel"] + $1, on: $0) }),
            ("get html", { try await self.run(GetHTML.self, ["#sel"] + $1, on: $0) }),
            ("save-image", { try await self.run(SaveImageCommand.self, [save, "--element", "svg"] + $1, on: $0) }),
            ("upload --js", { try await self.run(UploadCommand.self, ["input", upload, "--js"] + $1, on: $0) }),
            ("upload without Accessibility", { fake, args in
                var command = try UploadCommand.parse(["input", upload] + args)
                try await self.inContext(fake) { try await command.run(accessibilityProbe: { false }) }
            }),
            ("cookies get NAME", { try await self.run(CookiesGet.self, ["session"] + $1, on: $0) }),
            ("cookies get --json", { try await self.run(CookiesGet.self, ["--json"] + $1, on: $0) }),
            ("cookies get", { try await self.run(CookiesGet.self, $1, on: $0) }),
            ("console", { try await self.run(ConsoleCommand.self, $1, on: $0) }),
            ("console --start", { try await self.run(ConsoleCommand.self, ["--start"] + $1, on: $0) }),
            ("console --clear", { try await self.run(ConsoleCommand.self, ["--clear"] + $1, on: $0) }),
            ("errors", { try await self.run(ErrorsCommand.self, $1, on: $0) }),
            ("errors --start", { try await self.run(ErrorsCommand.self, ["--start"] + $1, on: $0) }),
            ("errors --clear", { try await self.run(ErrorsCommand.self, ["--clear"] + $1, on: $0) }),
        ]
    }

    /// Each command over the fake Safari: without the flag an ambiguous `--url` fails; with it the
    /// ambiguity is gone, the read goes to the FIRST matching tab (window id 101, tab 1), and the
    /// one warning the requirement asks for reaches standard error. What happens after the read
    /// (the fake's canned answers) is not under test, so a later error is fine.
    func testEveryReadCommandHonoursFirstMatchAtTargetResolution() async throws {
        let upload = try fixtureFile()
        defer { try? FileManager.default.removeItem(atPath: upload) }
        let save = FileManager.default.temporaryDirectory.appendingPathComponent("save-image-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: save) }
        for (label, drive) in cases(upload: upload, save: save) {
            do {
                try await drive(FakeSafari(), ["--url", "w1.example"])
                XCTFail("\(label): an ambiguous --url must fail without --first-match")
            } catch SafariBrowserError.ambiguousWindowMatch {
            } catch {
                XCTFail("\(label): expected ambiguousWindowMatch without the flag, got \(error)")
            }
            let fake = FakeSafari()
            let stderr = try await capturedStderr {
                do { try await drive(fake, ["--url", "w1.example", "--first-match"]) }
                catch SafariBrowserError.ambiguousWindowMatch { XCTFail("\(label): --first-match was not honoured") }
                catch { /* a later failure of the fake's canned answers is fine */ }
            }
            let transcript = fake.scripts.joined(separator: "\n---\n")
            XCTAssertTrue(fake.scripts.contains { $0.contains("do JavaScript") && $0.contains("tab 1 of window id 101") },
                          "\(label): the read must go to the first matching tab:\n\(transcript)")
            XCTAssertEqual(stderr.components(separatedBy: "--first-match resolved").count - 1, 1,
                           "\(label): exactly one multi-match warning on stderr, got:\n\(stderr)")
        }
    }

    /// `get html` end to end: one resolution for the whole command.
    func testGetHTMLResolvesOnce() async throws {
        let fake = FakeSafari()
        _ = try await capturedStderr { try? await self.run(GetHTML.self, ["#sel", "--url", "w1.example", "--first-match"], on: fake) }
        XCTAssertEqual(fake.enumerations, 1, "one resolution for the whole command:\n\(fake.scripts.joined(separator: "\n---\n"))")
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

    /// `--first-match` on a URL-pattern target without `--profile`: one enumeration, a concrete tab
    /// that is the FIRST match, and exactly one warning that lists the candidates — for every
    /// URL-matching flag that can match several tabs.
    func testTheHelperResolvesAURLTargetOnceToTheFirstMatchWithOneWarning() async throws {
        for args in [["--url", "w1.example"], ["--url-endswith", "/1"], ["--url-regex", "example/[0-9]"]] {
            let fake = FakeSafari()
            let warnings = WarningLog()
            let resolved = try await resolve(args + ["--first-match"], on: fake, warnings: warnings)
            guard case .resolvedTab(let windowID, let tab, _, _) = resolved else { return XCTFail("\(args): expected a concrete tab, got \(resolved)") }
            XCTAssertEqual(windowID, 101, "\(args)")
            XCTAssertEqual(tab, 1, "\(args): the first match")
            XCTAssertEqual(fake.enumerations, 1, "\(args)")
            XCTAssertEqual(warnings.all.count, 1, "\(args): \(warnings.all)")
            // Without the flag nothing is resolved here; the ambiguity is raised by the read.
            let unresolved = try await resolve(args, on: FakeSafari())
            guard case .urlMatch = unresolved else { return XCTFail("\(args): expected the target as named, got \(unresolved)") }
        }
        // A unique match with the flag is resolved too (no warning: nothing was ambiguous).
        let quiet = WarningLog()
        let single = try await resolve(["--url-exact", "https://w1.example/2", "--first-match"], on: FakeSafari(), warnings: quiet)
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
    /// ambiguous URL under `--profile` without the flag still fails. With the flag, the injected
    /// writer receives the warning on the profile path as well.
    func testTheProfileIsNeverDroppedByTheHelper() async throws {
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
        let warnings = WarningLog()
        let resolved = try await resolve(["--profile", "個人", "--url", "w1.example", "--first-match"], on: FakeSafari(), warnings: warnings)
        guard case .resolvedTab(_, let tab, _, let profile) = resolved else { return XCTFail("expected a concrete tab, got \(resolved)") }
        XCTAssertEqual(tab, 1)
        XCTAssertEqual(profile, "個人", "the profile is carried by the concrete tab")
        XCTAssertEqual(warnings.all.count, 1, "the injected writer receives the warning on the profile path too: \(warnings.all)")
    }

    // MARK: - Tripwire

    /// Every command STRUCT that composes `TargetOptions` mentions `firstMatch` (or the helpers), so
    /// a new command or subcommand cannot forget the flag unnoticed. It looks at the text of each
    /// struct, not at whole files, and at any property name. It is a shape check, not a proof: it
    /// cannot see a command that mentions the flag and drops it on a later read (the driven test
    /// above is what catches that, and `screenshot` is the known case: #233). The structs listed
    /// do not read it, for the reason and the issue named beside them.
    func testEveryCommandStructWithATargetMentionsFirstMatchExceptTheKnownOnes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SafariBrowser/Commands")
        let known: [String: String] = [
            "DocumentsCommand": "discovery command: it lists every tab and takes no single target",
            "ExecCommand": "resolves the exec-level target itself, per step",
        ]
        let optionGroup = try NSRegularExpression(pattern: #"@OptionGroup var \w+: TargetOptions"#)
        var missing: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() where file.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            var structs = text.components(separatedBy: "\nstruct ")
            structs.removeFirst()
            for block in structs {
                let name = String(block.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                guard optionGroup.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)) != nil else { continue }
                if block.contains("firstMatch") || block.contains("resolveFirstMatchOnce") { continue }
                if known[name] == nil { missing.append("\(file): \(name)") }
            }
        }
        XCTAssertEqual(missing, [], "a command struct with a target that never reads --first-match")
    }
}
