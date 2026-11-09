import ArgumentParser
import Foundation
import XCTest
@testable import SafariBrowser

/// #362: what a targeting miss prints must be usable as printed. Under `--profile` the listing names each
/// tab's window id and the hint points at `--window-id W --tab-in-window M` (Decision on #362); a failed
/// enumeration says it failed; `tabs` reports a window that closed during the command as a targeting miss.
final class TargetingMissListingTests: XCTestCase, @unchecked Sendable {

    // MARK: fixture — the Work profile's windows are Safari windows 2 and 3

    private static func tab(_ index: Int, _ url: String, current: Bool) -> SafariBridge.TabInWindow {
        SafariBridge.TabInWindow(tabIndex: index, url: url, title: "t", isCurrent: current)
    }

    /// Safari window 1 is Home (id 101); windows 2 and 3 are Work (ids 303, 404).
    private static func windows(ids: Bool = true) -> [SafariBridge.WindowInfo] {
        [SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1,
                                 tabs: [tab(1, "https://home.example/1", current: true)],
                                 profile: "Home", windowID: ids ? 101 : nil),
         SafariBridge.WindowInfo(windowIndex: 2, currentTabIndex: 1,
                                 tabs: [tab(1, "https://work.example/a1", current: true),
                                        tab(2, "https://work.example/a2", current: false)],
                                 profile: "Work", windowID: ids ? 303 : nil),
         SafariBridge.WindowInfo(windowIndex: 3, currentTabIndex: 1,
                                 tabs: [tab(1, "https://work.example/b1", current: true)],
                                 profile: "Work", windowID: ids ? 404 : nil)]
    }

    /// Every profile-scoped producer in the resolver, as (target, profile passed to the resolver).
    private static let scopedMisses: [(SafariBridge.TargetDocument, String?)] = [
        (.urlMatch(.contains("nothing-matches")), "Work"),
        (.windowTab(window: 1, tabInWindow: 99), "Work"),
        (.documentIndex(0), "Work"),
        (.documentIndex(99), "Work"),
        (.resolvedTab(windowID: 202, tabInWindow: 1, rematch: nil, profile: nil), "Work"),
        (.resolvedTab(windowID: 202, tabInWindow: 1, rematch: nil, profile: "Work"), nil),
    ]

    private func miss(_ target: SafariBridge.TargetDocument, profile: String?,
                      in windows: [SafariBridge.WindowInfo] = windows()) -> (pattern: String, entries: [String]) {
        do {
            _ = try SafariBridge.pickNativeTarget(target, in: windows, profile: profile)
            XCTFail("\(target) must miss")
        } catch SafariBrowserError.documentNotFound(let pattern, let entries) {
            return (pattern, entries)
        } catch {
            XCTFail("\(target): \(error)")
        }
        return ("", [])
    }

    private func text(_ miss: (pattern: String, entries: [String])) -> String {
        SafariBrowserError.documentNotFound(pattern: miss.pattern, availableDocuments: miss.entries).localizedDescription
    }

    private func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    // MARK: item 1 — profile-scoped listings carry window ids

    func testEveryProfileScopedListingNamesEachWindowsID() {
        for (target, profile) in Self.scopedMisses {
            let found = miss(target, profile: profile)
            XCTAssertFalse(found.entries.isEmpty, "\(target)")
            for entry in found.entries {
                XCTAssertTrue(entry.contains("(window id 303)") || entry.contains("(window id 404)"), "\(target): \(entry)")
                XCTAssertFalse(entry.contains("home.example"), "\(target): \(entry)")
            }
        }
    }

    /// The numbers in front of each entry stay Safari's own, the ones `documents` prints (document-listing,
    /// "Discovery aid for documentNotFound errors").
    func testTheWindowNumbersStaySafarisOwn() {
        let found = miss(.urlMatch(.contains("nothing-matches")), profile: "Work")
        XCTAssertEqual(found.entries, [
            "window 2 tab 1 (window id 303): https://work.example/a1",
            "window 2 tab 2 (window id 303): https://work.example/a2",
            "window 3 tab 1 (window id 404): https://work.example/b1",
        ])
        XCTAssertEqual(miss(.documentIndex(99), profile: "Work").entries, [
            "window 2 (window id 303): https://work.example/a1 (2 tab(s))",
            "window 3 (window id 404): https://work.example/b1 (1 tab(s))",
        ])
    }

    /// The issue's case: Work's windows are Safari windows 2 and 3. Copying an entry into the flags the hint
    /// names must select the tab that entry shows, with `--profile Work` still set and without it (verify F11).
    /// A tab entry gives `--window-id W --tab-in-window M`; a window-level entry (`--document N` overflow) names
    /// no tab, so it gives `--window-id W` alone, which selects the window's current tab, the URL it shows.
    /// The selected tab is read from what the resolver returned, and its URL compared with the entry's.
    func testEveryListedIDAndTabSelectsTheListedTab() throws {
        let tabEntry = try NSRegularExpression(pattern: #"^window (\d+) tab (\d+) \(window id (\d+)\): (\S+)$"#)
        let windowEntry = try NSRegularExpression(pattern: #"^window (\d+) \(window id (\d+)\): (\S+) \(\d+ tab\(s\)\)$"#)
        let windows = Self.windows()
        var tabs = 0, windowLevel = 0
        for (target, profile) in Self.scopedMisses {
            for entry in miss(target, profile: profile).entries {
                let range = NSRange(entry.startIndex..., in: entry)
                let copied: (window: Int, id: Int, tab: Int?, url: String)
                if let m = tabEntry.firstMatch(in: entry, range: range) {
                    func group(_ i: Int) -> String { (entry as NSString).substring(with: m.range(at: i)) }
                    copied = (Int(group(1))!, Int(group(3))!, Int(group(2))!, group(4))
                    tabs += 1
                } else if let m = windowEntry.firstMatch(in: entry, range: range) {
                    func group(_ i: Int) -> String { (entry as NSString).substring(with: m.range(at: i)) }
                    copied = (Int(group(1))!, Int(group(2))!, nil, group(3))
                    windowLevel += 1
                } else {
                    XCTFail("\(target): an entry the hint's flags cannot be copied from: \(entry)")
                    continue
                }
                for scope in ["Work", nil] as [String?] {
                    let resolved = try SafariBridge.pickNativeTarget(.windowID(copied.id, tabInWindow: copied.tab),
                                                                    in: windows, profile: scope)
                    let label = "\(entry), profile \(scope ?? "none")"
                    XCTAssertEqual(resolved.windowIndex, copied.window, label)
                    let window = try XCTUnwrap(windows.first { $0.windowIndex == resolved.windowIndex }, label)
                    let selected = resolved.tabIndexInWindow ?? window.currentTabIndex
                    XCTAssertEqual(window.tabs.first { $0.tabIndex == selected }?.url, copied.url, label)
                }
            }
        }
        XCTAssertGreaterThan(tabs, 10)
        XCTAssertEqual(windowLevel, 2)
    }

    func testTheHintPointsAtWindowIDWhenTheEntriesCarryIDs() {
        for (target, profile) in Self.scopedMisses {
            let message = flat(text(miss(target, profile: profile)))
            XCTAssertTrue(message.contains("--window-id W") && message.contains("--tab-in-window M"), "\(target): \(message)")
            XCTAssertFalse(message.contains("target one with --window N --tab-in-window M"), "\(target): \(message)")
            XCTAssertFalse(message.contains("Or target positionally with --window N --tab-in-window M"), "\(target): \(message)")
        }
    }

    /// A URL miss still says how to refine the substring.
    func testAURLMissUnderAProfileKeepsItsSubstringAdvice() {
        let message = flat(text(miss(.urlMatch(.contains("nothing-matches")), profile: "Work")))
        XCTAssertTrue(message.contains("--url matches a *substring* of the URL"), message)
        XCTAssertTrue(message.contains("--window-id W --tab-in-window M"), message)
    }

    func testWithoutAProfileTheListingAndHintAreUnchanged() {
        let found = miss(.urlMatch(.contains("nothing-matches")), profile: nil)
        XCTAssertEqual(found.entries.first, "window 1 tab 1: https://home.example/1")
        XCTAssertFalse(found.entries.joined().contains("window id"), "\(found.entries)")
        XCTAssertTrue(flat(text(found)).contains("--window N --tab-in-window M"), text(found))
        let positional = miss(.windowTab(window: 2, tabInWindow: 99), profile: nil)
        XCTAssertEqual(positional.entries, ["window 2 tab 1: https://work.example/a1", "window 2 tab 2: https://work.example/a2"])
        XCTAssertTrue(flat(text(positional)).contains("target one with --window N --tab-in-window M"), text(positional))
    }

    /// Legacy enumeration records carry no id: the entry says so, and the hint says the numbers are Safari's
    /// own and are used without `--profile`.
    func testLegacyRecordsSayTheyHaveNoWindowID() throws {
        let found = miss(.urlMatch(.contains("nothing-matches")), profile: "Work", in: Self.windows(ids: false))
        XCTAssertEqual(found.entries.first, "window 2 tab 1 (no window id): https://work.example/a1")
        let message = flat(text(found))
        XCTAssertTrue(message.contains("without --profile"), message)
        XCTAssertFalse(message.contains("--window-id W --tab-in-window M"), message)
        // Copied as the hint says — without --profile — the numbers select the tab listed.
        let resolved = try SafariBridge.pickNativeTarget(.windowTab(window: 2, tabInWindow: 1), in: Self.windows(ids: false))
        XCTAssertEqual(resolved.windowIndex, 2)
        XCTAssertEqual(resolved.anchorTabIndex, 1)
    }

    /// The hint reads the label, not the URL: a URL that contains the label's words does not change it.
    func testTheHintReadsTheLabelNotTheURL() {
        let message = flat(SafariBrowserError.documentNotFound(pattern: "window 1 tab 9",
            availableDocuments: ["window 1 tab 1: https://a.example/(window%20id%20)/(window id 5)"]).localizedDescription)
        XCTAssertTrue(message.contains("target one with --window N --tab-in-window M"), message)
    }

    // MARK: verify F8, F10, F13 — what the hint says about the entries it points at

    /// Verify F8: `checkWindowID` labels a record without an id the way `entryLabel` does, so a `--window-id`
    /// miss under `--profile` on legacy records gets the no-id hint, not `--window N` with the profile still set.
    func testAWindowIDMissOnLegacyRecordsUnderAProfileSaysTheyHaveNoID() throws {
        let found = miss(.windowID(999), profile: "Work", in: Self.windows(ids: false))
        XCTAssertEqual(found.entries, [
            "window 2 (no window id): https://work.example/a1",
            "window 3 (no window id): https://work.example/b1",
        ])
        let message = flat(text(found))
        XCTAssertTrue(message.contains("--window N without --profile"), message)
        XCTAssertTrue(message.contains("carry no window id"), message)
        XCTAssertFalse(message.contains("each entry above shows its own coordinates"), message)
        // Copied as the hint says, without --profile, the number selects the window listed.
        XCTAssertEqual(try SafariBridge.pickNativeTarget(.windowIndex(3), in: Self.windows(ids: false)).windowIndex, 3)
    }

    /// Verify F10: a window-level entry names no tab, so the hint does not ask for one it cannot supply.
    func testAWindowLevelListingIsTargetedByWindowIDAlone() {
        for ids in [true, false] {
            let message = flat(text(miss(.documentIndex(99), profile: "Work", in: Self.windows(ids: ids))))
            XCTAssertTrue(message.contains("adding --tab-in-window M where the entry names a tab"), message)
            XCTAssertFalse(message.contains("--window-id W --tab-in-window M,"), message)
            XCTAssertFalse(message.contains("target one with --window N --tab-in-window M"), message)
        }
    }

    /// Verify F13: the miss line repeats what was typed (here the profile's own ordinal, `window 1`); only the
    /// numbers in the entries are Safari's.
    func testTheHintSaysWhichNumbersAreSafarisOwn() {
        let message = flat(text(miss(.windowTab(window: 1, tabInWindow: 99), profile: "Work")))
        XCTAssertTrue(message.contains("The window numbers in the entries are Safari's own"), message)
        XCTAssertFalse(message.contains("The window numbers shown are Safari's own"), message)
    }

    // MARK: verify r2 C — a listing mixing entries with and without a window id

    /// Work's window 2 has id 303, window 3 has none (a record whose id could not be read).
    private static func mixedWindows() -> [SafariBridge.WindowInfo] {
        windows().map { w in
            w.windowIndex == 3
                ? SafariBridge.WindowInfo(windowIndex: 3, currentTabIndex: 1, tabs: w.tabs, profile: w.profile, windowID: nil)
                : w
        }
    }

    /// Each kind of entry is told how it is targeted, and nothing says that no entry carries an id.
    func testAMixedListingTellsEachKindOfEntryHowItIsTargeted() throws {
        let misses: [(SafariBridge.TargetDocument, [String])] = [
            (.documentIndex(99), ["window 2 (window id 303): https://work.example/a1 (2 tab(s))",
                                  "window 3 (no window id): https://work.example/b1 (1 tab(s))"]),
            (.urlMatch(.contains("nothing-matches")), ["window 2 tab 1 (window id 303): https://work.example/a1",
                                                      "window 2 tab 2 (window id 303): https://work.example/a2",
                                                      "window 3 tab 1 (no window id): https://work.example/b1"]),
            (.windowID(999), ["window id 303: https://work.example/a1",
                              "window 3 (no window id): https://work.example/b1"]),
        ]
        for (target, entries) in misses {
            let found = miss(target, profile: "Work", in: Self.mixedWindows())
            XCTAssertEqual(found.entries, entries, "\(target)")
            XCTAssertEqual(SafariBrowserError.listingWindowIDs(found.entries), .mixed, "\(target)")
            let message = flat(text(found))
            XCTAssertTrue(message.contains("--window-id W"), "\(target): \(message)")
            XCTAssertTrue(message.contains("marked (no window id)"), "\(target): \(message)")
            XCTAssertTrue(message.contains("without --profile"), "\(target): \(message)")
            XCTAssertFalse(message.contains("carry no window id"), "\(target): \(message)")
            XCTAssertFalse(message.contains("each entry above"), "\(target): \(message)")
        }
        // Copied as the hint says: the id with or without --profile, the number without it.
        for scope in ["Work", nil] as [String?] {
            XCTAssertEqual(try SafariBridge.pickNativeTarget(.windowID(303), in: Self.mixedWindows(), profile: scope).windowIndex, 2)
        }
        XCTAssertEqual(try SafariBridge.pickNativeTarget(.windowIndex(3), in: Self.mixedWindows()).windowIndex, 3)
    }

    // MARK: verify r2 D — windows without a profile in the listing of a profile with no window

    /// A window without a profile is shown `[(no profile)]`, and no `--profile` selects it: it is reached by its
    /// id without `--profile`, and the hint does not offer it the bracketed profile.
    func testAWindowWithoutAProfileIsReachedWithoutTheFlag() throws {
        let windows = Self.windows().map { w in
            w.windowIndex == 1
                ? SafariBridge.WindowInfo(windowIndex: 1, currentTabIndex: 1, tabs: w.tabs, profile: nil, windowID: 101)
                : w
        }
        let found = miss(.frontWindow, profile: "Wrok", in: windows)
        XCTAssertEqual(found.entries.first, "window 1 [(no profile)] (window id 101): https://home.example/1")
        let message = flat(text(found))
        XCTAssertTrue(message.contains("belong to other profiles"), message)
        XCTAssertTrue(message.contains("A window shown as [(no profile)] has none, and no --profile selects it"), message)
        XCTAssertTrue(message.contains("or, where its brackets name a profile, with that profile"), message)
        XCTAssertFalse(message.contains("or with the profile shown beside it"), message)
        XCTAssertEqual(try SafariBridge.pickNativeTarget(.windowID(101), in: windows).windowIndex, 1)
        XCTAssertThrowsError(try SafariBridge.pickNativeTarget(.windowID(101), in: windows, profile: "(no profile)"))
        for (id, window) in [(303, 2), (404, 3)] {
            XCTAssertEqual(try SafariBridge.pickNativeTarget(.windowID(id), in: windows, profile: "Work").windowIndex, window)
        }
    }

    /// No listed window has a profile (a Safari without profiles): the hint does not say they belong to other
    /// profiles, and does not offer a bracketed profile.
    func testWhenNoListedWindowHasAProfileTheHintSaysSo() throws {
        let windows = Self.windows().map {
            SafariBridge.WindowInfo(windowIndex: $0.windowIndex, currentTabIndex: 1, tabs: $0.tabs, profile: nil, windowID: $0.windowID)
        }
        let found = miss(.frontWindow, profile: "Work", in: windows)
        let message = flat(text(found))
        XCTAssertFalse(message.contains("belong to other profiles"), message)
        XCTAssertFalse(message.contains("brackets name a profile"), message)
        XCTAssertTrue(message.contains("None of the windows listed above has a profile"), message)
        XCTAssertTrue(message.contains("--window-id W"), message)
        XCTAssertEqual(try SafariBridge.pickNativeTarget(.windowID(404), in: windows).windowIndex, 3)
    }

    // MARK: verify r2 B — a URL miss with no tab listed

    /// An empty or notes-only listing has no entry: the URL hint neither refers to listed URLs or coordinates nor
    /// points at `--window N` (under `--profile` that would be the #362 failure), and keeps the substring advice.
    func testAURLMissWithNoTabListedClaimsNoEntries() {
        for listing in [[], ["(no window of profile \"Work\" is open)"]] {
            let message = flat(SafariBrowserError.documentNotFound(pattern: "nothing-matches", availableDocuments: listing).localizedDescription)
            XCTAssertTrue(message.contains("--url matches a *substring* of the URL"), "\(listing): \(message)")
            XCTAssertTrue(message.contains("no tab is listed above"), "\(listing): \(message)")
            XCTAssertFalse(message.contains("coordinates are shown per entry"), "\(listing): \(message)")
            XCTAssertFalse(message.contains("Refine it against the URLs above"), "\(listing): \(message)")
            XCTAssertFalse(message.contains("--window N"), "\(listing): \(message)")
            XCTAssertFalse(message.contains("[N] shown above"), "\(listing): \(message)")
        }
    }

    // MARK: verify F2 — no window of the profile is open

    /// The listing names every other profile's windows by Safari's number and profile, and now by id too; the
    /// hint says what happened and points at the ids, not at the `--url` substring advice or at `--window N`.
    func testAProfileWithNoWindowListsTheOtherProfilesWindowsWithTheirIDs() throws {
        let found = miss(.windowIndex(2), profile: "Wrok")
        XCTAssertEqual(found.pattern, "(profile: \"Wrok\")")
        XCTAssertEqual(found.entries, [
            "window 1 [Home] (window id 101): https://home.example/1",
            "window 2 [Work] (window id 303): https://work.example/a1",
            "window 3 [Work] (window id 404): https://work.example/b1",
        ])
        let message = flat(text(found))
        XCTAssertTrue(message.contains("no window of the profile named in --profile is open"), message)
        XCTAssertTrue(message.contains("--window-id W"), message)
        XCTAssertFalse(message.contains("--url matches a *substring*"), message)
        XCTAssertFalse(message.contains("target one with --window N"), message)
        XCTAssertFalse(message.contains("Or target positionally"), message)
        XCTAssertFalse(message.contains("(no window id)"), message)
        // Copied as the hint says, each id selects the window its entry names, without --profile and with the
        // profile shown in brackets.
        for (id, window, profile) in [(101, 1, "Home"), (303, 2, "Work"), (404, 3, "Work")] {
            for scope in [nil, profile] {
                let resolved = try SafariBridge.pickNativeTarget(.windowID(id), in: Self.windows(), profile: scope)
                XCTAssertEqual(resolved.windowIndex, window, "window id \(id), profile \(scope ?? "none")")
            }
        }
    }

    /// Legacy records carry no id: the entry says so, and the hint gives the way that still works for them.
    func testAProfileWithNoWindowOnLegacyRecordsSaysTheyHaveNoID() throws {
        let found = miss(.frontWindow, profile: "Wrok", in: Self.windows(ids: false))
        XCTAssertEqual(found.entries.first, "window 1 [Home] (no window id): https://home.example/1")
        let message = flat(text(found))
        XCTAssertTrue(message.contains("An entry that says (no window id) is targeted with --window N without --profile"), message)
        XCTAssertFalse(message.contains("--url matches a *substring*"), message)
        let resolved = try SafariBridge.pickNativeTarget(.windowIndex(2), in: Self.windows(ids: false))
        XCTAssertEqual(resolved.windowIndex, 2)
    }

    /// No window at all: there is nothing listed to point at.
    func testAProfileWithNoWindowAndNothingElseOpenListsNothingToCopy() {
        let found = miss(.frontWindow, profile: "Work", in: [])
        XCTAssertEqual(found.entries, [])
        let message = flat(text(found))
        XCTAssertTrue(message.contains("no window of another profile is listed either"), message)
        XCTAssertFalse(message.contains("--window-id W"), message)
        XCTAssertFalse(message.contains("--url matches a *substring*"), message)
    }

    // MARK: verify F12 — the labelled listings redact the URLs they show

    /// Every URL here carries something the redaction removes. The fragment is `fragZ9`, not `frag`, because the
    /// hints themselves say "fragment".
    private static let secretWindows: [FakeSafari.Window] = [
        (101, "Home", ["https://user:pw@home.example/1?token=SECRET#fragZ9"]),
        (303, "Work", ["https://work.example/a1?token=SECRET#fragZ9", "https://user:pw@work.example/a2?token=SECRET"]),
        (404, "Work", ["https://work.example/b1#fragZ9"]),
    ]

    private static func info(_ windows: [FakeSafari.Window]) -> [SafariBridge.WindowInfo] {
        windows.enumerated().map { offset, window in
            SafariBridge.WindowInfo(windowIndex: offset + 1, currentTabIndex: 1,
                                    tabs: window.tabs.enumerated().map { tab($0.offset + 1, $0.element, current: $0.offset == 0) },
                                    profile: window.profile, windowID: window.id)
        }
    }

    private func assertRedacted(_ error: Error, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let renderings = ["\(error)", error.localizedDescription, (error as? LocalizedError)?.errorDescription ?? ""]
        for rendering in renderings {
            for secret in ["SECRET", "fragZ9", "user:pw"] {
                XCTAssertFalse(rendering.contains(secret), "\(what): \(rendering)", file: file, line: line)
            }
        }
    }

    /// The producers whose listings name window ids under `--profile` (the five in the resolver, the listing of a
    /// profile with no window, and the miss translation through a fake Safari), plus `checkWindowID` and
    /// `candidateSummary` for good measure: no rendering of the error, payload included (a daemon prints the
    /// payload), shows a query, a fragment or credentials.
    func testEveryLabelledListingRedactsItsURLs() async throws {
        let windows = Self.info(Self.secretWindows)
        let producers = Self.scopedMisses + [(.windowIndex(1), "Wrok"), (.windowID(999), "Work"), (.windowIndex(9), "Work")]
        for (target, profile) in producers {
            do {
                _ = try SafariBridge.pickNativeTarget(target, in: windows, profile: profile)
                XCTFail("\(target) must miss")
            } catch {
                guard case SafariBrowserError.documentNotFound(_, let entries) = error else { return XCTFail("\(target): \(error)") }
                XCTAssertFalse(entries.isEmpty, "\(target)")
                XCTAssertTrue(entries.allSatisfy { $0.contains("example/") }, "\(target): \(entries)")
                assertRedacted(error, "\(target)")
            }
        }
        let fake = FakeSafari(windows: Self.secretWindows)
        do {
            _ = try await fake.drive {
                try await SafariBridge.getCurrentTitle(target: .resolvedTab(windowID: 202, tabInWindow: 1, rematch: nil, profile: "Work"))
            }
            XCTFail("must miss")
        } catch {
            guard case SafariBrowserError.documentNotFound(_, let entries) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(entries.count, 3, "\(entries)")
            XCTAssertTrue(entries.allSatisfy { $0.contains("(window id ") }, "\(entries)")
            assertRedacted(error, "miss translation")
        }
    }

    /// The miss translation in `runTargetedAppleScript`: a resolved tab carrying a profile whose window is gone.
    func testTheMissTranslationListsTheProfilesTabsWithTheirIDs() async throws {
        let fake = FakeSafari(windows: FakeSafari.workIsTwoAndThree)
        do {
            _ = try await fake.drive {
                try await SafariBridge.getCurrentTitle(target: .resolvedTab(windowID: 202, tabInWindow: 1, rematch: nil, profile: "Work"))
            }
            XCTFail("must miss")
        } catch SafariBrowserError.documentNotFound(_, let entries) {
            XCTAssertEqual(entries, [
                "window 2 tab 1 (window id 303): https://work.example/a1",
                "window 2 tab 2 (window id 303): https://work.example/a2",
                "window 3 tab 1 (window id 404): https://work.example/b1",
            ])
            let message = flat(SafariBrowserError.documentNotFound(pattern: "window id 202 tab 1", availableDocuments: entries).localizedDescription)
            XCTAssertTrue(message.contains("--window-id W") && message.contains("--tab-in-window M"), message)
        }
    }
}
