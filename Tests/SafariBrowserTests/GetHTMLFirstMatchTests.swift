import Foundation
import XCTest
@testable import SafariBrowser

/// #231: `get html <selector> --url <pattern> --first-match` handed the target to the bridge
/// unresolved, and the reads that follow take no `firstMatch`, so an ambiguous pattern threw
/// although the flag was given — the defect `get text` had until #220. `save-image` resolved its
/// target the same way. All three now go through `TargetOptions.resolveFirstMatchOnce`.
final class GetHTMLFirstMatchTests: XCTestCase, @unchecked Sendable {
    typealias FakeSafari = ExecSharedTargetTests.Fake

    private func runGetHTML(_ args: [String], on fake: FakeSafari) async throws {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let command = try GetHTML.parse(args)
        try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                try await command.run()
            }
        }
    }

    func testAnAmbiguousURLStillFailsWithoutTheFlag() async {
        do {
            try await runGetHTML(["#sel", "--url", "w1.example"], on: FakeSafari())
            XCTFail("an ambiguous --url must fail without --first-match")
        } catch SafariBrowserError.ambiguousWindowMatch {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFirstMatchTakesTheFirstTabAndResolvesOnce() async throws {
        let fake = FakeSafari()
        try await runGetHTML(["#sel", "--url", "w1.example", "--first-match"], on: fake)
        XCTAssertEqual(fake.enumerations, 1, "one resolution for the whole command:\n\(fake.scripts.joined(separator: "\n---\n"))")
    }

    // MARK: - The helper, and who uses it

    private func resolve(_ args: [String], on fake: FakeSafari, warnings: NSMutableArray) async throws -> SafariBridge.TargetDocument {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let command = try GetHTML.parse(["#sel"] + args)
        return try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ try fake.respond($0) }) {
                try await command.target.resolveFirstMatchOnce()
            }
        }
    }

    /// `--first-match` without `--profile` resolves once, to a concrete tab; every other
    /// combination is what `resolveProfileScoped` returned before.
    func testTheHelperResolvesOnceOnlyForFirstMatchWithoutAProfile() async throws {
        let first = FakeSafari()
        let resolved = try await resolve(["--url", "w1.example", "--first-match"], on: first, warnings: NSMutableArray())
        guard case .resolvedTab = resolved else { return XCTFail("expected a concrete tab, got \(resolved)") }
        XCTAssertEqual(first.enumerations, 1)

        let plain = FakeSafari()
        let unresolved = try await resolve(["--url", "w1.example"], on: plain, warnings: NSMutableArray())
        guard case .urlMatch = unresolved else { return XCTFail("without the flag the target stays as given, got \(unresolved)") }
        XCTAssertEqual(plain.enumerations, 0, "nothing is resolved until a read needs it")
    }

    /// The three commands take their target from the helper; putting `resolveProfileScoped` back
    /// in any of them brings the defect back without failing a behavioural test, so it is pinned.
    func testGetTextGetHTMLAndSaveImageResolveTheirTargetThroughTheHelper() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SafariBrowser/Commands")
        let get = try String(contentsOf: root.appendingPathComponent("GetCommand.swift"), encoding: .utf8)
        let save = try String(contentsOf: root.appendingPathComponent("SaveImageCommand.swift"), encoding: .utf8)
        XCTAssertEqual(get.components(separatedBy: "target.resolveFirstMatchOnce()").count - 1, 2, "GetText and GetHTML")
        XCTAssertEqual(save.components(separatedBy: "target.resolveFirstMatchOnce()").count - 1, 1, "save-image")
        XCTAssertFalse(get.contains("target.resolveProfileScoped()") || save.contains("target.resolveProfileScoped()"))
    }
}
