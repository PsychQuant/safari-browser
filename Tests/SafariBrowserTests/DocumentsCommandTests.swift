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
        isCurrent: Bool = false
    ) -> SafariBridge.DocumentInfo {
        SafariBridge.DocumentInfo(
            index: index,
            window: window,
            tabInWindow: tabInWindow,
            title: title,
            url: url,
            isCurrent: isCurrent
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
}
