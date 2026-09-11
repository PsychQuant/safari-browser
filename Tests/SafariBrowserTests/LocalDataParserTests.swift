import ArgumentParser
import Darwin
import Foundation
import SQLite3
import XCTest

@testable import SafariBrowser

final class LocalDataParserTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("data-parsers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func plist(_ value: Any) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".plist")
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: url)
        return url
    }

    private func database(_ statements: String) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statements, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return url
    }

    private let historySchema = "CREATE TABLE history_items(id INTEGER PRIMARY KEY, url, visit_count); CREATE TABLE history_visits(history_item, title, visit_time);"
    private let cloudSchema = "CREATE TABLE cloud_tabs(device_uuid, title, url); CREATE TABLE cloud_tab_devices(device_uuid, device_name);"

    private func leaf(_ url: Any? = "https://example.test", title: String = "Example") -> [String: Any] {
        var result: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeLeaf", "URIDictionary": ["title": title]]
        result["URLString"] = url
        return result
    }

    private func assertSchemaFailure(_ body: () throws -> Void, field: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case SafariBrowserError.safariDataParseFailed(_, let detail) = error else {
                return XCTFail("expected schema error, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(detail.contains(field), detail, file: file, line: line)
            XCTAssertTrue(detail.contains("["), "diagnostic must identify an entry: \(detail)", file: file, line: line)
        }
    }

    func testBookmarksNestedReadingListAndUntypedContainers() throws {
        let url = try plist(["Children": [["WebBookmarkType": "WebBookmarkTypeList", "Title": "Saved", "Children": [leaf()]], ["WebBookmarkType": "WebBookmarkTypeList", "Title": BookmarksCommand.readingListFolderTitle, "Children": [["Children": [leaf("https://reading.test")]]]]]])
        let entries = try BookmarksCommand.entries(inPlistAt: url)
        XCTAssertEqual(entries.map(\.folder), ["Saved", "com.apple.ReadingList"])
        XCTAssertEqual(entries.map(\.isReadingList), [false, true])
    }

    func testBookmarksAllInvalidLeavesFailWithFieldAndLocation() throws {
        let url = try plist(["Children": [leaf(nil), leaf(42)]])
        assertSchemaFailure({ _ = try BookmarksCommand.entries(inPlistAt: url) }, field: "URLString")
    }

    func testBookmarksNonDictionaryChildDoesNotDiscardGoodSiblings() throws {
        let url = try plist(["Children": [leaf(), "broken"]])
        XCTAssertEqual(try BookmarksCommand.entries(inPlistAt: url).count, 1)
    }

    func testBookmarksUnknownNonemptyNodeAndWrongChildrenTypeFail() throws {
        for value: [String: Any] in [["RenamedChildren": [leaf()]], ["Children": "wrong"]] {
            let url = try plist(value)
            assertSchemaFailure({ _ = try BookmarksCommand.entries(inPlistAt: url) }, field: "Children")
        }
    }

    func testDownloadsMissingOptionalFieldsAndNilDateOrdering() throws {
        let url = try plist(["DownloadHistory": [["DownloadEntryPath": "/tmp/no-date-a"], ["DownloadEntryPath": "/tmp/older", "DownloadEntryDateAddedKey": Date(timeIntervalSince1970: 100)], ["DownloadEntryPath": "/tmp/newer", "DownloadEntryDateAddedKey": Date(timeIntervalSince1970: 200)], ["DownloadEntryPath": "/tmp/no-date-b"]]])
        let entries = try DownloadsCommand.entries(inPlistAt: url, limit: 10)
        XCTAssertEqual(entries.map(\.filename), ["newer", "older", "no-date-a", "no-date-b"])
        XCTAssertNil(entries.last?.date)
        XCTAssertEqual(entries.last?.sourceURL, "")
        XCTAssertEqual(try DownloadsCommand.entries(inPlistAt: url, limit: 1).map(\.filename), ["newer"])
        XCTAssertNil(DownloadsCommand.parse(["DownloadEntryURL": "https://example.test"]))
    }

    func testDownloadsAllInvalidFailAndMixedTypesKeepValidRows() throws {
        let broken = try plist(["DownloadHistory": [["RenamedPath": "/tmp/file"]]])
        assertSchemaFailure({ _ = try DownloadsCommand.entries(inPlistAt: broken, limit: 10) }, field: "DownloadEntryPath")
        let mixed = try plist(["DownloadHistory": [["DownloadEntryPath": "/tmp/good"], "bad"]])
        XCTAssertEqual(try DownloadsCommand.entries(inPlistAt: mixed, limit: 10).map(\.filename), ["good"])
    }

    func testCloudTabsRealSchemaLeftJoinAndOptionalFields() throws {
        let url = try database(cloudSchema + "INSERT INTO cloud_tab_devices VALUES ('known', 'My Mac'); INSERT INTO cloud_tabs VALUES ('known','Title','https://known.test'),('missing',NULL,'https://unknown.test');")
        let tabs = try CloudTabsCommand.tabs(inDatabaseAt: url)
        XCTAssertEqual(tabs.count, 2)
        XCTAssertTrue(tabs.contains(CloudTab(device: "My Mac", title: "Title", url: "https://known.test")))
        XCTAssertTrue(tabs.contains(CloudTab(device: "(unknown device)", title: "", url: "https://unknown.test")))
    }

    func testCloudAllInvalidURLsFail() throws {
        let url = try database(cloudSchema + "INSERT INTO cloud_tabs VALUES ('x','Title',NULL),('x','Title',42);")
        assertSchemaFailure({ _ = try CloudTabsCommand.tabs(inDatabaseAt: url) }, field: "url")
    }

    func testHistoryOptionalTimeAndCountAreNotInvented() throws {
        let url = try database(historySchema + "INSERT INTO history_items VALUES (1,'https://example.test',NULL); INSERT INTO history_visits VALUES (1,NULL,NULL);")
        let visits = try HistoryCommand.visits(inDatabaseAt: url, search: nil, since: nil, limit: 10)
        XCTAssertEqual(visits.count, 1)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: HistoryCommand.encodeJSON(visits)) as? [[String: Any]])
        XCTAssertTrue(payload.first?["visit_time"] is NSNull)
        XCTAssertTrue(payload.first?["visit_count"] is NSNull)
    }

    func testHistoryInvalidURLsFailEvenWhenSearchWouldNotMatch() throws {
        let url = try database(historySchema + "INSERT INTO history_items VALUES (1,NULL,1); INSERT INTO history_visits VALUES (1,'Valid Title',200);")
        assertSchemaFailure({ _ = try HistoryCommand.visits(inDatabaseAt: url, search: "not-found", since: nil, limit: 10) }, field: "url")
    }

    func testHistoryUnicodeSearchSinceAndAcceptedLimit() throws {
        let url = try database(historySchema + "INSERT INTO history_items VALUES (1,'https://first.test',1),(2,'https://second.test',2),(3,'https://third.test',3); INSERT INTO history_visits VALUES (1,'other',300),(2,'ÉCOLE',200),(3,'école',100);")
        XCTAssertEqual(try HistoryCommand.visits(inDatabaseAt: url, search: "école", since: nil, limit: 1).map(\.url), ["https://second.test"])
        XCTAssertEqual(try HistoryCommand.visits(inDatabaseAt: url, search: nil, since: HistoryCommand.date(fromCoreDataReferenceTime: 200), limit: 10).count, 2)
        XCTAssertEqual(try HistoryCommand.visits(inDatabaseAt: url, search: "no-match", since: nil, limit: 10), [])
    }

    func testAllParsersAcceptEmptySources() throws {
        XCTAssertEqual(try BookmarksCommand.entries(inPlistAt: plist(["Children": []])), [])
        XCTAssertEqual(try DownloadsCommand.entries(inPlistAt: plist(["DownloadHistory": []]), limit: 10), [])
        XCTAssertEqual(try CloudTabsCommand.tabs(inDatabaseAt: database(cloudSchema)), [])
        XCTAssertEqual(try HistoryCommand.visits(inDatabaseAt: database(historySchema), search: nil, since: nil, limit: 10), [])
    }
    /// Capture the actual command bodies at the file-descriptor boundary,
    /// using files rather than pipes so large output cannot deadlock a writer.
    private func output(_ body: () throws -> Void) throws -> (stdout: String, stderr: String, error: Error?) {
        let outURL = directory.appendingPathComponent(UUID().uuidString + ".stdout")
        let errURL = directory.appendingPathComponent(UUID().uuidString + ".stderr")
        let out = open(outURL.path, O_CREAT | O_RDWR | O_TRUNC, S_IRUSR | S_IWUSR)
        let err = open(errURL.path, O_CREAT | O_RDWR | O_TRUNC, S_IRUSR | S_IWUSR)
        guard out >= 0, err >= 0 else {
            if out >= 0 { close(out) }
            if err >= 0 { close(err) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(out); close(err) }
        fflush(nil)
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        guard savedOut >= 0, savedErr >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(savedOut); close(savedErr) }
        dup2(out, STDOUT_FILENO)
        dup2(err, STDERR_FILENO)
        let error: Error?
        do { try body(); error = nil } catch let caught { error = caught }
        fflush(nil)
        dup2(savedOut, STDOUT_FILENO)
        dup2(savedErr, STDERR_FILENO)
        return (try String(contentsOf: outURL, encoding: .utf8), try String(contentsOf: errURL, encoding: .utf8), error)
    }

    private func commandBodies(json: Bool = true) throws -> [(URL) throws -> Void] {
        let arguments = json ? ["--json"] : []
        let history = try HistoryCommand.parse(arguments)
        let bookmarks = try BookmarksCommand.parse(arguments)
        let cloud = try CloudTabsCommand.parse(arguments)
        let downloads = try DownloadsCommand.parse(arguments)
        return [history.run(sourceURL:), bookmarks.run(sourceURL:), cloud.run(sourceURL:), downloads.run(sourceURL:)]
    }

    func testEveryCommandAbsentSourceSucceedsWithJSONOnlyOnStdout() throws {
        let missing = directory.appendingPathComponent("missing")
        for command in try commandBodies() {
            let captured = try output { try command(missing) }
            XCTAssertEqual((captured.error.map { HistoryCommand.exitCode(for: $0) } ?? .success), .success)
            XCTAssertEqual(captured.stdout, "[]\n")
            XCTAssertTrue(captured.stderr.contains("does not exist"))
            XCTAssertFalse(captured.stdout.contains("normal"))
        }
    }

    func testEveryCommandDeniedSourceFailsInsteadOfReportingAbsent() throws {
        // Running as the normal developer user makes POSIX mode 000 a real
        // permission denial. Never turn an unexercised assertion into a pass.
        guard geteuid() != 0 else { throw XCTSkip("root bypasses file permissions") }
        let denied = try plist(["Children": []])
        XCTAssertEqual(chmod(denied.path, 0), 0)
        defer { chmod(denied.path, S_IRUSR | S_IWUSR) }
        for command in try commandBodies() {
            let captured = try output { try command(denied) }
            XCTAssertNotEqual((captured.error.map { HistoryCommand.exitCode(for: $0) } ?? .success), .success)
            guard case SafariBrowserError.fullDiskAccessRequired? = captured.error as? SafariBrowserError else {
                XCTFail("expected FDA denial, got \(String(describing: captured.error))")
                continue
            }
            XCTAssertEqual(captured.stdout, "")
            XCTAssertFalse(captured.stderr.contains("does not exist"))
        }
    }

    func testEveryCommandRejectsMalformedSourceWithNonzeroExit() throws {
        let sources = try [
            database(historySchema + "INSERT INTO history_items VALUES (1,NULL,1); INSERT INTO history_visits VALUES (1,NULL,1);"),
            plist(["Children": [leaf(nil)]]),
            database(cloudSchema + "INSERT INTO cloud_tabs VALUES ('x',NULL,NULL);"),
            plist(["DownloadHistory": [["UnknownPath": "value"]]])
        ]
        for (command, source) in zip(try commandBodies(), sources) {
            let captured = try output { try command(source) }
            XCTAssertNotEqual((captured.error.map { HistoryCommand.exitCode(for: $0) } ?? .success), .success)
            XCTAssertEqual(captured.stdout, "")
            guard case SafariBrowserError.safariDataParseFailed(let path, _)? = captured.error as? SafariBrowserError else {
                XCTFail("expected parse failure, got \(String(describing: captured.error))")
                continue
            }
            XCTAssertEqual(path, source.path)
        }
    }

    func testAllPartialParsersWarnOnStderrAndKeepJSONValid() throws {
        let sources = try [
            database(historySchema + "INSERT INTO history_items VALUES (1,NULL,1),(2,'https://good.test',1); INSERT INTO history_visits VALUES (1,NULL,200),(2,'Good',100);"),
            plist(["Children": [leaf(nil), leaf()]]),
            database(cloudSchema + "INSERT INTO cloud_tabs VALUES ('x','Bad',NULL),('x','Good','https://good.test');"),
            plist(["DownloadHistory": [["UnknownPath": "bad"], ["DownloadEntryPath": "/tmp/good"]]])
        ]
        for (command, source) in zip(try commandBodies(), sources) {
            let captured = try output { try command(source) }
            XCTAssertNil(captured.error)
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(captured.stdout.utf8)) as? [[String: Any]])
            XCTAssertEqual(decoded.count, 1)
            XCTAssertTrue(captured.stderr.contains("1 malformed"), captured.stderr)
            XCTAssertTrue(captured.stderr.contains("[0]"), captured.stderr)
            XCTAssertFalse(captured.stdout.contains("Warning:"))
        }
    }

    func testAllTextCommandLegendsStayOnStderr() throws {
        let sources = try [
            database(historySchema + "INSERT INTO history_items VALUES (1,'https://good.test',1); INSERT INTO history_visits VALUES (1,'Good',100);"),
            plist(["Children": [leaf()]]),
            database(cloudSchema + "INSERT INTO cloud_tabs VALUES ('x','Good','https://good.test');"),
            plist(["DownloadHistory": [["DownloadEntryPath": "/tmp/good"]]])
        ]
        for (command, source) in zip(try commandBodies(json: false), sources) {
            let captured = try output { try command(source) }
            XCTAssertNil(captured.error)
            XCTAssertTrue(captured.stdout.hasPrefix("[1]"), captured.stdout)
            XCTAssertTrue(captured.stderr.contains("[N]"), captured.stderr)
            XCTAssertFalse(captured.stdout.contains("[N]"))
        }
    }

    func testBookmarksSearchCombinesFolderAndTitleURLAndPreservesReadingList() throws {
        let source = try plist(["Children": [
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Other École", "Children": [leaf("https://other.test", title: "Unrelated")]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [leaf("https://a.test", title: "ÉCOLE"), leaf("https://b.test/École", title: "By URL"), leaf("https://c.test", title: "Other")]]
        ]])
        let command = try BookmarksCommand.parse(["--json", "--search", "école", "--folder", "READINGLIST"])
        let captured = try output { try command.run(sourceURL: source) }
        XCTAssertNil(captured.error)
        XCTAssertEqual(captured.stderr, "")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(captured.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(decoded.count, 2)
        XCTAssertTrue(decoded.allSatisfy { $0["reading_list"] as? Bool == true })
        let textCommand = try BookmarksCommand.parse(["--search", "école", "--folder", "READINGLIST"])
        let text = try output { try textCommand.run(sourceURL: source) }
        XCTAssertNil(text.error)
        XCTAssertEqual(text.stdout.components(separatedBy: "[reading-list]").count - 1, 2)
        let onlyFolderMatch = try BookmarksCommand.parse(["--json", "--search", "école", "--folder", "Other"])
        let empty = try output { try onlyFolderMatch.run(sourceURL: source) }
        XCTAssertNil(empty.error)
        XCTAssertEqual(empty.stdout, "[]\n", "folder name is not a search field")
        XCTAssertEqual(empty.stderr, "")
    }

    func testHistoryLimitCountsGoodRowsAndMalformedOrphanIsVisible() throws {
        let source = try database(historySchema + "INSERT INTO history_items VALUES (1,'https://good.test',1); INSERT INTO history_visits VALUES (99,'Orphan',300),(1,'Good',200),(1,'Older',100);")
        let captured = try output {
            XCTAssertEqual(try HistoryCommand.visits(inDatabaseAt: source, search: nil, since: nil, limit: 1).map(\.url), ["https://good.test"])
        }
        XCTAssertNil(captured.error)
        XCTAssertTrue(captured.stderr.contains("1 malformed"))
        XCTAssertTrue(captured.stderr.contains("row[0].url"))
    }

    func testValidFilteredRowsDoNotTurnPartialDamageIntoAllInvalidError() throws {
        let source = try database(historySchema + "INSERT INTO history_items VALUES (1,NULL,1),(2,'https://good.test',1); INSERT INTO history_visits VALUES (1,'Bad',300),(2,'Good',200);")
        let captured = try output {
            XCTAssertEqual(try HistoryCommand.visits(inDatabaseAt: source, search: "absent", since: nil, limit: 1), [])
        }
        XCTAssertNil(captured.error)
        XCTAssertTrue(captured.stderr.contains("1 malformed"))
    }

    func testExplicitBookmarkListsMayOmitChildrenWhileOtherNodesStillFail() throws {
        let source = try plist(["Children": [
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Empty", "WebBookmarkUUID": "fixture", "Sync": [:]],
            leaf()
        ]])
        let captured = try output {
            XCTAssertEqual(try BookmarksCommand.entries(inPlistAt: source).map(\.url), ["https://example.test"])
        }
        XCTAssertNil(captured.error)
        XCTAssertEqual(captured.stderr, "")
        let emptyList = try plist(["WebBookmarkType": "WebBookmarkTypeList", "Title": "Empty"])
        XCTAssertEqual(try BookmarksCommand.entries(inPlistAt: emptyList), [])
        let brokenList = try plist(["WebBookmarkType": "WebBookmarkTypeList", "Children": "bad"])
        assertSchemaFailure({ _ = try BookmarksCommand.entries(inPlistAt: brokenList) }, field: "Children")
    }

    func testUnrepresentableOptionalDatesStayUnknownInHistoryAndDownloads() throws {
        // CE 0001 through 9999 is the public date range; rejecting wider Date
        // values prevents empty DateFormatter output or misleading clipped eras.
        let invalidTimes: [Double] = [-62_135_596_801, 253_402_300_800, -1e15, 1e15, -1e20, 1e20, -Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude]
        for seconds in invalidTimes {
            let reference = seconds - HistoryCommand.coreDataEpochOffset
            let source = try database(historySchema + "INSERT INTO history_items VALUES (1,'https://date.test',1); INSERT INTO history_visits VALUES (1,'Date',\(reference));")
            let visits = try HistoryCommand.visits(inDatabaseAt: source, search: nil, since: nil, limit: 10)
            let visit = try XCTUnwrap(visits.first)
            XCTAssertNil(visit.visitTime, "\(seconds) is not a representable optional date")
            let historyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: HistoryCommand.encodeJSON(visits)) as? [[String: Any]])
            XCTAssertTrue(historyJSON[0]["visit_time"] is NSNull, "\(seconds)")
            XCTAssertTrue(HistoryCommand.formatRow(index: 1, visit: visit, timeZone: .current).contains("(no date)"), "\(seconds)")

            let downloadsSource = try plist(["DownloadHistory": [["DownloadEntryPath": "/tmp/date", "DownloadEntryDateAddedKey": Date(timeIntervalSince1970: seconds)]]])
            let entries = try DownloadsCommand.entries(inPlistAt: downloadsSource, limit: 10)
            let entry = try XCTUnwrap(entries.first)
            XCTAssertNil(entry.date, "\(seconds)")
            let downloadsJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: DownloadsCommand.encodeJSON(entries)) as? [[String: Any]])
            XCTAssertTrue(downloadsJSON[0]["date"] is NSNull, "\(seconds)")
            XCTAssertTrue(DownloadsCommand.formatRow(index: 1, entry: entry, timeZone: .current).contains("(no date)"), "\(seconds)")
        }
        let valid = Date(timeIntervalSince1970: 1_767_225_600)
        let validSource = try plist(["DownloadHistory": [["DownloadEntryPath": "/tmp/valid", "DownloadEntryDateAddedKey": valid]]])
        XCTAssertEqual(try DownloadsCommand.entries(inPlistAt: validSource, limit: 1).first?.date, valid)
    }

    func testUnknownDateCannotSatisfySinceFilter() throws {
        let source = try database(historySchema + "INSERT INTO history_items VALUES(1,'https://unknown-date.test',1); INSERT INTO history_visits VALUES(1,'Unknown',1e20)")
        XCTAssertTrue(try HistoryCommand.visits(inDatabaseAt: source, search: nil,
            since: Date(timeIntervalSince1970: 1_700_000_000), limit: 1).isEmpty)
    }

    func testOptionalDateGuardHonorsUTCAndLocalGregorianEraYearBoundaries() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let east = try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 3600))
        let west = try XCTUnwrap(TimeZone(secondsFromGMT: -12 * 3600))
        let first = Date(timeIntervalSince1970: -62_135_596_800)
        let last = Date(timeIntervalSince1970: 253_402_300_799)
        XCTAssertEqual(SchemaDiagnostics.representableDate(first, timeZone: utc), first)
        XCTAssertEqual(SchemaDiagnostics.representableDate(last, timeZone: utc), last)
        // Foundation Gregorian uses its historical cutover before 1582;
        // this lower UTC bound remains CE in the western time zone too.
        XCTAssertEqual(SchemaDiagnostics.representableDate(first, timeZone: west), first)
        XCTAssertNil(SchemaDiagnostics.representableDate(last, timeZone: east))
        XCTAssertNil(SchemaDiagnostics.representableDate(first.addingTimeInterval(-1), timeZone: east))
        XCTAssertNil(SchemaDiagnostics.representableDate(last.addingTimeInterval(1), timeZone: west))
        XCTAssertNil(SchemaDiagnostics.representableDate(Date(timeIntervalSince1970: .infinity)))
        XCTAssertNil(SchemaDiagnostics.representableDate(Date(timeIntervalSince1970: .nan)))
    }

}
