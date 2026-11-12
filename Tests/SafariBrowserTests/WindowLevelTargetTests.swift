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
        XCTAssertEqual(SafariBridge.actingWindow(
            for: Resolved(windowIndex: 2, tabIndexInWindow: nil, windowID: nil), named: .windowID(5822), profile: nil), .position(2))
        XCTAssertEqual(SafariBridge.actingWindow(
            for: Resolved(windowIndex: 2, tabIndexInWindow: 2, windowID: 5822, anchorTabIndex: 2),
            named: .windowTab(window: 2, tabInWindow: 2), profile: nil), .position(2))

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
        do {
            _ = try await fake.drive { try await SafariBridge.runAppleScript(script) }
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
                guard case SafariBrowserError.appleScriptFailed(let message)? = outcome.error else {
                    XCTFail("\(row.0): expected the check to stop the script, got \(String(describing: outcome.error))")
                    continue
                }
                XCTAssertTrue(message.contains("SB_TARGET_CHANGED"), message)
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
        guard case SafariBrowserError.targetChangedBeforeActing(let expected)? = moved else {
            return XCTFail("a failed URL check is targetChangedBeforeActing, got \(String(describing: moved))")
        }
        XCTAssertTrue(expected.contains("window id 5822 tab 2"), expected)
        let text = SafariBrowserError.targetChangedBeforeActing(expected: expected).errorDescription ?? ""
        XCTAssertTrue(text.contains("Nothing was done to it"), text)
        XCTAssertFalse(text.contains("re-resolve"), "this error does not retry, and must not say it did:\n\(text)")

        // Anything else passes through untouched.
        guard case SafariBrowserError.appleScriptFailed(let other)? =
                await translate(.windowID(5822), "execution error: File dialog did not appear within 10 seconds (-2700)") else {
            return XCTFail("another AppleScript error is not translated")
        }
        XCTAssertTrue(other.contains("File dialog did not appear"))
        XCTAssertEqual(fake.scripts, [], "wording a miss on a window id sends nothing")
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
            scripts.append(("reveal, raise \(raise)", SafariBridge.focusExistingScript(
                windowID: 5822, tab: 2, url: "https://work.example/a2", raise: raise)))
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
