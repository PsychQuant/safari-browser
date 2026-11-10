import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #354: `TargetOptions.pinWindowAtStart()` — `--window N` becomes `--window-id W` once at command start,
/// positional when the id cannot be read — and the wording of a miss on a pinned window.
final class WindowPinTests: XCTestCase {

    private func pin(_ args: [String], on fake: PinFakeSafari) async throws -> TargetOptions {
        let options = try TargetOptions.parse(args)
        return try await fake.drive { try await options.pinWindowAtStart() }
    }

    // MARK: 1.1 the private option and `.windowID(…, pinnedFrom:)`

    func testThePinnedFromWindowRidesOnTheWindowIDTarget() throws {
        let options = try TargetOptions.parse(["--window-id", "4711", "--pinned-from-window", "2"])
        guard case .windowID(4711, nil, pinnedFrom: 2) = options.resolve() else {
            return XCTFail("got \(options.resolve())")
        }
        let tabbed = try TargetOptions.parse(["--window-id", "4711", "--tab-in-window", "3", "--pinned-from-window", "2"])
        guard case .windowID(4711, 3, pinnedFrom: 2) = tabbed.resolve() else { return XCTFail("got \(tabbed.resolve())") }
        XCTAssertEqual(ScriptInterpreter.encodeTargetArgs(options), ["--window-id", "4711", "--pinned-from-window", "2"])
    }

    func testThePinnedFromWindowNeedsAWindowIDAndAPositiveNumber() {
        XCTAssertThrowsError(try TargetOptions.parse(["--pinned-from-window", "2"]))
        XCTAssertThrowsError(try TargetOptions.parse(["--window", "2", "--pinned-from-window", "2"]))
        XCTAssertThrowsError(try TargetOptions.parse(["--window-id", "4711", "--pinned-from-window", "0"]))
    }

    func testThePinnedFromWindowIsNotInTheHelp() {
        XCTAssertFalse(GetURL.helpMessage().contains("pinned-from-window"))
        XCTAssertTrue(GetURL.helpMessage().contains("--window-id"))
    }

    /// The MCP tool schemas are built from the parser's own metadata, which does know the option; the catalog keeps
    /// only what `--help` displays.
    func testThePinnedFromWindowIsNotInTheMCPToolSchemas() throws {
        let metadata = SafariBrowser._dumpHelp()
        XCTAssertTrue(metadata.contains("pinned-from-window"), "the metadata lists the option, so the catalog is what hides it")
        let catalog = try MCPToolCatalog(metadata: Data(metadata.utf8))
        XCTAssertFalse(catalog.tools.isEmpty)
        for tool in catalog.tools {
            let schema = String(decoding: try tool.descriptor.encoded(), as: UTF8.self)
            XCTAssertFalse(schema.contains("pinned"), "\(tool.name): \(schema)")
            XCTAssertFalse(schema.contains("profileChecked"), "\(tool.name): \(schema)")
        }
    }

    // MARK: 1.2 the pin

    func testAWindowNumberBecomesItsIDInOneQuery() async throws {
        let fake = PinFakeSafari()
        let pinned = try await pin(["--window", "2"], on: fake)
        XCTAssertNil(pinned.window)
        XCTAssertEqual(pinned.windowID, 5822)
        XCTAssertEqual(pinned.pinnedFromWindow, 2)
        XCTAssertNil(pinned.tabInWindow)
        XCTAssertEqual(fake.scripts.count, 1, fake.transcript)
        XCTAssertTrue(fake.scripts[0].contains("set _id to id of window 2"), fake.transcript)
        guard case .windowID(5822, nil, pinnedFrom: 2) = pinned.resolve() else { return XCTFail("\(pinned.resolve())") }
    }

    func testAWindowNumberWithATabKeepsTheTabAfterARangeCheck() async throws {
        let fake = PinFakeSafari()
        let pinned = try await pin(["--window", "1", "--tab-in-window", "3"], on: fake)
        XCTAssertEqual(pinned.windowID, 4711)
        XCTAssertEqual(pinned.tabInWindow, 3)
        XCTAssertEqual(fake.scripts.count, 1)
        XCTAssertTrue(fake.scripts[0].contains("count of tabs of window id _id"), fake.transcript)
    }

    /// The id cannot be read: the copy stays positional, so the first step fails (or runs) exactly as before.
    func testAnUnreadableIDKeepsThePosition() async throws {
        let empty: [PinFakeSafari.Window] = [(4711, "Home", ["https://home.example/1"]), (5822, "Home", [])]
        for (label, args, windows) in [
            ("no such window", ["--window", "9"], PinFakeSafari.threeWindows),
            ("a tab outside the window", ["--window", "1", "--tab-in-window", "9"], PinFakeSafari.threeWindows),
            ("tab 3 of a two-tab window", ["--window", "2", "--tab-in-window", "3"], PinFakeSafari.threeWindows),
            ("a window with no tab", ["--window", "2"], empty),
            ("no window at all", ["--window", "1"], []),
        ] as [(String, [String], [PinFakeSafari.Window])] {
            let fake = PinFakeSafari(windows: windows)
            let options = try TargetOptions.parse(args)
            let pinned = try await fake.drive { try await options.pinWindowAtStart() }
            XCTAssertEqual(pinned.window, options.window, label)
            XCTAssertNil(pinned.windowID, label)
            XCTAssertNil(pinned.pinnedFromWindow, label)
            XCTAssertEqual(pinned.tabInWindow, options.tabInWindow, label)
        }
    }

    func testWithAProfileTheIDComesFromOneProfileScopedEnumeration() async throws {
        let fake = PinFakeSafari()
        let pinned = try await pin(["--window", "2", "--profile", "Work"], on: fake)
        XCTAssertEqual(pinned.windowID, 6933, "the second Work window, which is Safari's window 3")
        XCTAssertEqual(pinned.profile, "Work")
        XCTAssertEqual(pinned.pinnedFromWindow, 2)
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isEnumeration).count, 1)
        XCTAssertFalse(fake.scripts.contains(where: PinFakeSafari.isIndexAnchor),
                       "Safari's own window number counts every profile's windows:\n\(fake.transcript)")

        let withTab = try await pin(["--window", "1", "--tab-in-window", "2", "--profile", "Work"], on: PinFakeSafari())
        XCTAssertEqual(withTab.windowID, 5822)
        XCTAssertEqual(withTab.tabInWindow, 2)
    }

    func testWithAProfileAMissOrALegacyRecordKeepsThePosition() async throws {
        let missing = try await pin(["--window", "3", "--profile", "Work"], on: PinFakeSafari())
        XCTAssertEqual(missing.window, 3)
        XCTAssertNil(missing.windowID)

        let legacy = PinFakeSafari()
        legacy.withoutIDs = true
        let positional = try await pin(["--window", "1", "--profile", "Work"], on: legacy)
        XCTAssertEqual(positional.window, 1)
        XCTAssertNil(positional.windowID)
    }

    func testEveryOtherFlagSetIsLeftAloneAndSendsNothing() async throws {
        for args in [[], ["--url", "work"], ["--url-exact", "x"], ["--url-endswith", "/a1"], ["--url-regex", "a"],
                     ["--document", "2"], ["--tab", "2"], ["--window-id", "4711"], ["--window-id", "4711", "--tab-in-window", "2"],
                     ["--profile", "Work"]] {
            let fake = PinFakeSafari()
            let options = try TargetOptions.parse(args)
            let pinned = try await fake.drive { try await options.pinWindowAtStart() }
            XCTAssertEqual(ScriptInterpreter.encodeTargetArgs(pinned), ScriptInterpreter.encodeTargetArgs(options), "\(args)")
            XCTAssertEqual(fake.scripts, [], "\(args): \(fake.transcript)")
        }
    }

    // MARK: 1.3 a pinned window that closes mid-command

    func testAMissOnAPinnedWindowNamesTheWindowNumberTheUserTyped() async throws {
        let fake = PinFakeSafari()
        fake.closeAfterScripts = (1, 5822)
        let error = await fake.run(GetURL.self, ["--window", "2"])
        guard case SafariBrowserError.documentNotFound(let pattern, let available)? = error else {
            return XCTFail("expected a targeting miss, got \(String(describing: error))\n\(fake.transcript)")
        }
        XCTAssertEqual(pattern, "window 2 (window id 5822 at command start)")
        XCTAssertEqual(available.count, 1)
        XCTAssertTrue(available[0].contains("no longer open"), "\(available)")
        XCTAssertFalse(available.joined().contains("https://"), "no other window's tab is listed: \(available)")
        let after = fake.scripts(afterFirst: PinFakeSafari.isIndexAnchor)
        XCTAssertFalse(after.contains { $0.contains("window 2") }, fake.transcript)
        XCTAssertFalse(fake.scripts.contains { $0.contains("front window") }, fake.transcript)
    }

    func testAMissOnAPinnedTabNamesTheWindowNumberAndTheTab() async throws {
        let fake = PinFakeSafari()
        fake.closeAfterScripts = (1, 4711)
        let error = await fake.run(GetURL.self, ["--window", "1", "--tab-in-window", "3"])
        guard case SafariBrowserError.documentNotFound(let pattern, _)? = error else {
            return XCTFail("expected a targeting miss, got \(String(describing: error))")
        }
        XCTAssertEqual(pattern, "window 1 tab 3 (window id 4711 at command start)")
    }

    /// Under `--profile` the pin's enumeration is the profile check; the window closing afterwards is found by the
    /// id-addressed read, and the miss lists that profile's tabs labelled with their window ids (#362's listing),
    /// with the `--window-id` hint. One enumeration before the read, one for the listing — as before #354.
    func testAMissOnAPinnedWindowWithAProfileListsTheProfilesTabsByID() async throws {
        let fake = PinFakeSafari()
        fake.closeAfterScripts = (1, 6933)
        let error = await fake.run(GetURL.self, ["--window", "2", "--profile", "Work"])
        guard case SafariBrowserError.documentNotFound(let pattern, let available)? = error else {
            return XCTFail("expected a targeting miss, got \(String(describing: error))\n\(fake.transcript)")
        }
        XCTAssertEqual(pattern, "window 2 (window id 6933 at command start)")
        XCTAssertEqual(available, ["window 2 tab 1 (window id 5822): https://work.example/a1",
                                   "window 2 tab 2 (window id 5822): https://work.example/a2"])
        let message = (error as? SafariBrowserError)?.localizedDescription ?? ""
        XCTAssertTrue(message.contains("--window-id W"), message)
        XCTAssertFalse(message.contains("target one with --window N"), message)
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isEnumeration).count, 2, fake.transcript)
    }

    /// The pure producers: a `--window-id` the user typed keeps its own wording.
    func testTheWordingOfAnUnpinnedWindowIDIsUnchanged() {
        XCTAssertEqual(SafariBridge.windowIDDescription(4711, tab: nil, pinnedFrom: nil), "window id 4711")
        XCTAssertEqual(SafariBridge.windowIDDescription(4711, tab: 2, pinnedFrom: nil), "window id 4711 tab 2")
        XCTAssertEqual(SafariBridge.windowIDMissNote(pinnedFrom: nil, tabs: true), "(no such window or tab)")
        XCTAssertThrowsError(try SafariBridge.checkWindowID(4711, profile: nil, in: [])) { error in
            guard case SafariBrowserError.documentNotFound(let pattern, let available) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(pattern, "window id 4711")
            XCTAssertEqual(available, ["(no such window)"])
        }
        XCTAssertThrowsError(try SafariBridge.checkWindowID(4711, profile: nil, in: [], pinnedFrom: 2)) { error in
            guard case SafariBrowserError.documentNotFound(let pattern, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(pattern, "window 2 (window id 4711 at command start)")
        }
    }

    /// `resolveProfileScoped` collapses a pinned window without a tab to `.windowID` and keeps where it came from:
    /// the N, and the profile the pin checked the id against (the pin's enumeration is the only one).
    func testTheProfileScopedResolutionKeepsThePinnedFromWindow() async throws {
        let fake = PinFakeSafari()
        let pinned = try await pin(["--window", "1", "--profile", "Work"], on: fake)
        let scoped = try await fake.drive { try await pinned.resolveProfileScoped() }
        guard case .windowID(5822, nil, let from?) = scoped else { return XCTFail("\(scoped)") }
        XCTAssertEqual(from, SafariBridge.PinnedFrom(window: 1, checkedProfile: "Work"))
        XCTAssertEqual(fake.scripts.filter(PinFakeSafari.isEnumeration).count, 1, fake.transcript)
    }
}
