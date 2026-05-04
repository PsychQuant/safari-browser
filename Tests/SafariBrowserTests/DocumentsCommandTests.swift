import XCTest
@testable import SafariBrowser

/// Tests for the `documents` subcommand's output format. Exercises the
/// pure `formatText` formatter against `DocumentInfo` fixtures so tests
/// do not require a live Safari.
///
/// Corresponds to the `document-listing` spec's "List all Safari
/// documents" requirement (tab-level enumeration, current-tab
/// indicator, cross-command consistency).
final class DocumentsCommandTests: XCTestCase {

    private func doc(
        index: Int,
        window: Int,
        tabInWindow: Int,
        url: String,
        title: String = "",
        isCurrent: Bool = false,
        profile: String? = nil
    ) -> SafariBridge.DocumentInfo {
        SafariBridge.DocumentInfo(
            index: index,
            window: window,
            tabInWindow: tabInWindow,
            title: title,
            url: url,
            isCurrent: isCurrent,
            profile: profile
        )
    }

    // MARK: - Text output format

    func testFormatTextIncludesWindowAndTabInWindow() {
        let docs = [
            doc(index: 1, window: 1, tabInWindow: 1, url: "https://a.com",
                title: "Alpha", isCurrent: true),
            doc(index: 2, window: 1, tabInWindow: 2, url: "https://b.com",
                title: "Beta"),
        ]
        let lines = DocumentsCommand.formatText(docs)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("w1.t1"),
                      "First line must expose (window, tab-in-window) coordinate")
        XCTAssertTrue(lines[1].contains("w1.t2"))
        XCTAssertTrue(lines[0].contains("https://a.com"))
        XCTAssertTrue(lines[0].contains("Alpha"))
    }

    func testFormatTextMarksCurrentTabWithAsterisk() {
        let docs = [
            doc(index: 1, window: 1, tabInWindow: 1, url: "https://a", isCurrent: false),
            doc(index: 2, window: 1, tabInWindow: 2, url: "https://b", isCurrent: true),
        ]
        let lines = DocumentsCommand.formatText(docs)
        XCTAssertFalse(lines[0].contains("*"),
                       "Background tab must not carry current-tab marker")
        XCTAssertTrue(lines[1].contains("*"),
                      "Current tab must carry * marker")
    }

    func testFormatTextExposesAllTabsAcrossMultipleWindows() {
        // List all Safari documents — multi-window multi-tab scenario
        // must show every tab, including background ones.
        let docs = [
            doc(index: 1, window: 1, tabInWindow: 1, url: "https://a", isCurrent: true),
            doc(index: 2, window: 1, tabInWindow: 2, url: "https://b"),  // background
            doc(index: 3, window: 2, tabInWindow: 1, url: "https://c", isCurrent: true),
        ]
        let lines = DocumentsCommand.formatText(docs)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.contains(where: { $0.contains("https://a") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("https://b") }),
                      "Background tab in window 1 must appear")
        XCTAssertTrue(lines.contains(where: { $0.contains("w2.t1") }))
    }

    func testEmptyDocumentsProducesNoLines() {
        let lines = DocumentsCommand.formatText([])
        XCTAssertTrue(lines.isEmpty)
    }

    // MARK: - Global index invariant

    func testGlobalIndexMatchesArrayPosition() {
        let docs = [
            doc(index: 1, window: 1, tabInWindow: 1, url: "https://a", isCurrent: true),
            doc(index: 2, window: 2, tabInWindow: 1, url: "https://b", isCurrent: true),
        ]
        let lines = DocumentsCommand.formatText(docs)
        XCTAssertTrue(lines[0].hasPrefix("[1]"))
        XCTAssertTrue(lines[1].hasPrefix("[2]"))
    }

    // MARK: - Profile column auto-detection (Issue #47)
    //
    // formatText auto-detects whether ANY doc has a non-nil profile.
    // - All-nil → no [profile] column → bit-exact pre-#47 output
    //   (zero break for legacy parser scripts on single-profile setups)
    // - Any non-nil → [profile] column appears for every row,
    //   nil-profile rows show "[-]" so the column is regular

    func testFormatTextOmitsProfileColumnWhenAllNil() {
        let docs = [
            doc(index: 1, window: 1, tabInWindow: 1, url: "https://a", title: "A", isCurrent: true, profile: nil),
            doc(index: 2, window: 2, tabInWindow: 1, url: "https://b", title: "B", isCurrent: true, profile: nil),
        ]
        let lines = DocumentsCommand.formatText(docs)
        // Legacy bit-exact format — single profile / pre-Safari-17 envs
        // see no [profile] column at all (zero break for parser scripts)
        XCTAssertEqual(lines[0], "[1] * w1.t1  https://a — A")
        XCTAssertEqual(lines[1], "[2] * w2.t1  https://b — B")
    }

    func testFormatTextIncludesProfileColumnWhenAnyHasProfile() {
        let docs = [
            doc(index: 1, window: 1, tabInWindow: 1, url: "https://a", title: "A", isCurrent: true, profile: "個人"),
            doc(index: 2, window: 2, tabInWindow: 1, url: "https://b", title: "B", isCurrent: true, profile: "工作"),
        ]
        let lines = DocumentsCommand.formatText(docs)
        XCTAssertTrue(lines[0].contains("[個人]"))
        XCTAssertTrue(lines[1].contains("[工作]"))
        // Profile column comes after wN.tM and before url
        let firstIdxOfProfile = lines[0].range(of: "[個人]")!.lowerBound
        let firstIdxOfWindow = lines[0].range(of: "w1.t1")!.lowerBound
        let firstIdxOfURL = lines[0].range(of: "https")!.lowerBound
        XCTAssertLessThan(firstIdxOfWindow, firstIdxOfProfile)
        XCTAssertLessThan(firstIdxOfProfile, firstIdxOfURL)
    }

    func testFormatTextMixedProfileShowsDashForNil() {
        let docs = [
            doc(index: 1, window: 1, tabInWindow: 1, url: "https://a", title: "A", isCurrent: true, profile: "個人"),
            doc(index: 2, window: 2, tabInWindow: 1, url: "https://b", title: "B", isCurrent: true, profile: nil),
        ]
        let lines = DocumentsCommand.formatText(docs)
        XCTAssertTrue(lines[0].contains("[個人]"))
        XCTAssertTrue(lines[1].contains("[-]"),
                      "Window with nil profile in mixed list shows [-] placeholder so column stays aligned")
    }
}
