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
            guard let capture = try await command.resolveCapture().capture else {
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

    /// `run()` reads the page (`--full`) through the options `resolveCapture()` returns, so they must be the
    /// pinned ones: `--window 2` has become the window's id.
    func testResolveCaptureReturnsThePinnedOptions() async throws {
        let fake = Fake()
        let command = try ScreenshotCommand.parse(["--window", "2", "/tmp/out.png"])
        let resolved = try await fake.drive { try await command.resolveCapture() }
        XCTAssertNil(resolved.target.window)
        XCTAssertEqual(resolved.target.windowID, 5822)
        XCTAssertEqual(resolved.capture?.window, .id(5822))
        XCTAssertTrue(fake.scripts.first.map(Fake.isAnchor) == true, fake.transcript)
    }

    /// A session a test can pass `requireAvailable()` with.
    private static let session = GUISession(readDictionary: { ["CGSSessionScreenIsLocked": false] })

    /// Runs `ScreenshotCommand.captureWindow`, the function `run()` starts with, with `received` standing in
    /// for Accessibility: it records the window the capture resolver is handed.
    private func captureWindow(_ flags: [String], fake: Fake) async throws
        -> (received: [SafariBridge.ActingWindow?], capture: ScreenshotCommand.CaptureTarget?, options: TargetOptions) {
        let command = try ScreenshotCommand.parse(flags + ["/tmp/out.png"])
        var received: [SafariBridge.ActingWindow?] = []
        let result = try await fake.drive {
            try await command.captureWindow(session: Self.session, resolve: { window in
                received.append(window)
                return (cgID: "77", axWindow: nil)
            })
        }
        XCTAssertEqual(result.cgID, "77")
        return (received, result.capture, result.target)
    }

    /// `run()` cannot be driven in a test (Screen Recording, Accessibility), but the function it starts with
    /// can: the window the resolution found is the window the capture resolver is handed.
    func testTheCaptureResolverIsHandedTheResolvedWindow() async throws {
        let pinned = try await captureWindow(["--window", "2"], fake: Fake())
        XCTAssertEqual(pinned.received, [.id(5822)])
        let byURL = try await captureWindow(["--url", "work.example/a1"], fake: Fake())
        XCTAssertEqual(byURL.received, [.id(5822)])
        let scoped = try await captureWindow(["--profile", "Work"], fake: Fake())
        XCTAssertEqual(scoped.received, [nil], "--profile alone is not a targeting flag for screenshot (#233)")
        let plain = try await captureWindow([], fake: Fake())
        XCTAssertEqual(plain.received, [nil])
        XCTAssertNil(plain.capture)

        // A locked or absent session stops before anything is resolved by Accessibility.
        let command = try ScreenshotCommand.parse(["--window", "2", "/tmp/out.png"])
        var asked = false
        do {
            _ = try await Fake().drive {
                try await command.captureWindow(session: GUISession(readDictionary: { nil }), resolve: { _ in
                    asked = true
                    return (cgID: "77", axWindow: nil)
                })
            }
            XCTFail("no GUI session")
        } catch {
            XCTAssertFalse(asked)
        }
    }

    /// Changes the fake's windows now: the change is applied after one more script, which is sent here.
    private func change(_ fake: Fake, _ body: @escaping (inout [Fake.Window]) -> Void) async throws {
        fake.after(script: fake.scripts.count + 1, body)
        _ = try await fake.drive { try await SafariBridge.runAppleScript("tell application \"Safari\"\nend tell") }
    }

    // spec-example: screenshot / page steps by window id
    func testPageStepsByWindowID() async throws {
        // --window 2: the page steps run in window id 5822, whatever is in position 2 by then.
        let pinnedFake = Fake()
        let pinned = try await captureWindow(["--window", "2"], fake: pinnedFake)
        let pinnedPage = try await pinnedFake.drive { try await ScreenshotCommand.pageTarget(capture: pinned.capture, options: pinned.options) }
        XCTAssertEqual(pinnedPage, .windowID(5822, tabInWindow: nil, pinnedFrom: 2))
        XCTAssertEqual(SafariBridge.resolveDocumentReference(pinnedPage), "document of window id 5822")
        try await change(pinnedFake) { windows in windows.insert(windows.removeLast(), at: 0) }
        XCTAssertEqual(pinnedFake.windows.map(\.id), [6933, 4711, 5822], "window id 5822 is window 3 by then")
        let sent = pinnedFake.scripts.count
        _ = try await pinnedFake.drive {
            try await ScreenshotCommand.pageStep(pinnedPage, capture: pinned.capture) { try await SafariBridge.doJavaScript("window.scrollTo(0,0)", target: pinnedPage) }
        }
        let steps = Array(pinnedFake.scripts[sent...])
        XCTAssertFalse(steps.isEmpty)
        XCTAssertFalse(steps.contains(where: Fake.namesAPosition), steps.joined(separator: "\n---\n"))
        XCTAssertFalse(steps.contains(where: Fake.isEnumeration), "the options are not resolved a second time")
        XCTAssertTrue(steps.contains { $0.contains("do JavaScript") && $0.contains("document of window id 5822") })

        // The current tab found by its URL: that tab of window id 5822, only while it is still current.
        let byURLFake = Fake()
        let byURL = try await captureWindow(["--url", "work.example/a1"], fake: byURLFake)
        let page = try await byURLFake.drive { try await ScreenshotCommand.pageTarget(capture: byURL.capture, options: byURL.options) }
        XCTAssertEqual(page, .anchoredCurrentTab(windowID: 5822, tabInWindow: 1, profile: nil))
        let before = byURLFake.scripts.count
        _ = try await byURLFake.drive {
            try await ScreenshotCommand.pageStep(page, capture: byURL.capture) { try await SafariBridge.doJavaScript("1", target: page) }
        }
        let anchored = Array(byURLFake.scripts[before...])
        XCTAssertEqual(anchored.count, 1, anchored.joined(separator: "\n---\n"))
        XCTAssertTrue(anchored[0].contains("set _w to window id 5822"), anchored[0])
        XCTAssertTrue(anchored[0].contains("(index of current tab of _w) is not 1"), anchored[0])
        XCTAssertFalse(anchored.contains(where: Fake.isEnumeration), "the URL is not matched a second time")

        // Another tab of that window becomes current, or another tab now matches the flag: the step fails;
        // it does not run in whichever tab a second resolution would find.
        let switched = Fake()
        let switchedCapture = try await captureWindow(["--url", "work.example/a1"], fake: switched)
        let switchedPage = try await switched.drive {
            try await ScreenshotCommand.pageTarget(capture: switchedCapture.capture, options: switchedCapture.options)
        }
        try await change(switched) { windows in
            windows[1].current = 2
            windows[2].tabs = ["https://work.example/a1"]
        }
        do {
            _ = try await switched.drive {
                try await ScreenshotCommand.pageStep(switchedPage, capture: switchedCapture.capture) { try await SafariBridge.doJavaScript("1", target: switchedPage) }
            }
            XCTFail("tab 1 of window id 5822 is no longer current")
        } catch SafariBrowserError.anchoredTargetChanged(let target) {
            XCTAssertTrue(target.contains("tab 1 of window id 5822"), target)
            XCTAssertFalse(switched.scripts.contains { $0.contains("window id 6933") && $0.contains("do JavaScript") }, switched.transcript)
        }

        // --first-match with a URL several tabs match: the window is resolved once, with the flag, and the page
        // steps run in that tab without resolving the URL again (a second resolution without the flag would
        // fail as ambiguous after the capture, #233 item 1).
        let ambiguousFake = Fake()
        let ambiguous = try await captureWindow(["--url", "work.example", "--first-match"], fake: ambiguousFake)
        XCTAssertEqual(ambiguous.received, [.id(5822)])
        let ambiguousPage = try await ambiguousFake.drive {
            try await ScreenshotCommand.pageTarget(capture: ambiguous.capture, options: ambiguous.options)
        }
        XCTAssertEqual(ambiguousPage, .anchoredCurrentTab(windowID: 5822, tabInWindow: 1, profile: nil))
        let enumerations = ambiguousFake.scripts.filter(Fake.isEnumeration).count
        _ = try await ambiguousFake.drive {
            try await ScreenshotCommand.pageStep(ambiguousPage, capture: ambiguous.capture) { try await SafariBridge.doJavaScript("1", target: ambiguousPage) }
        }
        XCTAssertEqual(ambiguousFake.scripts.filter(Fake.isEnumeration).count, enumerations, "no second resolution")

        // The window closes: a miss on what was typed.
        let closing = Fake()
        let closingCapture = try await captureWindow(["--window", "2"], fake: closing)
        let closingPage = try await closing.drive {
            try await ScreenshotCommand.pageTarget(capture: closingCapture.capture, options: closingCapture.options)
        }
        try await change(closing) { $0.removeAll { $0.id == 5822 } }
        do {
            _ = try await closing.drive {
                try await ScreenshotCommand.pageStep(closingPage, capture: closingCapture.capture) { try await SafariBridge.doJavaScript("1", target: closingPage) }
            }
            XCTFail("the window is gone")
        } catch SafariBrowserError.documentNotFound(let pattern, _) {
            XCTAssertEqual(pattern, "window 2 (window id 5822 at command start)")
        }

        // A tab target whose window closes: the same document-not-found error, worded for the target that
        // was resolved, not "the tab is no longer current".
        let urlClosing = Fake()
        let urlClosingCapture = try await captureWindow(["--url", "work.example/a1"], fake: urlClosing)
        let urlClosingPage = try await urlClosing.drive {
            try await ScreenshotCommand.pageTarget(capture: urlClosingCapture.capture, options: urlClosingCapture.options)
        }
        try await change(urlClosing) { $0.removeAll { $0.id == 5822 } }
        do {
            _ = try await urlClosing.drive {
                try await ScreenshotCommand.pageStep(urlClosingPage, capture: urlClosingCapture.capture) {
                    try await SafariBridge.doJavaScript("1", target: urlClosingPage)
                }
            }
            XCTFail("the window is gone")
        } catch SafariBrowserError.documentNotFound(let pattern, let entries) {
            XCTAssertTrue(pattern.hasPrefix("window id 5822 tab 1 (matched: "), pattern)
            XCTAssertFalse(pattern.contains("current tab"), "a closed window is not \"no longer the current tab\": \(pattern)")
            XCTAssertFalse(entries.contains { $0.contains("work.example/a1") }, "\(entries)")
        }
        // …and whose tab is gone from a window that is still open.
        let tabClosing = Fake()
        let tabClosingCapture = try await captureWindow(["--url", "work.example/b1"], fake: tabClosing)
        let tabClosingPage = try await tabClosing.drive {
            try await ScreenshotCommand.pageTarget(capture: tabClosingCapture.capture, options: tabClosingCapture.options)
        }
        XCTAssertEqual(tabClosingPage, .anchoredCurrentTab(windowID: 6933, tabInWindow: 1, profile: nil))
        try await change(tabClosing) { $0[2].tabs = [] }
        do {
            _ = try await tabClosing.drive {
                try await ScreenshotCommand.pageStep(tabClosingPage, capture: tabClosingCapture.capture) {
                    try await SafariBridge.doJavaScript("1", target: tabClosingPage)
                }
            }
            XCTFail("the tab is gone")
        } catch SafariBrowserError.documentNotFound(let pattern, _) {
            XCTAssertTrue(pattern.hasPrefix("window id 6933 tab 1"), pattern)
        }

        // No target was resolved: flags this command does not count (#233). The capture is Safari's front
        // window, and the page steps read and scroll that same window; the flags are not resolved for them.
        for flags in [["--profile", "Work"], ["--url-exact", "https://work.example/a2"],
                      ["--url-endswith", "/a2"], ["--url-regex", "a2$"]] {
            let fake = Fake()
            let uncounted = try await captureWindow(flags, fake: fake)
            XCTAssertNil(uncounted.capture, "\(flags)")
            XCTAssertEqual(uncounted.received, [nil], "\(flags)")
            let frontPage = try await fake.drive {
                try await ScreenshotCommand.pageTarget(capture: uncounted.capture, options: uncounted.options)
            }
            XCTAssertEqual(frontPage, .frontWindow, "\(flags): the page steps follow the capture to the front window")
            XCTAssertEqual(fake.scripts, [], "\(flags): nothing is resolved")
        }

        // By position (no flag, or a window number whose id could not be read): the options, as before.
        let plainFake = Fake()
        let plain = try await captureWindow([], fake: plainFake)
        let plainPage = try await plainFake.drive { try await ScreenshotCommand.pageTarget(capture: plain.capture, options: plain.options) }
        XCTAssertEqual(plainPage, .frontWindow)
        let unreadFake = Fake()
        unreadFake.anchorDoesNotAnswer = true
        let unread = try await captureWindow(["--window", "2"], fake: unreadFake)
        XCTAssertEqual(unread.received, [.position(2)])
        XCTAssertNil(unread.capture?.pageTarget)
        let unreadPage = try await unreadFake.drive { try await ScreenshotCommand.pageTarget(capture: unread.capture, options: unread.options) }
        XCTAssertEqual(unreadPage, .windowIndex(2))
    }

    /// `screenshot` never makes a tab current and never raises a window, whatever the target: what it sends
    /// before Accessibility is involved changes nothing in Safari.
    func testScreenshotChangesNothingInSafari() async throws {
        for flags in [["--window", "2"], ["--url", "work.example/a1"], ["--window-id", "5822"],
                      ["--window-id", "5822", "--tab-in-window", "1"], ["--document", "4"]] {
            let fake = Fake()
            let capture = try await captureWindow(flags, fake: fake)
            let window = try XCTUnwrap(capture.capture?.window, "\(flags)")
            let missTarget = try XCTUnwrap(capture.capture?.missTarget)
            _ = try await fake.drive {
                try await SafariBridge.readCaptureGeometry(window: window, missTarget: missTarget, profile: capture.capture?.profile)
            }
            XCTAssertEqual(fake.actions, [], "\(flags)")
            for forbidden in ["set current tab", "set index", "activate"] {
                XCTAssertFalse(fake.scripts.contains { $0.contains(forbidden) }, "\(flags): \(forbidden)\n\(fake.transcript)")
            }
        }
    }

    /// A shape check, not a proof: `run()` starts from `captureWindow()` and never reads the unpinned
    /// `self.target`, and its page steps take their document from `pageTarget(capture:options:)`.
    func testRunStartsFromTheResolvedCapture() throws {
        let source = try String(contentsOfFile: "Sources/SafariBrowser/Commands/ScreenshotCommand.swift", encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "    func run() async throws {"))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.upperBound])
        XCTAssertTrue(body.contains("let (target, capture, windowID, axWindow) = try await captureWindow()"),
                      "run() must take its window from captureWindow()")
        XCTAssertFalse(body.contains("self.target"), "run() must not read the unpinned options")
        XCTAssertFalse(body.contains("resolveWindowForCapture("), "run() must not find the window a second way")
        XCTAssertTrue(body.contains("let docTarget = try await Self.pageTarget(capture: capture, options: target)"))
        XCTAssertFalse(body.contains("target.resolveProfileScoped()"), "the page steps must not resolve the options again")
        XCTAssertFalse(source.contains("target: try await target.resolve"), "no page step resolves the options inline")
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
        let resolved = try await fake.drive { try await command.resolveCapture() }
        XCTAssertNil(resolved.capture)
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

    /// Runs `OpenCommand.revealExisting`, the first step of `open <url>`: the enumeration, the match, and the
    /// hand-over of the window id the enumeration read to the reveal.
    private func reveal(_ url: String, fake: Fake, spaces: SafariBridge.SpaceProbe) async -> Reveal {
        var warnings: [String] = []
        var failure: Error?
        do {
            let found = try await fake.drive {
                try await OpenCommand.revealExisting(url: url, warn: { warnings.append($0) }, spaces: spaces)
            }
            XCTAssertTrue(found, "a tab shows \(url)")
        } catch {
            failure = error
        }
        return Reveal(error: failure, warnings: warnings, scripts: fake.scripts(afterFirst: Fake.isEnumeration))
    }

    func testNoExistingTabIsNotARevealAndSendsNothingMore() async throws {
        let fake = Fake()
        var warnings: [String] = []
        let found = try await fake.drive {
            try await OpenCommand.revealExisting(url: "https://nowhere.example/", warn: { warnings.append($0) }, spaces: Self.sameSpace)
        }
        XCTAssertFalse(found)
        XCTAssertEqual(fake.scripts.count, 1, fake.transcript)
        XCTAssertTrue(fake.scripts.first.map(Fake.isEnumeration) == true)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(fake.actions, [])
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
        XCTAssertEqual(currentElsewhere.actions, [.raised(windowID: 6933), .activated], "tab 1 is current: no tab is made current")

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
        guard case SafariBrowserError.targetChangedBeforeActing(_, let stage)? = stopped.error else {
            return XCTFail("expected targetChangedBeforeActing, got \(String(describing: stopped.error))\n\(moved.transcript)")
        }
        XCTAssertEqual(stage, .beforeAnyAction)
        XCTAssertEqual(stopped.scripts.count, 1, moved.transcript)
        XCTAssertFalse(stopped.scripts.contains { $0.contains("make new") }, moved.transcript)
        XCTAssertEqual(moved.actions, [])
        XCTAssertEqual(stopped.warnings, [], "nothing was raised, so nothing says a window was raised")
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
        XCTAssertEqual(moved.warnings, [], "the warning that a window was raised follows the raise")
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
        XCTAssertEqual(result.warnings, [])
    }

    /// The tab closed (its window is still open) before it was revealed: a miss, not Safari's "invalid index".
    func testATabThatClosedBeforeItWasRevealedIsAMiss() async {
        let fake = Fake()
        fake.after(script: 1) { $0[1].tabs.removeLast() }
        let result = await reveal("https://work.example/a2", fake: fake, spaces: Self.sameSpace)
        guard case SafariBrowserError.documentNotFound? = result.error else {
            return XCTFail("expected documentNotFound, got \(String(describing: result.error))\n\(fake.transcript)")
        }
        XCTAssertEqual(fake.actions, [])
        XCTAssertEqual(result.warnings, [])
    }

    func testAMatchWithoutAWindowIDFallsBackToThePosition() async throws {
        // The match carries the id the enumeration read…
        let windows = try SafariBridge.decodeWindowEnumeration(FakeEnumeration.sourceForm(Fake.threeWindows.map {
            .titledTabs(id: $0.id, profile: nil, urls: $0.tabs, currentTab: $0.current)
        }))
        XCTAssertEqual(SafariBridge.findExactMatch(url: "https://work.example/a2", in: windows)?.windowID, 5822)
        // …and without one (a record that carries no id; `open` cannot produce this from a live enumeration),
        // the reveal is the same one script by position: the checks, the switch, then the raise, because after
        // the raise `window 2` is another window.
        let fake = Fake()
        try await fake.drive {
            try await SafariBridge.focusExistingTab(
                window: 2, tabInWindow: 2, isCurrent: false, url: "https://work.example/a2",
                windowID: nil, warnWriter: { _ in }, spaces: Self.sameSpace)
        }
        XCTAssertEqual(fake.scripts.count, 1, fake.transcript)
        assertOrder(["if (count of tabs of window 2) < 2 then error \"SB_TAB_GONE\" number 9003",
                     "set _t to tab 2 of window 2", "is not equal to \"https://work.example/a2\"", "SB_TARGET_CHANGED",
                     "set current tab of window 2 to _t", "set index of window 2 to 1", "activate"],
                    in: fake.scripts.first ?? "")
        XCTAssertFalse(fake.scripts.contains { $0.contains("window id") }, fake.transcript)
        XCTAssertEqual(fake.actions, [.madeCurrent(windowID: 5822, tab: 2), .raised(windowID: 5822), .activated])

        // The checks are not lost with the id: a tab that shows another URL is left alone.
        var otherURL = Fake.threeWindows
        otherURL[1].tabs[1] = "https://other.example/"
        let moved = Fake(windows: otherURL)
        var warnings: [String] = []
        do {
            try await moved.drive {
                try await SafariBridge.focusExistingTab(
                    window: 2, tabInWindow: 2, isCurrent: false, url: "https://work.example/a2",
                    windowID: nil, warnWriter: { warnings.append($0) }, spaces: Self.sameSpace)
            }
            XCTFail("the tab in that position shows another URL")
        } catch SafariBrowserError.targetChangedBeforeActing {
            XCTAssertEqual(moved.actions, [])
            XCTAssertEqual(warnings, [])
        }
        // A window id of zero or less is no id.
        let zero = Fake()
        try await zero.drive {
            try await SafariBridge.focusExistingTab(
                window: 2, tabInWindow: 2, isCurrent: false, url: "https://work.example/a2",
                windowID: 0, warnWriter: { _ in }, spaces: Self.sameSpace)
        }
        XCTAssertFalse(zero.scripts.contains { $0.contains("window id") }, zero.transcript)
    }
}
