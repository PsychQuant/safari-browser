import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #353: `screenshot` reads the window it resolved by its id, and `open` reveals an existing tab by the id of
/// its window, in one script that checks the tab first.
///
/// Neither test reaches Accessibility, `screencapture` or the running Safari: the capture tests stop at the
/// AppleScript read that precedes the Accessibility match, and the Space of each window is injected.
final class WindowLevelCaptureAndFocusTests: XCTestCase {

    private typealias Fake = WindowLevelFakeSafari

    // MARK: screenshot

    /// What `ScreenshotCommand.run()` does with its target before Accessibility is involved: pin, resolve, and
    /// read the geometry.
    private func geometry(_ flags: [String], fake: Fake) async throws -> String {
        let command = try ScreenshotCommand.parse(flags + ["/tmp/out.png"])
        return try await fake.drive {
            let target = try await command.target.pinWindowAtStart()
            guard let capture = try await ScreenshotCommand.resolveCaptureTarget(target) else {
                throw ValidationError("no explicit target")
            }
            return try await SafariBridge.readCaptureGeometry(
                window: capture.window, missTarget: capture.missTarget, profile: capture.profile)
        }
    }

    // spec-example: screenshot / geometry read by window id
    func testGeometryReadByWindowID() async throws {
        // --window 2: one script reads bounds and title of window id 5822; nothing raises or switches.
        let pinned = Fake()
        let raw = try await geometry(["--window", "2"], fake: pinned)
        XCTAssertEqual(raw, "0,25,1200,900\u{1F}Tab 1")
        let reads = pinned.scripts.filter { $0.contains("bounds of") }
        XCTAssertEqual(reads.count, 1, pinned.transcript)
        XCTAssertTrue(reads[0].contains("set b to bounds of window id 5822"), reads[0])
        XCTAssertTrue(reads[0].contains("set n to name of window id 5822"), reads[0])
        XCTAssertEqual(pinned.scripts.last, reads[0], "the read is the last script before Accessibility")
        XCTAssertFalse(pinned.scripts(afterFirst: Fake.isAnchor).contains(where: Fake.namesAPosition), pinned.transcript)
        for forbidden in ["set index", "activate", "set current tab"] {
            XCTAssertFalse(pinned.scripts.contains { $0.contains(forbidden) }, "\(forbidden):\n\(pinned.transcript)")
        }
        XCTAssertEqual(pinned.actions, [])

        // The current tab found by its URL: the same window id.
        let byURL = Fake()
        _ = try await geometry(["--url", "work.example/a1"], fake: byURL)
        XCTAssertTrue(byURL.scripts.last?.contains("bounds of window id 5822") == true, byURL.transcript)
        XCTAssertFalse(byURL.scripts(afterFirst: Fake.isEnumeration).contains(where: Fake.namesAPosition), byURL.transcript)

        // A background tab: refused before any geometry is read.
        let background = Fake()
        do {
            _ = try await geometry(["--url", "work.example/a2"], fake: background)
            XCTFail("a background tab cannot be captured")
        } catch SafariBrowserError.backgroundTabNotCapturable {
            XCTAssertEqual(background.scripts.count, 1, background.transcript)
            XCTAssertFalse(background.scripts.contains { $0.contains("bounds of") })
        }

        // The pinned window closes after the id was read: the miss names `--window 2`, and nothing is read
        // from the window now in position 2.
        let closing = Fake()
        closing.after(script: 2) { $0.removeAll { $0.id == 5822 } }
        do {
            _ = try await geometry(["--window", "2"], fake: closing)
            XCTFail("the window is gone")
        } catch SafariBrowserError.documentNotFound(let pattern, _) {
            XCTAssertEqual(pattern, "window 2 (window id 5822 at command start)")
            XCTAssertFalse(closing.scripts.contains { $0.contains("bounds of window 2") || $0.contains("window id 6933") }, closing.transcript)
        }
    }

    func testAnUnpinnedWindowNumberKeepsTheTwoPositionalReads() async throws {
        let fake = Fake()
        fake.anchorDoesNotAnswer = true
        _ = try await geometry(["--window", "2"], fake: fake)
        XCTAssertEqual(fake.diagnostics.count, 1, "\(fake.diagnostics)")
        XCTAssertEqual(fake.scripts.suffix(2).map { $0.contains("window 2") }, [true, true], fake.transcript)
        XCTAssertEqual(fake.scripts.suffix(2).first, SafariBridge.windowExistenceValidationScript(windowIndex: 2))
        XCTAssertTrue(fake.scripts.last?.contains("set b to bounds of window 2") == true, fake.transcript)
    }

    func testNoTargetingFlagResolvesNoCaptureTarget() async throws {
        let fake = Fake()
        let command = try ScreenshotCommand.parse(["/tmp/out.png"])
        let capture = try await fake.drive { () -> ScreenshotCommand.CaptureTarget? in
            let target = try await command.target.pinWindowAtStart()
            return try await ScreenshotCommand.resolveCaptureTarget(target)
        }
        XCTAssertNil(capture)
        XCTAssertEqual(fake.scripts, [])
    }

    // MARK: open: reveal an existing tab

    private static let sameSpace = SafariBridge.SpaceProbe(current: { 1 }, ofWindow: { _ in 1 })
    /// Window 3 is on another Space.
    private static let window3Elsewhere = SafariBridge.SpaceProbe(current: { 1 }, ofWindow: { $0 == 3 ? 2 : 1 })

    private struct Reveal {
        let error: Error?
        let warnings: [String]
        /// The scripts sent after the enumeration that found the tab.
        let scripts: [String]
    }

    private func reveal(_ url: String, fake: Fake, spaces: SafariBridge.SpaceProbe) async -> Reveal {
        var warnings: [String] = []
        var failure: Error?
        do {
            try await fake.drive {
                guard let match = try await SafariBridge.findExactMatchingTab(url: url) else {
                    throw ValidationError("no tab shows \(url)")
                }
                try await SafariBridge.focusExistingTab(
                    window: match.window, tabInWindow: match.tabInWindow, isCurrent: match.isCurrent,
                    url: url, windowID: match.windowID,
                    warnWriter: { warnings.append($0) }, spaces: spaces)
            }
        } catch {
            failure = error
        }
        return Reveal(error: failure, warnings: warnings, scripts: fake.scripts(afterFirst: Fake.isEnumeration))
    }

    private func assertOrder(_ needles: [String], in text: String, file: StaticString = #filePath, line: UInt = #line) {
        var cursor = text.startIndex
        for needle in needles {
            guard let range = text.range(of: needle, range: cursor..<text.endIndex) else {
                return XCTFail("missing, or out of order: \(needle)\n\(text)", file: file, line: line)
            }
            cursor = range.upperBound
        }
    }

    // spec-example: human-emulation / focus-existing by window id
    func testFocusExistingByWindowID() async {
        // Layer 1: the front tab of the front window.
        let front = Fake()
        let layer1 = await reveal("https://home.example/1", fake: front, spaces: Self.sameSpace)
        XCTAssertNil(layer1.error)
        XCTAssertEqual(layer1.scripts, [])

        // Layer 2: a background tab of the front window. One script; no raise.
        let sameWindow = Fake()
        let layer2 = await reveal("https://home.example/3", fake: sameWindow, spaces: Self.sameSpace)
        XCTAssertNil(layer2.error)
        XCTAssertEqual(layer2.scripts.count, 1, sameWindow.transcript)
        assertOrder(["set _t to tab 3 of window id 4711", "is not equal to \"https://home.example/3\"", "SB_TARGET_CHANGED",
                     "set current tab of window id 4711 to _t"], in: layer2.scripts.first ?? "")
        XCTAssertFalse(layer2.scripts.contains { $0.contains("set index") || $0.contains("activate") }, sameWindow.transcript)
        XCTAssertEqual(layer2.warnings, [])

        // Layer 3: a background tab of another window on this Space. One script: check, switch, raise, activate.
        let otherWindow = Fake()
        let layer3 = await reveal("https://work.example/a2", fake: otherWindow, spaces: Self.sameSpace)
        XCTAssertNil(layer3.error)
        XCTAssertEqual(layer3.scripts.count, 1, otherWindow.transcript)
        assertOrder(["set _t to tab 2 of window id 5822", "SB_TARGET_CHANGED", "set current tab of window id 5822 to _t",
                     "set index of window id 5822 to 1", "activate"], in: layer3.scripts.first ?? "")
        XCTAssertFalse(layer3.scripts.contains(where: Fake.namesAPosition), otherWindow.transcript)
        XCTAssertEqual(layer3.warnings.count, 1)

        // Layer 3, the tab is already current in its window: no tab switch.
        let currentElsewhere = Fake()
        let layer3Current = await reveal("https://work.example/b1", fake: currentElsewhere, spaces: Self.sameSpace)
        XCTAssertNil(layer3Current.error)
        XCTAssertEqual(layer3Current.scripts.count, 1, currentElsewhere.transcript)
        assertOrder(["set _t to tab 1 of window id 6933", "SB_TARGET_CHANGED", "set index of window id 6933 to 1", "activate"],
                    in: layer3Current.scripts.first ?? "")
        XCTAssertFalse(layer3Current.scripts.first?.contains("set current tab") == true)

        // Layer 4: the window is on another Space. It is not named at all; a new tab opens here.
        let elsewhere = Fake()
        let layer4 = await reveal("https://work.example/b1", fake: elsewhere, spaces: Self.window3Elsewhere)
        XCTAssertNil(layer4.error)
        XCTAssertFalse(layer4.scripts.isEmpty, "a new tab is opened")
        XCTAssertFalse(layer4.scripts.contains { $0.contains("window id 6933") }, elsewhere.transcript)
        XCTAssertEqual(layer4.warnings.count, 1)

        // The tab moved before it was revealed: nothing changes, and no new tab is opened instead.
        let moved = Fake()
        moved.after(script: 1) { $0[1].tabs[1] = "https://other.example/" }
        let stopped = await reveal("https://work.example/a2", fake: moved, spaces: Self.sameSpace)
        guard case SafariBrowserError.targetChangedBeforeActing? = stopped.error else {
            return XCTFail("expected targetChangedBeforeActing, got \(String(describing: stopped.error))\n\(moved.transcript)")
        }
        XCTAssertEqual(stopped.scripts.count, 1, moved.transcript)
        XCTAssertFalse(stopped.scripts.contains { $0.contains("make new") }, moved.transcript)
        XCTAssertEqual(moved.actions, [])
    }

    // spec-example: non-interference / gradient actions by window id
    func testGradientActionsByWindowID() async {
        func outcome(_ url: String, spaces: SafariBridge.SpaceProbe, prepare: (Fake) -> Void = { _ in })
            async -> (actions: [Fake.Action], warnings: [String], error: Error?, scripts: [String]) {
            let fake = Fake()
            prepare(fake)
            let result = await reveal(url, fake: fake, spaces: spaces)
            return (fake.actions, result.warnings, result.error, result.scripts)
        }
        let layer1 = await outcome("https://home.example/1", spaces: Self.sameSpace)
        XCTAssertEqual(layer1.actions, [])
        XCTAssertEqual(layer1.warnings, [])

        let layer2 = await outcome("https://home.example/3", spaces: Self.sameSpace)
        XCTAssertEqual(layer2.actions, [.madeCurrent(windowID: 4711, tab: 3)])
        XCTAssertEqual(layer2.warnings, [], "a tab switch inside the front window is silent")

        let layer3 = await outcome("https://work.example/a2", spaces: Self.sameSpace)
        XCTAssertEqual(layer3.actions, [.madeCurrent(windowID: 5822, tab: 2), .raised(windowID: 5822), .activated])
        XCTAssertEqual(layer3.warnings.count, 1)
        XCTAssertTrue(layer3.warnings.first?.hasPrefix("warning:") == true, "\(layer3.warnings)")

        let layer4 = await outcome("https://work.example/b1", spaces: Self.window3Elsewhere)
        XCTAssertFalse(layer4.actions.contains { if case .raised = $0 { return true }; if case .madeCurrent = $0 { return true }; return false },
                       "\(layer4.actions)")
        XCTAssertEqual(layer4.warnings.count, 1)
        XCTAssertTrue(layer4.warnings.first?.hasPrefix("note:") == true, "\(layer4.warnings)")
        XCTAssertFalse(layer4.scripts.isEmpty, "a new tab opens in the front window")

        let moved = await outcome("https://work.example/a2", spaces: Self.sameSpace) {
            $0.after(script: 1) { $0[1].tabs[1] = "https://other.example/" }
        }
        XCTAssertEqual(moved.actions, [], "no tab is made current and no window is raised")
        guard case SafariBrowserError.targetChangedBeforeActing? = moved.error else {
            return XCTFail("expected targetChangedBeforeActing, got \(String(describing: moved.error))")
        }
    }

    func testAWindowThatClosedBeforeItWasRevealedIsAMissNotANewTab() async {
        let fake = Fake()
        fake.after(script: 1) { $0.removeAll { $0.id == 5822 } }
        let result = await reveal("https://work.example/a2", fake: fake, spaces: Self.sameSpace)
        guard case SafariBrowserError.documentNotFound? = result.error else {
            return XCTFail("expected documentNotFound, got \(String(describing: result.error))\n\(fake.transcript)")
        }
        XCTAssertEqual(fake.actions, [])
        XCTAssertFalse(fake.scripts.contains { $0.contains("make new") }, fake.transcript)
    }

    func testAMatchWithoutAWindowIDFallsBackToThePosition() async throws {
        // The match carries the id the enumeration read…
        let windows = try SafariBridge.decodeWindowEnumeration(FakeEnumeration.sourceForm(Fake.threeWindows.map {
            .titledTabs(id: $0.id, profile: nil, urls: $0.tabs, currentTab: $0.current)
        }))
        XCTAssertEqual(SafariBridge.findExactMatch(url: "https://work.example/a2", in: windows)?.windowID, 5822)
        // …and without one, the reveal names the window by its position: the switch first, because after the
        // raise `window 2` is another window.
        let fake = Fake()
        try await fake.drive {
            try await SafariBridge.focusExistingTab(
                window: 2, tabInWindow: 2, isCurrent: false, url: "https://work.example/a2",
                windowID: nil, warnWriter: { _ in }, spaces: Self.sameSpace)
        }
        XCTAssertEqual(fake.actions, [.madeCurrent(windowID: 5822, tab: 2), .raised(windowID: 5822), .activated])
    }
}
