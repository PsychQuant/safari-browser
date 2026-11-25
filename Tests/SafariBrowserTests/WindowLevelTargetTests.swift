import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #353: the pieces every window-level command shares: how the resolved window is named, what the resolver
/// hands back, the URL check a script makes before it acts on a tab, and the wording of a miss.
final class WindowLevelTargetTests: XCTestCase {

    private typealias Fake = WindowLevelFakeSafari

    // MARK: The fake itself

    func testTheFakeRefusesAURLCheckThatFailsAndAppliesNothingAfterIt() async throws {
        let fake = Fake()
        let script = SafariBridge.closeTabScript(
            windowReference: "window id 5822", tab: 2,
            guardClause: SafariBridge.exactURLGuardClause("https://elsewhere.example/"))
        do {
            _ = try await fake.drive { try await SafariBridge.runAppleScript(script) }
            XCTFail("the URL check must stop the script")
        } catch SafariBrowserError.appleScriptFailed(let message) {
            XCTAssertTrue(message.contains("SB_TARGET_CHANGED") && message.contains("9001"), message)
        }
        XCTAssertEqual(fake.actions, [])
        XCTAssertEqual(fake.window(id: 5822)?.tabs.count, 2)
    }

    func testTheFakeKeepsTheCurrentTabWhenABackgroundTabCloses() async throws {
        let fake = Fake()
        let script = SafariBridge.closeTabScript(windowReference: "window id 4711", tab: 3, guardClause: nil)
        _ = try await fake.drive { try await SafariBridge.runAppleScript(script) }
        XCTAssertEqual(fake.actions, [.closed(windowID: 4711, tab: 3, url: "https://home.example/3")])
        XCTAssertEqual(fake.window(id: 4711)?.current, 1)
        XCTAssertEqual(fake.window(id: 4711)?.tabs, ["https://home.example/1", "https://home.example/2"])
    }

    func testTheFakeAnswersAWindowThatIsGoneAsSafariDoes() async {
        let fake = Fake()
        let script = SafariBridge.closeTabScript(windowReference: "window id 9999", tab: nil, guardClause: nil)
        do {
            _ = try await fake.drive { try await SafariBridge.runAppleScript(script) }
            XCTFail("window id 9999 does not exist")
        } catch SafariBrowserError.appleScriptFailed(let message) {
            XCTAssertTrue(SafariBridge.isObjectNotFound(message), message)
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: cases that keep the position

    /// The close script sent before #353 for the front window, kept here as text so a change to it shows.
    private static let closeFrontWindowScript = """
        tell application "Safari"
            if (count of windows) = 0 then
                error "Safari has no windows — nothing to close"
            end if
            if (count of tabs of window 1) = 0 then
                error "window 1 has no tabs — nothing to close"
            end if
            close current tab of window 1
        end tell
        """

    // spec-example: document-targeting / cases that keep the position
    func testCasesThatKeepThePosition() async throws {
        typealias Resolved = SafariBridge.ResolvedWindowTarget
        // The decision itself.
        XCTAssertEqual(SafariBridge.actingWindow(
            for: Resolved(windowIndex: 1, tabIndexInWindow: nil, windowID: 4711), named: .frontWindow, profile: nil), .position(1))
        XCTAssertEqual(SafariBridge.actingWindow(
            for: Resolved(windowIndex: 2, tabIndexInWindow: nil, windowID: 5822), named: .windowIndex(2), profile: nil), .position(2))
        XCTAssertEqual(SafariBridge.actingWindow(
            for: Resolved(windowIndex: 2, tabIndexInWindow: nil, windowID: 5822), named: .frontWindow, profile: "Work"), .id(5822))
        // A window id the user typed never falls back to a position, whatever the resolution carried
        // (--window-id is an identity, not a place); a tab found by its URL in a record without an id does.
        XCTAssertEqual(SafariBridge.actingWindow(
            for: Resolved(windowIndex: 2, tabIndexInWindow: nil, windowID: nil), named: .windowID(5822), profile: nil), .id(5822))
        XCTAssertEqual(SafariBridge.actingWindow(
            for: Resolved(windowIndex: 2, tabIndexInWindow: nil, windowID: nil),
            named: .windowID(5822, tabInWindow: nil, pinnedFrom: 2), profile: "Work"), .id(5822))
        XCTAssertEqual(SafariBridge.actingWindow(
            for: Resolved(windowIndex: 2, tabIndexInWindow: 2, windowID: nil, anchorTabIndex: 2),
            named: .urlMatch(.contains("a2")), profile: nil), .position(2))
        XCTAssertEqual(SafariBridge.actingWindow(
            for: Resolved(windowIndex: 2, tabIndexInWindow: 2, windowID: 5822, anchorTabIndex: 2),
            named: .windowTab(window: 2, tabInWindow: 2), profile: nil), .position(2))

        // `screenshot` does not count --profile alone, --url-exact, --url-endswith or --url-regex as a target
        // (#233): no window is resolved, nothing is sent, and the front window is captured as before.
        for flags in [["--profile", "Work"], ["--url-exact", "https://work.example/a1"],
                      ["--url-endswith", "/a1"], ["--url-regex", "a1$"]] {
            let fake = Fake()
            let shot = try ScreenshotCommand.parse(flags + ["/tmp/out.png"])
            let resolved = try await fake.drive { try await shot.resolveCapture() }
            XCTAssertNil(resolved.capture, "\(flags)")
            XCTAssertEqual(fake.scripts, [], "\(flags)")
        }

        // `close`: no flag — the script is the one sent before, and it names `window 1`.
        let plain = Fake()
        let plainError = await plain.run(CloseCommand.self, [])
        XCTAssertNil(plainError, plain.transcript)
        XCTAssertEqual(plain.scripts.last, Self.closeFrontWindowScript)
        XCTAssertEqual(plain.closed, [.closed(windowID: 4711, tab: 1, url: "https://home.example/1")])
        XCTAssertEqual(plain.diagnostics, [])

        // `close --window 2`, the id of window 2 cannot be read: one note, then `window 2`.
        let unread = Fake()
        unread.anchorDoesNotAnswer = true
        let unreadError = await unread.run(CloseCommand.self, ["--window", "2"])
        XCTAssertNil(unreadError, unread.transcript)
        XCTAssertEqual(unread.diagnostics.count, 1, "\(unread.diagnostics)")
        XCTAssertTrue(unread.diagnostics.first?.contains("--window 2 is looked up by its position") == true, "\(unread.diagnostics)")
        XCTAssertTrue(unread.scripts.last?.contains("close current tab of window 2") == true, unread.transcript)
        XCTAssertFalse(unread.scripts.last?.contains("window id") == true, unread.transcript)
        XCTAssertEqual(unread.closed, [.closed(windowID: 5822, tab: 1, url: "https://work.example/a1")])

        // `close --window 5` with three windows: the note, then the miss it gave before.
        let missing = Fake()
        let missingError = await missing.run(CloseCommand.self, ["--window", "5"])
        guard case SafariBrowserError.documentNotFound(let pattern, _)? = missingError else {
            return XCTFail("expected documentNotFound, got \(String(describing: missingError))\n\(missing.transcript)")
        }
        XCTAssertEqual(pattern, "window 5")
        XCTAssertEqual(missing.diagnostics.count, 1, "\(missing.diagnostics)")
        XCTAssertEqual(missing.closed, [])

        // `close --profile Work`: the profile's first window, by its id.
        let scoped = Fake()
        let scopedError = await scoped.run(CloseCommand.self, ["--profile", "Work"])
        XCTAssertNil(scopedError, scoped.transcript)
        XCTAssertTrue(scoped.scripts.last?.contains("close current tab of window id 5822") == true, scoped.transcript)
        XCTAssertFalse(scoped.scripts(afterFirst: Fake.isEnumeration).contains(where: Fake.namesAPosition), scoped.transcript)
        XCTAssertEqual(scoped.closed, [.closed(windowID: 5822, tab: 1, url: "https://work.example/a1")])
    }

    // MARK: what the resolver returns

    private func fixtureWindows() throws -> [SafariBridge.WindowInfo] {
        try SafariBridge.decodeWindowEnumeration(FakeEnumeration.sourceForm(Fake.threeWindows.map {
            .titledTabs(id: $0.id, profile: nil, urls: $0.tabs, currentTab: $0.current)
        }))
    }

    // spec-example: document-targeting / what the resolver returns
    func testWhatTheResolverReturns() throws {
        let windows = try fixtureWindows()
        let regex = try NSRegularExpression(pattern: "home.*/1$")
        let rows: [(SafariBridge.TargetDocument, index: Int, id: Int?, tab: Int?, url: String?)] = [
            (.urlMatch(.contains("a2")), 2, 5822, 2, "https://work.example/a2"),
            (.urlMatch(.regex(regex)), 1, 4711, 1, "https://home.example/1"),
            (.documentIndex(4), 2, 5822, 1, nil),
            (.windowID(5822, tabInWindow: 2), 2, 5822, 2, nil),
            (.windowID(5822), 2, 5822, nil, nil),
        ]
        for row in rows {
            let resolved = try SafariBridge.pickNativeTarget(row.0, in: windows)
            XCTAssertEqual(resolved.windowIndex, row.index, "\(row.0)")
            XCTAssertEqual(resolved.windowID, row.id, "\(row.0)")
            XCTAssertEqual(resolved.anchorTabIndex, row.tab, "\(row.0)")
            XCTAssertEqual(resolved.matchedURL, row.url, "\(row.0)")
        }
        // --first-match hands back the URL of the tab it chose.
        let first = try SafariBridge.pickFirstMatchFallback(matcher: .contains("work.example"), in: windows)
        XCTAssertEqual(first.matchedURL, "https://work.example/a1")
    }

    // MARK: the URL check before acting

    /// Runs the close script for tab 2 of window id 5822, which shows `now`, with the check `named` gives.
    private func closeTab2(named: SafariBridge.TargetDocument, read: String?, now: String) async -> (closed: Bool, error: Error?) {
        var windows = Fake.threeWindows
        windows[1].tabs[1] = now
        let fake = Fake(windows: windows)
        let script = SafariBridge.closeTabScript(
            windowReference: "window id 5822", tab: 2,
            guardClause: SafariBridge.tabGuardClause(named: named, matchedURL: read))
        // Through the translation the commands use, so that a failed check is the error a caller reads.
        let target = SafariBridge.TargetDocument.resolvedTab(windowID: 5822, tabInWindow: 2, rematch: nil, profile: nil)
        do {
            _ = try await fake.drive {
                try await SafariBridge.translatingWindowLevelMarkers(target: target, profile: nil) {
                    try await SafariBridge.runAppleScript(script)
                }
            }
            return (!fake.closed.isEmpty, nil)
        } catch {
            return (!fake.closed.isEmpty, error)
        }
    }

    // spec-example: document-targeting / the URL check before acting
    func testTheURLCheckBeforeActing() async throws {
        let regex = try NSRegularExpression(pattern: "a[0-9]$")
        let read = "https://work.example/a2"
        let long = "https://work.example/" + String(repeating: "x", count: 2_479)
        XCTAssertEqual(long.count, 2_500)
        let sameStart = String(long.prefix(2_000)) + String(repeating: "y", count: 500)
        let differsEarly = "https://work.example/z" + String(long.dropFirst(22))
        let rows: [(SafariBridge.TargetDocument, read: String?, now: String, acts: Bool)] = [
            (.urlMatch(.contains("work.example/a2")), read, "https://work.example/a2?x=1", true),
            (.urlMatch(.contains("work.example/a2")), read, "https://work.example/A2", false),
            (.urlMatch(.exact("https://work.example/a2")), read, "https://work.example/a2#top", false),
            (.urlMatch(.endsWith("/a2")), read, "https://other.example/a2", true),
            (.urlMatch(.regex(regex)), read, "https://work.example/a2", true),
            (.urlMatch(.regex(regex)), read, "https://work.example/a3", false),
            (.urlMatch(.regex(regex)), long, sameStart, true),
            (.urlMatch(.regex(regex)), long, differsEarly, false),
            (.windowID(5822, tabInWindow: 2), nil, "https://anything.example/", true),
            (.documentIndex(5), nil, "https://anything.example/", true),
        ]
        for row in rows {
            let outcome = await closeTab2(named: row.0, read: row.read, now: row.now)
            XCTAssertEqual(outcome.closed, row.acts, "\(row.0) read \(row.read ?? "-") now \(row.now.prefix(60))")
            if row.acts {
                XCTAssertNil(outcome.error, "\(row.0): \(String(describing: outcome.error))")
            } else {
                guard case SafariBrowserError.targetChangedBeforeActing(let expected, let stage)? = outcome.error else {
                    XCTFail("\(row.0): expected a target-changed error, got \(String(describing: outcome.error))")
                    continue
                }
                XCTAssertEqual(stage, .beforeAnyAction)
                XCTAssertTrue(expected.contains("window id 5822 tab 2"), expected)
            }
        }
        // A tab named by its position has no check; a regex with no URL to compare refuses.
        XCTAssertNil(SafariBridge.tabGuardClause(named: .windowID(5822, tabInWindow: 2), matchedURL: nil))
        XCTAssertNil(SafariBridge.tabGuardClause(named: .documentIndex(5), matchedURL: "https://x.example/"))
        let unread = await closeTab2(named: .urlMatch(.regex(regex)), read: nil, now: read)
        XCTAssertFalse(unread.closed)
        XCTAssertNotNil(unread.error)
    }

    // MARK: a window that is gone, a tab that moved

    func testAMarkerFromAWindowLevelScriptBecomesTheErrorACallerReads() async throws {
        let fake = Fake()
        func translate(_ target: SafariBridge.TargetDocument, _ message: String) async -> Error? {
            do {
                try await fake.drive {
                    try await SafariBridge.translatingWindowLevelMarkers(target: target, profile: nil) {
                        throw SafariBrowserError.appleScriptFailed(message)
                    }
                }
                return nil
            } catch {
                return error
            }
        }
        let gone = "89:142: execution error: SB_WINDOW_GONE (9002)"
        guard case SafariBrowserError.documentNotFound(let pinned, _)? =
                await translate(.windowID(5822, tabInWindow: nil, pinnedFrom: 2), gone) else {
            return XCTFail("a pinned window that is gone is documentNotFound")
        }
        XCTAssertEqual(pinned, "window 2 (window id 5822 at command start)")
        guard case SafariBrowserError.documentNotFound(let typed, _)? = await translate(.windowID(5822), gone) else {
            return XCTFail("a window id that is gone is documentNotFound")
        }
        XCTAssertEqual(typed, "window id 5822")

        let moved = await translate(
            .resolvedTab(windowID: 5822, tabInWindow: 2, rematch: .contains("a2"), profile: nil),
            "execution error: SB_TARGET_CHANGED (9001)")
        guard case SafariBrowserError.targetChangedBeforeActing(let expected, let stage)? = moved else {
            return XCTFail("a failed URL check is targetChangedBeforeActing, got \(String(describing: moved))")
        }
        XCTAssertTrue(expected.contains("window id 5822 tab 2"), expected)
        XCTAssertEqual(stage, .beforeAnyAction)
        let text = SafariBrowserError.targetChangedBeforeActing(expected: expected).errorDescription ?? ""
        XCTAssertTrue(text.contains("Nothing was done to it"), text)
        XCTAssertFalse(text.contains("re-resolve"), "this error does not retry, and must not say it did:\n\(text)")

        // A tab the resolution named is gone from a window that is still open.
        guard case SafariBrowserError.documentNotFound(let tabGone, _)? =
                await translate(.windowID(5822, tabInWindow: 2), "execution error: SB_TAB_GONE (9003)") else {
            return XCTFail("a tab that is gone is documentNotFound")
        }
        XCTAssertEqual(tabGone, "window id 5822 tab 2")

        // Anything else passes through untouched.
        guard case SafariBrowserError.appleScriptFailed(let other)? =
                await translate(.windowID(5822), "execution error: File dialog did not appear within 10 seconds (-2700)") else {
            return XCTFail("another AppleScript error is not translated")
        }
        XCTAssertTrue(other.contains("File dialog did not appear"))
        XCTAssertEqual(fake.scripts, [], "wording a miss on a window id sends nothing")
    }

    /// The number at the end of the error decides, never the text (#218): the wrapped scripts include System
    /// Events blocks, whose error text can carry a window's name, and a window's name is a page's title.
    // spec-example: document-targeting / markers by number
    func testAMarkerIsReadFromTheErrorNumberNotFromTheText() async throws {
        let fake = Fake()
        func translate(_ message: String, notFound: Bool = false) async -> Error? {
            do {
                try await fake.drive {
                    try await SafariBridge.translatingWindowLevelMarkers(
                        target: .windowID(5822), profile: nil, translateNotFound: notFound
                    ) {
                        throw SafariBrowserError.appleScriptFailed(message)
                    }
                }
                return nil
            } catch {
                return error
            }
        }
        // A page titled like a marker, reported by System Events with its own number: passed through.
        for title in ["SB_WINDOW_GONE", "SB_TARGET_CHANGED", "SB_TAB_GONE"] {
            let message = "System Events got an error: Can’t get sheet 1 of window \"\(title)\" of process \"Safari\". (-1728)"
            guard case SafariBrowserError.appleScriptFailed(let passed)? = await translate(message) else {
                return XCTFail("\(title) in the text is not a marker")
            }
            XCTAssertEqual(passed, message)
        }
        // The numbers alone are the markers.
        guard case SafariBrowserError.targetChangedBeforeActing? = await translate("execution error: tab 2 is no longer current (9001)") else {
            return XCTFail("9001 is the target-changed marker")
        }
        guard case SafariBrowserError.documentNotFound? = await translate("execution error: gone (9002)") else {
            return XCTFail("9002 is the window-gone marker")
        }
        guard case SafariBrowserError.documentNotFound? = await translate("execution error: gone (9003)") else {
            return XCTFail("9003 is the tab-gone marker")
        }
        // "Object not found" is a miss only where the caller says the wrapped script is a Safari read.
        let bare = "execution error: Safari got an error: Can’t get window id 5822. (-1728)"
        guard case SafariBrowserError.appleScriptFailed? = await translate(bare) else {
            return XCTFail("-1728 is left alone by default")
        }
        guard case SafariBrowserError.documentNotFound? = await translate(bare, notFound: true) else {
            return XCTFail("-1728 is a miss when translateNotFound is set")
        }
    }

    /// What the target-changed error says depends on what the command had already done.
    // spec-example: document-targeting / what a target-changed error says
    func testTheTargetChangedErrorSaysWhatHadAlreadyHappened() async throws {
        let fake = Fake()
        func text(_ stage: SafariBrowserError.TargetChangeStage) async -> String {
            do {
                try await fake.drive {
                    try await SafariBridge.translatingWindowLevelMarkers(
                        target: .resolvedTab(windowID: 5822, tabInWindow: 2, rematch: .contains("a2"), profile: nil),
                        profile: nil, stage: stage
                    ) {
                        throw SafariBrowserError.appleScriptFailed("execution error: SB_TARGET_CHANGED (9001)")
                    }
                }
                return ""
            } catch {
                guard case SafariBrowserError.targetChangedBeforeActing(_, let carried) = error else { return "\(error)" }
                XCTAssertEqual(carried, stage)
                return error.localizedDescription
            }
        }
        let before = await text(.beforeAnyAction)
        XCTAssertTrue(before.contains("Nothing was done to it"), before)

        let switched = await text(.afterTabSwitch)
        XCTAssertFalse(switched.contains("Nothing was done"), "a tab may have been made current by then:\n\(switched)")
        XCTAssertFalse(switched.contains("no tab was closed or switched"), switched)
        XCTAssertTrue(switched.contains("had already made that tab current"), switched)
        XCTAssertTrue(switched.contains("The file input was not clicked"), switched)
        XCTAssertTrue(switched.contains("no longer its window's current tab"), switched)

        let dialog = await text(.afterFileDialog)
        XCTAssertFalse(dialog.contains("Nothing was done"), dialog)
        XCTAssertFalse(dialog.contains("was not clicked"), "the click had happened:\n\(dialog)")
        XCTAssertTrue(dialog.contains("after the file input was clicked"), dialog)
        XCTAssertTrue(dialog.contains("dismiss it (Esc)"), dialog)
        for message in [before, switched, dialog] {
            XCTAssertTrue(message.contains("window id 5822 tab 2"), message)
            XCTAssertFalse(message.contains("re-resolve"), message)
        }
    }

    // spec-example: document-targeting / misses of window-level commands under a profile
    func testMissesOfWindowLevelCommandsUnderAProfile() async throws {
        func miss(_ target: SafariBridge.TargetDocument, profile: String?, on fake: Fake) async throws -> (String, [String]) {
            let error = try await fake.drive { try await SafariBridge.notFoundError(for: target, profile: profile) }
            guard case .documentNotFound(let pattern, let entries) = error else {
                XCTFail("expected documentNotFound, got \(error)")
                return ("", [])
            }
            return (pattern, entries)
        }
        var windows = Fake.threeWindows
        windows.removeAll { $0.id == 5822 }

        // A window id that is gone, under --profile: that profile's windows, by id.
        let gone = try await miss(.windowID(5822), profile: "Work", on: Fake(windows: windows))
        XCTAssertEqual(gone.0, "window id 5822 (profile: \"Work\")")
        XCTAssertEqual(gone.1, ["window id 6933: https://work.example/b1"])

        // The same miss on a tab of that window.
        let goneTab = try await miss(.windowID(5822, tabInWindow: 2), profile: "Work", on: Fake(windows: windows))
        XCTAssertEqual(goneTab.0, "window id 5822 tab 2 (profile: \"Work\")")
        XCTAssertEqual(goneTab.1, ["window id 6933: https://work.example/b1"])

        // The window is open but has no tab 2 any more: the tabs it has.
        var oneTab = Fake.threeWindows
        oneTab[1].tabs.removeLast()
        let tabGone = try await miss(.windowID(5822, tabInWindow: 2), profile: "Work", on: Fake(windows: oneTab))
        XCTAssertEqual(tabGone.0, "window id 5822 tab 2 (profile: \"Work\")")
        XCTAssertEqual(tabGone.1.count, 1, "\(tabGone.1)")
        XCTAssertTrue(tabGone.1.first?.hasSuffix("(window id 5822): https://work.example/a1") == true, "\(tabGone.1)")

        // No window of the profile is left.
        let none = try await miss(.windowID(5822), profile: "Work", on: Fake(windows: [Fake.threeWindows[0]]))
        XCTAssertEqual(none.1, ["(no window of profile \"Work\" is open)"])
        // A window of another profile is never listed, even when it is the window named and it is open.
        let foreign = try await miss(.windowID(4711, tabInWindow: 9), profile: "Work", on: Fake())
        XCTAssertEqual(foreign.1, ["window id 5822: https://work.example/a1", "window id 6933: https://work.example/b1"])
        for entries in [gone.1, goneTab.1, tabGone.1, none.1, foreign.1] {
            XCTAssertFalse(entries.contains { $0.contains("home.example") }, "another profile's tab is listed: \(entries)")
        }

        // Without --profile the miss sends nothing and lists nothing, as before.
        let plain = Fake(windows: windows)
        let bare = try await miss(.windowID(5822), profile: nil, on: plain)
        XCTAssertEqual(bare.0, "window id 5822")
        XCTAssertEqual(plain.scripts, [])

        // close --window-id 5822 --profile Work, the window closes after the resolution.
        let closing = Fake()
        closing.after(script: 1) { $0.removeAll { $0.id == 5822 } }
        let closeError = await closing.run(CloseCommand.self, ["--window-id", "5822", "--profile", "Work"])
        guard case SafariBrowserError.documentNotFound(let pattern, let entries)? = closeError else {
            return XCTFail("expected documentNotFound, got \(String(describing: closeError))\n\(closing.transcript)")
        }
        XCTAssertEqual(pattern, "window id 5822 (profile: \"Work\")")
        XCTAssertEqual(entries, ["window id 6933: https://work.example/b1"])
        XCTAssertEqual(closing.closed, [])

        // close --profile Work: the profile's first window, by its id. The same miss.
        let scopedClosing = Fake()
        scopedClosing.after(script: 1) { $0.removeAll { $0.id == 5822 } }
        let scopedError = await scopedClosing.run(CloseCommand.self, ["--profile", "Work"])
        guard case SafariBrowserError.documentNotFound(let scopedPattern, let scopedEntries)? = scopedError else {
            return XCTFail("expected documentNotFound, got \(String(describing: scopedError))\n\(scopedClosing.transcript)")
        }
        XCTAssertEqual(scopedPattern, "window id 5822 (profile: \"Work\")")
        XCTAssertEqual(scopedEntries, ["window id 6933: https://work.example/b1"])
        XCTAssertEqual(scopedClosing.closed, [])

        // close --document 2 --profile Work: a resolved tab that carries the profile. No suffix, and the
        // profile's tabs with their window ids.
        let tabClosing = Fake()
        tabClosing.after(script: 1) { $0.removeAll { $0.id == 5822 } }
        let tabError = await tabClosing.run(CloseCommand.self, ["--document", "2", "--profile", "Work"])
        guard case SafariBrowserError.documentNotFound(let tabPattern, let tabEntries)? = tabError else {
            return XCTFail("expected documentNotFound, got \(String(describing: tabError))\n\(tabClosing.transcript)")
        }
        XCTAssertEqual(tabPattern, "window id 5822 tab 2")
        XCTAssertEqual(tabEntries, ["window 2 tab 1 (window id 6933): https://work.example/b1"])
        XCTAssertEqual(tabClosing.closed, [])
    }

    /// The `--url-regex` check carries the URL the resolution read inside the script: it has to be escaped as
    /// AppleScript text, and a long one is cut before it is escaped, not after.
    func testTheURLCheckCarriesAURLThatNeedsEscaping() async throws {
        let regex = try NSRegularExpression(pattern: "quote")
        let quoted = "https://work.example/quote?q=\"a\\b\"&r=\\"
        let same = await closeTab2(named: .urlMatch(.regex(regex)), read: quoted, now: quoted)
        XCTAssertTrue(same.closed, "the tab still shows the URL that was read: \(String(describing: same.error))")
        let other = await closeTab2(named: .urlMatch(.regex(regex)), read: quoted, now: quoted + "x")
        XCTAssertFalse(other.closed)

        // Character 2,000 is a quote: cut after escaping, the compared text would end in a lone backslash.
        let head = "https://work.example/quote/" + String(repeating: "x", count: 1_972) + "\""
        XCTAssertEqual(head.count, 2_000)
        let long = head + String(repeating: "y", count: 500)
        let sameStart = await closeTab2(named: .urlMatch(.regex(regex)), read: long, now: head + String(repeating: "z", count: 40))
        XCTAssertTrue(sameStart.closed, "the first 2,000 characters are the same: \(String(describing: sameStart.error))")
        let differsAtTheCut = await closeTab2(
            named: .urlMatch(.regex(regex)), read: long, now: String(head.dropLast()) + "'" + String(repeating: "y", count: 500))
        XCTAssertFalse(differsAtTheCut.closed, "character 2,000 differs")
        // Exactly 2,000 characters is compared whole.
        let whole = await closeTab2(named: .urlMatch(.regex(regex)), read: head, now: head + "tail")
        XCTAssertFalse(whole.closed, "a URL of exactly 2,000 characters is compared for equality")
    }

    /// The fake compares as AppleScript does: a check written without `considering case` lets a URL that
    /// differs only in case through, so the check the product builds is seen to need it.
    func testTheFakeIgnoresCaseOutsideConsideringCase() async throws {
        func closes(_ clause: String) async -> Bool {
            var windows = Fake.threeWindows
            windows[1].tabs[1] = "https://work.example/A2"
            let fake = Fake(windows: windows)
            let script = SafariBridge.closeTabScript(windowReference: "window id 5822", tab: 2, guardClause: clause)
            _ = try? await fake.drive { try await SafariBridge.runAppleScript(script) }
            return !fake.closed.isEmpty
        }
        let withCase = SafariBridge.exactURLGuardClause("https://work.example/a2")
        XCTAssertTrue(withCase.contains("considering case"), withCase)
        let stopped = await closes(withCase)
        XCTAssertFalse(stopped, "inside considering case, A2 is not a2")
        let withoutCase = withCase.components(separatedBy: "\n").filter { !$0.contains("considering") }.joined(separator: "\n")
        let passed = await closes(withoutCase)
        XCTAssertTrue(passed, "outside considering case AppleScript ignores case, and so does the fake")
    }

    /// The fake reads these scripts line by line; it would accept text Safari's AppleScript cannot parse. So
    /// every script the window-level commands build is also handed to the AppleScript compiler. Compiling does
    /// not run anything.
    @MainActor  // NSAppleScript is created and compiled on the main actor (#130)
    func testEveryWindowLevelScriptCompiles() throws {
        let regex = try NSRegularExpression(pattern: "a[0-9]$")
        let long = "https://work.example/" + String(repeating: "x", count: 2_479)
        let clauses: [(String, String?)] = [
            ("no check", nil),
            ("contains", SafariBridge.tabGuardClause(named: .urlMatch(.contains("work.example/\"a2")), matchedURL: nil)),
            ("exact", SafariBridge.tabGuardClause(named: .urlMatch(.exact("https://work.example/a2")), matchedURL: nil)),
            ("ends with", SafariBridge.tabGuardClause(named: .urlMatch(.endsWith("/a2")), matchedURL: nil)),
            ("regex", SafariBridge.tabGuardClause(named: .urlMatch(.regex(regex)), matchedURL: "https://work.example/a2")),
            ("regex, long URL", SafariBridge.tabGuardClause(named: .urlMatch(.regex(regex)), matchedURL: long)),
            ("regex, nothing read", SafariBridge.tabGuardClause(named: .urlMatch(.regex(regex)), matchedURL: nil)),
        ]
        var scripts: [(String, String)] = []
        for (name, clause) in clauses {
            for reference in ["window id 5822", "window 2"] {
                scripts.append(("close, \(name), \(reference)",
                                SafariBridge.closeTabScript(windowReference: reference, tab: 2, guardClause: clause)))
                scripts.append(("bring tab forward, \(name), \(reference)",
                                SafariBridge.bringTabForwardScript(windowReference: reference, tab: 2, guardClause: clause)))
            }
            scripts.append(("pdf export by id, \(name)", PdfCommand.exportScript(
                path: "/tmp/staging/out.pdf", window: .id(5822), tab: 2, guardClause: clause)))
            scripts.append(("pdf export by position, \(name)", PdfCommand.exportScript(
                path: "/tmp/staging/out.pdf", window: .position(2), tab: 2, guardClause: clause)))
        }
        scripts.append(("close current tab by id", SafariBridge.closeTabScript(windowReference: "window id 5822", tab: nil, guardClause: nil)))
        scripts.append(("pdf export by id, no tab", PdfCommand.exportScript(path: "/tmp/staging/out.pdf", window: .id(5822))))
        scripts.append(("pdf export, front window", PdfCommand.exportScript(path: "/tmp/staging/out.pdf", window: .position(1))))
        scripts.append(("geometry by id", SafariBridge.captureGeometryScript(windowReference: "window id 5822")))
        scripts.append(("geometry by position", SafariBridge.captureGeometryScript(windowReference: "window 2")))
        for raise in [false, true] {
            for window in [SafariBridge.ActingWindow.id(5822), .position(2)] {
                scripts.append(("reveal, raise \(raise), \(window.reference)", SafariBridge.focusExistingScript(
                    window: window, tab: 2, url: "https://work.example/a\"2", raise: raise)))
            }
        }
        // A matched URL that needs escaping, whole and cut at 2,000 characters next to a quote.
        let quoted = "https://work.example/quote?q=\"a\\b\"&r=\\"
        let cutAtAQuote = "https://work.example/quote/" + String(repeating: "x", count: 1_972) + "\"" + String(repeating: "y", count: 500)
        for (name, url) in [("quoted", quoted), ("cut at a quote", cutAtAQuote)] {
            let clause = SafariBridge.tabGuardClause(named: .urlMatch(.regex(regex)), matchedURL: url)
            scripts.append(("close, regex, \(name)", SafariBridge.closeTabScript(windowReference: "window id 5822", tab: 2, guardClause: clause)))
        }
        for (name, clause) in clauses {
            scripts.append(("upload dialog by id, tab, \(name)", UploadCommand.nativeDialogScript(
                path: "/tmp/f.txt", window: .id(5822), tab: 2, guardClause: clause)))
        }
        scripts.append(("upload dialog by id", UploadCommand.nativeDialogScript(path: "/tmp/f.txt", window: .id(5822))))
        scripts.append(("upload dialog by position", UploadCommand.nativeDialogScript(path: "/tmp/f.txt", window: .position(2))))
        scripts.append(("upload dialog, no window", UploadCommand.nativeDialogScript(path: "/tmp/f.txt", window: nil)))

        for (name, source) in scripts {
            let script = try XCTUnwrap(NSAppleScript(source: source), name)
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "\(name): \(String(describing: error))\n\(source)")
        }
    }

    func testTheFakeMakesATabCurrentOnlyWhenItIsNot() async throws {
        let fake = Fake()
        _ = try await fake.drive {
            try await SafariBridge.runAppleScript(SafariBridge.bringTabForwardScript(windowReference: "window id 5822", tab: 1, guardClause: nil))
        }
        XCTAssertEqual(fake.actions, [], "tab 1 is already current")
        _ = try await fake.drive {
            try await SafariBridge.runAppleScript(SafariBridge.bringTabForwardScript(windowReference: "window id 5822", tab: 2, guardClause: nil))
        }
        XCTAssertEqual(fake.actions, [.madeCurrent(windowID: 5822, tab: 2)])
    }

    func testClickTargetIsTheNamedTabOnlyWhileItIsCurrent() {
        typealias Resolved = SafariBridge.ResolvedWindowTarget
        // A named tab of a window with an id: the anchored form, which checks it is still current.
        XCTAssertEqual(SafariBridge.clickTarget(
            for: Resolved(windowIndex: 2, tabIndexInWindow: 2, windowID: 5822, anchorTabIndex: 2, matchedURL: "https://work.example/a2"),
            named: .urlMatch(.contains("a2")), profile: nil),
            .anchoredCurrentTab(windowID: 5822, tabInWindow: 2, profile: nil))
        XCTAssertEqual(SafariBridge.clickTarget(
            for: Resolved(windowIndex: 2, tabIndexInWindow: nil, windowID: 5822, anchorTabIndex: 2),
            named: .windowID(5822, tabInWindow: 2), profile: "Work"),
            .anchoredCurrentTab(windowID: 5822, tabInWindow: 2, profile: "Work"))
        // A window with no tab named, and the positional cases: what `actedTarget` gives.
        let pinned = SafariBridge.TargetDocument.windowID(5822, tabInWindow: nil, pinnedFrom: 2)
        XCTAssertEqual(SafariBridge.clickTarget(
            for: Resolved(windowIndex: 2, tabIndexInWindow: nil, windowID: 5822), named: pinned, profile: nil), pinned)
        XCTAssertEqual(SafariBridge.clickTarget(
            for: Resolved(windowIndex: 1, tabIndexInWindow: nil, windowID: 4711), named: .frontWindow, profile: nil), .windowIndex(1))
    }

    func testPageTargetIsTheResolvedWindowOrItsCurrentTab() {
        typealias Resolved = SafariBridge.ResolvedWindowTarget
        // A tab the resolution named (it was the window's current tab, or the capture was refused): that tab,
        // only while it is still current.
        XCTAssertEqual(SafariBridge.pageTarget(
            for: Resolved(windowIndex: 2, tabIndexInWindow: nil, windowID: 5822, anchorTabIndex: 1, matchedURL: "https://work.example/a1"),
            named: .urlMatch(.contains("a1")), profile: nil),
            .anchoredCurrentTab(windowID: 5822, tabInWindow: 1, profile: nil))
        // A window with no tab named: the window by its id, keeping what a miss needs.
        let pinned = SafariBridge.TargetDocument.windowID(5822, tabInWindow: nil, pinnedFrom: 2)
        XCTAssertEqual(SafariBridge.pageTarget(
            for: Resolved(windowIndex: 2, tabIndexInWindow: nil, windowID: 5822), named: pinned, profile: nil), pinned)
        XCTAssertEqual(SafariBridge.pageTarget(
            for: Resolved(windowIndex: 2, tabIndexInWindow: nil, windowID: 5822), named: .frontWindow, profile: "Work"), .windowID(5822))
        // By position there is none: the page steps resolve the options as before.
        XCTAssertNil(SafariBridge.pageTarget(
            for: Resolved(windowIndex: 1, tabIndexInWindow: nil, windowID: 4711), named: .frontWindow, profile: nil))
        XCTAssertNil(SafariBridge.pageTarget(
            for: Resolved(windowIndex: 2, tabIndexInWindow: nil, windowID: 5822), named: .windowIndex(2), profile: nil))
    }

    func testActedTargetKeepsWhatAMissNeeds() {
        typealias Resolved = SafariBridge.ResolvedWindowTarget
        let pinned = SafariBridge.TargetDocument.windowID(5822, tabInWindow: nil, pinnedFrom: 2)
        XCTAssertEqual(SafariBridge.actedTarget(
            for: Resolved(windowIndex: 3, tabIndexInWindow: nil, windowID: 5822), named: pinned, profile: nil), pinned)
        XCTAssertEqual(SafariBridge.actedTarget(
            for: Resolved(windowIndex: 2, tabIndexInWindow: 2, windowID: 5822, anchorTabIndex: 2, matchedURL: "https://work.example/a2"),
            named: .urlMatch(.contains("a2")), profile: "Work"),
            .resolvedTab(windowID: 5822, tabInWindow: 2, rematch: .contains("a2"), profile: "Work"))
        XCTAssertEqual(SafariBridge.actedTarget(
            for: Resolved(windowIndex: 1, tabIndexInWindow: nil, windowID: 4711), named: .frontWindow, profile: nil), .windowIndex(1))
        XCTAssertEqual(SafariBridge.actedTarget(
            for: Resolved(windowIndex: 2, tabIndexInWindow: nil, windowID: 5822), named: .frontWindow, profile: "Work"), .windowID(5822))
    }
}
