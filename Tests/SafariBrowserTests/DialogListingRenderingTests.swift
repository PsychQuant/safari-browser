import Foundation
import XCTest
@testable import SafariBrowser

final class DialogListingRenderingTests: XCTestCase {
    private func observation(message: String = "請確認") -> WindowDialogObservation {
        var snapshot = DialogTreeSnapshot<Int>()
        snapshot.observedWindowIDs = [71, 72]
        snapshot.candidates = [CapturedDialog(
            windowID: 72, element: 1,
            dialog: .init(message: message, buttons: ["OK"]), buttons: [])]
        return WindowDialogObservation(snapshot: snapshot)
    }

    private func document(
        index: Int, window: Int, tab: Int = 1, profile: String? = nil, id: Int?
    ) -> SafariBridge.DocumentInfo {
        .init(index: index, window: window, tabInWindow: tab,
              title: "分頁 \(index)", url: "https://example.test/\(index)",
              isCurrent: tab == 1, profile: profile, windowID: id)
    }

    func testDocumentsAssociateStableIDsAndPreserveProfilesAndGlobalIndices() throws {
        let documents = [
            document(index: 4, window: 1, profile: "工作", id: 72),
            document(index: 5, window: 1, tab: 2, profile: "工作", id: 72),
            document(index: 8, window: 3, id: 71),
        ]
        let captured = observation()
        let legacy = DocumentsCommand.formatText(documents)
        let rendered = DocumentsCommand.formatText(documents, observation: captured)
        let suffix = try XCTUnwrap(captured.status(for: 72).textSuffix)
        XCTAssertEqual(rendered.count, 3)
        XCTAssertEqual(rendered[0], legacy[0] + " " + suffix)
        XCTAssertEqual(rendered[1], legacy[1] + " " + suffix)
        XCTAssertEqual(rendered[2], legacy[2])

        let rows = DocumentsCommand.jsonRows(documents, observation: captured)
        XCTAssertEqual(rows.compactMap { $0["index"] as? Int }, [4, 5, 8])
        XCTAssertEqual(rows.compactMap { $0["window"] as? Int }, [1, 1, 3])
        XCTAssertEqual(rows[0]["profile"] as? String, "工作")
        XCTAssertTrue(rows[2]["profile"] is NSNull)
        let statuses = rows.compactMap { $0["blocking_dialog"] as? [String: Any] }
        XCTAssertEqual(statuses.compactMap { $0["state"] as? String }, ["present", "present", "clear"])
        XCTAssertEqual(statuses.compactMap { $0["window_id"] as? Int }, [72, 72, 71])
        XCTAssertEqual(Set(statuses[0].keys), ["state", "window_id", "messages", "reason"])
        XCTAssertEqual(statuses[0]["messages"] as? [String], ["請確認"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: rows))
    }

    func testTabsAppendFourthTSVFieldAndEscapeDialogTextOnly() throws {
        let message = "一行\n二行\t\"quoted\"\\終點"
        let captured = observation(message: message)
        let tabs = [
            SafariBridge.TabInfo(index: 3, title: "背景分頁", url: "https://example.test/3", windowID: 72),
            SafariBridge.TabInfo(index: 1, title: "目前分頁", url: "https://example.test/1", windowID: 71),
        ]
        let rendered = TabsCommand.formatText(tabs, observation: captured)
        XCTAssertEqual(rendered[0].components(separatedBy: "\t").count, 4)
        XCTAssertEqual(Array(rendered[0].components(separatedBy: "\t").prefix(3)),
                       ["3", "背景分頁", "https://example.test/3"])
        XCTAssertFalse(rendered[0].contains("\n"))
        // Existing dialog rendering folds line breaks and escapes TSV controls.
        XCTAssertTrue(rendered[0].contains("一行 二行"))
        XCTAssertTrue(rendered[0].contains("\\t"))
        XCTAssertTrue(rendered[0].contains("\\\"quoted\\\"\\\\終點"))
        XCTAssertEqual(rendered[1], "1\t目前分頁\thttps://example.test/1")
        let rows = TabsCommand.jsonRows(tabs, observation: captured)
        XCTAssertEqual(rows.compactMap { $0["index"] as? Int }, [3, 1])
        XCTAssertEqual(rows[0]["title"] as? String, "背景分頁")
        let status = try XCTUnwrap(rows[0]["blocking_dialog"] as? [String: Any])
        XCTAssertEqual(status["messages"] as? [String], [message])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: rows))
    }

    func testMissingAndUnobservedIdentitiesAreExplicitlyUnknown() throws {
        let captured = observation()
        let documents = [document(index: 1, window: 1, id: nil), document(index: 2, window: 2, id: 99)]
        let rows = DocumentsCommand.jsonRows(documents, observation: captured)
        let statuses = rows.compactMap { $0["blocking_dialog"] as? [String: Any] }
        XCTAssertEqual(statuses.compactMap { $0["state"] as? String }, ["unknown", "unknown"])
        XCTAssertEqual(statuses.compactMap { $0["reason"] as? String }, ["missingID", "notobserved"])
        XCTAssertTrue(statuses[0]["window_id"] is NSNull)
        XCTAssertTrue(DocumentsCommand.formatText(documents, observation: captured).allSatisfy {
            $0.contains("[dialog: unknown")
        })
        let tabs = [SafariBridge.TabInfo(index: 1, title: "", url: "", windowID: nil)]
        let line = try XCTUnwrap(TabsCommand.formatText(tabs, observation: captured).first)
        XCTAssertEqual(line.components(separatedBy: "\t").count, 4)
        XCTAssertTrue(line.hasPrefix("1\t\t\t[dialog: unknown"))
    }

    func testUnavailableObservationPreservesOrdinaryRowsAndExplainsUnknown() throws {
        let captured = WindowDialogObservation.unavailable(reason: "disabled")
        let tabs = [SafariBridge.TabInfo(index: 7, title: "Title", url: "https://example.test", windowID: 71)]
        let line = try XCTUnwrap(TabsCommand.formatText(tabs, observation: captured).first)
        XCTAssertEqual(line, "7\tTitle\thttps://example.test\t[dialog: unknown (disabled)]")
        let status = try XCTUnwrap(TabsCommand.jsonRows(tabs, observation: captured)[0]["blocking_dialog"] as? [String: Any])
        XCTAssertEqual(status["state"] as? String, "unknown")
        XCTAssertEqual(status["reason"] as? String, "disabled")
    }

    func testEmptyListingsNeverCreateSyntheticRows() {
        let captured = observation()
        XCTAssertTrue(DocumentsCommand.formatText([], observation: captured).isEmpty)
        XCTAssertTrue(DocumentsCommand.jsonRows([], observation: captured).isEmpty)
        XCTAssertTrue(TabsCommand.formatText([], observation: captured).isEmpty)
        XCTAssertTrue(TabsCommand.jsonRows([], observation: captured).isEmpty)
    }

    func testDocumentsCaptureOnceAfterProfileFilteringForEachOutputMode() async throws {
        let captured = observation()
        let records = [
            ["1", "1", "1", "https://personal.test", "Personal", "個人 — Personal", "71"],
            ["2", "1", "1", "https://work.test/1", "Work 1", "工作 — Work", "72"],
            ["2", "2", "0", "https://work.test/2", "Work 2", "工作 — Work", "72"],
        ].map { $0.joined(separator: "\u{1D}") }.joined(separator: "\u{1E}")
        for arguments in [["--profile", "工作"], ["--profile", "工作", "--json"]] {
            let calls = ExecSubprocessOutputTests.Output()
            let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            let command = try DocumentsCommand.parse(arguments)
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in records }) {
                    try await WindowDialogObservation.$provider.withValue({
                        calls.append("capture")
                        return captured
                    }) { try await command.run() }
                }
            }
            XCTAssertEqual(calls.text, "capture")
        }
    }

    func testTabsCaptureOnceForAllRowsInEachOutputMode() async throws {
        let captured = observation()
        for arguments in [[], ["--json"]] as [[String]] {
            let calls = ExecSubprocessOutputTests.Output()
            let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
            let command = try TabsCommand.parse(arguments)
            try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                    if source.contains("get id of") { return "72" }
                    if source.contains("count of tabs") { return "2" }
                    if source.contains("get name of") { return "Work" }
                    return "https://work.test"
                }) {
                    try await WindowDialogObservation.$provider.withValue({
                        calls.append("capture")
                        return captured
                    }) { try await command.run() }
                }
            }
            XCTAssertEqual(calls.text, "capture")
        }
    }

    func testEmptyCommandsDoNotCaptureIncludingProfileFilteredDocuments() async throws {
        let calls = ExecSubprocessOutputTests.Output()
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let documents = try DocumentsCommand.parse(["--json", "--profile", "工作"])
        let tabs = try TabsCommand.parse(["--json"])
        try await DaemonRequestContext.$current.withValue(context) {
            try await WindowDialogObservation.$provider.withValue({
                calls.append("unexpected capture")
                return .unavailable(reason: "unavailable")
            }) {
                let personal = ["1", "1", "1", "https://personal.test", "Personal", "個人 — Personal", "71"]
                    .joined(separator: "\u{1D}")
                try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in personal }) {
                    try await documents.run()
                }
                try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in "0" }) {
                    try await tabs.run()
                }
            }
        }
        XCTAssertEqual(calls.text, "")
    }

    func testDialogLegendExplainsWindowScopeAndUnknown() {
        for commandName in ["documents", "tabs"] {
            let legend = DocumentsCommand.dialogLegendLine(commandName: commandName)
            XCTAssertTrue(legend.hasPrefix(commandName + ":"))
            XCTAssertTrue(legend.contains("visible native dialogs of the window"))
            XCTAssertTrue(legend.contains("unknown"))
            XCTAssertTrue(legend.contains("every tab"))
            XCTAssertTrue(legend.contains("background pending dialogs"))
            XCTAssertTrue(legend.contains("blocking_dialog"))
        }
    }
}
