import XCTest
@testable import SafariBrowser

final class LocalDataTextBoundaryTests: XCTestCase {
    private let attack = "頁面\u{1B}[2A\u{1B}]52;c;YQ==\u{7}\r\n\t\u{7F}\u{85}\u{2028}\u{2029}\u{202E}\"\\ — forged"
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testEveryLocalDataFieldEscapesTerminalControlsAndEmbeddedSeparators() {
        let rows = [
            HistoryCommand.formatRow(index: 1, visit: HistoryVisit(url: attack, title: attack, visitTime: Date(timeIntervalSince1970: 0), visitCount: 1), timeZone: utc),
            BookmarksCommand.formatRow(index: 2, entry: BookmarkEntry(folder: attack, title: attack, url: attack, isReadingList: true)),
            CloudTabsCommand.formatRow(index: 3, tab: CloudTab(device: attack, title: attack, url: attack)),
            DownloadsCommand.formatRow(index: 4, entry: DownloadEntry(filename: attack, sourceURL: attack, date: nil), timeZone: utc),
        ]
        for row in rows {
            XCTAssertFalse(row.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) || [0x2028, 0x2029, 0x202E].contains($0.value) }, row)
            XCTAssertFalse(row.contains(" — forged"), row)
            XCTAssertTrue(row.contains("\\\"\\\\"), row)
            XCTAssertTrue(row.contains("頁面"), row)
        }
    }

    func testEveryControlRangeAndBidiScalarIsEscaped() {
        let values = Array(UInt32(0)...31) + Array(UInt32(127)...159)
            + [0x061C, 0x200E, 0x200F, 0x2028, 0x2029]
            + Array(UInt32(0x202A)...0x202E) + Array(UInt32(0x2066)...0x2069)
        for value in values {
            let raw = String(UnicodeScalar(value)!)
            XCTAssertFalse(LocalDataOutput.sanitizeTextField(raw).contains(raw), String(value))
        }
        XCTAssertEqual(LocalDataOutput.sanitizeTextField("台灣 😀 café"), "台灣 😀 café")
        XCTAssertFalse(LocalDataOutput.sanitizeTextField("folder  forged ← source — title").contains("  "))
    }

    func testDialogBoundsCountScalarsRatherThanGraphemesAndKeepQuotesBalanced() {
        let raw = "a" + String(repeating: "\u{301}", count: 1000)
        let message = BlockingDialogWarning.messageText(SafariBridge.BlockingDialog(message: raw, buttons: []))
        XCTAssertLessThanOrEqual(message.unicodeScalars.count, 256)
        XCTAssertTrue(message.contains("[truncated]"))
        XCTAssertTrue(message.hasPrefix("\"") && message.hasSuffix("\""))
        for buttons in [Array(repeating: "OK", count: 1000), [String(repeating: "\"", count: 1000)], [raw, "Cancel"]] {
            let rendered = BlockingDialogWarning.buttonsText(SafariBridge.BlockingDialog(message: "", buttons: buttons))
            XCTAssertLessThanOrEqual(rendered.unicodeScalars.count, 256)
            XCTAssertTrue(rendered.contains("[truncated]"))
            XCTAssertFalse(rendered.hasSuffix("\\"))
        }
    }

    func testHistoryUnknownDateIsExplicitAndKnownDatesKeepTheirFormat() {
        let unknown = HistoryVisit(url: "https://example.test", title: nil, visitTime: nil, visitCount: nil)
        XCTAssertEqual(HistoryCommand.formatRow(index: 1, visit: unknown, timeZone: utc), "[1]  (no date)  https://example.test")
        let known = HistoryVisit(url: "https://example.test", title: "Title", visitTime: Date(timeIntervalSince1970: 0), visitCount: 1)
        XCTAssertEqual(HistoryCommand.formatRow(index: 2, visit: known, timeZone: utc), "[2]  1970-01-01 00:00  https://example.test — Title")
    }

    func testJSONPreservesEveryRawField() throws {
        let payloads: [(Data, [String])] = [
            (try HistoryCommand.encodeJSON([HistoryVisit(url: attack, title: attack, visitTime: Date(), visitCount: 1)]), ["url", "title"]),
            (try BookmarksCommand.encodeJSON([BookmarkEntry(folder: attack, title: attack, url: attack, isReadingList: true)]), ["folder", "title", "url"]),
            (try CloudTabsCommand.encodeJSON([CloudTab(device: attack, title: attack, url: attack)]), ["device", "title", "url"]),
            (try DownloadsCommand.encodeJSON([DownloadEntry(filename: attack, sourceURL: attack, date: nil)]), ["filename", "source_url"]),
        ]
        for (data, keys) in payloads {
            let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            for key in keys { XCTAssertEqual(rows[0][key] as? String, attack) }
        }
    }

    func testDialogWarningEscapesQuotesAndBoundsMessageAndAggregateButtons() {
        let dialog = SafariBridge.BlockingDialog(message: attack, buttons: [attack])
        let line = BlockingDialogWarning.firstLine(windowKey: .id(7), dialog: dialog)
        XCTAssertFalse(line.contains("\u{1B}"))
        XCTAssertFalse(line.contains("\u{202E}"))
        XCTAssertTrue(line.contains("\\\""))
        let huge = SafariBridge.BlockingDialog(message: String(repeating: "\u{1B}", count: 1000), buttons: Array(repeating: String(repeating: "x", count: 1000), count: 100))
        for field in [BlockingDialogWarning.messageText(huge), BlockingDialogWarning.buttonsText(huge)] {
            XCTAssertLessThanOrEqual(field.unicodeScalars.count, 256)
            XCTAssertTrue(field.contains("[truncated]"))
        }
    }

    func testAllDialogErrorsUseSafeFieldsAndCannotForgeNumberedLines() {
        let errors: [SafariBrowserError] = [
            .javaScriptDialogBlocking(message: attack, buttons: [attack]),
            .ambiguousBlockingDialog(messages: [attack, "real"]),
            .dialogButtonNotFound(titled: attack, available: [attack]),
            .dialogButtonAmbiguous(titled: attack, count: 2),
            .dialogChangedBeforePress(nowMessage: attack, nowButtons: [attack]),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.contains("\u{1B}"), text)
            XCTAssertFalse(text.contains("\u{202E}"), text)
            XCTAssertTrue(text.contains("\\\""), text)
            XCTAssertFalse(text.contains("\n\t"), text)
        }
    }

    func testDismissPreambleAlsoEscapesTheNamedButton() {
        let dialog = SafariBridge.BlockingDialog(message: "message", buttons: [attack])
        let output = DialogDismissCommand.preamble(for: dialog, pressing: attack)
        XCTAssertFalse(output.contains("\u{1B}"))
        XCTAssertFalse(output.contains("\u{202E}"))
        XCTAssertTrue(output.contains("\\\""))
        XCTAssertEqual(output.components(separatedBy: "\n").count, 3)
    }

    func testRenderingDoesNotAlterRawButtonMatching() {
        let dialog = SafariBridge.BlockingDialog(message: attack, buttons: [attack, "Cancel"])
        _ = BlockingDialogWarning.buttonsText(dialog)
        XCTAssertEqual(DialogDismissCommand.selectButton(titled: attack, from: dialog.buttons), .found(index: 0))
        XCTAssertEqual(DialogDismissCommand.selectButton(titled: BlockingDialogWarning.buttonsText(dialog), from: dialog.buttons), .notFound(available: dialog.buttons))
        XCTAssertEqual(dialog.message, attack)
    }
}
