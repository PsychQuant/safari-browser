import Foundation
import SQLite3
import XCTest
@testable import SafariBrowser

final class SafariDataStoreTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("data-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testErrnoClassificationDoesNotRecommendFDAForResourceFailures() {
        for code in [EIO, ENOSPC, EROFS, EMFILE] {
            let error = SafariDataStore.ioError(path: "/source/History.db", code: code)
            guard case .safariDataReadFailed(let path, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, "/source/History.db")
            XCTAssertTrue(detail.contains("errno \(code)"))
            XCTAssertFalse(error.localizedDescription.contains("Full Disk Access"))
        }
        for code in [EPERM, EACCES] {
            guard case .fullDiskAccessRequired = SafariDataStore.ioError(path: "/source", code: code) else { return XCTFail() }
        }
        guard case .safariDataFileNotFound = SafariDataStore.ioError(path: "/source", code: ENOENT) else { return XCTFail() }
    }

    func testPlistReadHasNoTemporaryCopyAndPreservesSourceMode() throws {
        let source = dir.appendingPathComponent("Bookmarks.plist")
        let bytes = Data("source bytes".utf8)
        try bytes.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        let temp = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("safari-data-") })
        XCTAssertEqual(try SafariDataStore.readPlist(sourceURL: source), bytes)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("safari-data-") })
        XCTAssertEqual(before, after)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int, 0o644)
    }

    func testMissingAndDirectorySourcesAreDifferentErrors() throws {
        XCTAssertThrowsError(try SafariDataStore.readPlist(sourceURL: dir.appendingPathComponent("absent"))) {
            guard case SafariBrowserError.safariDataFileNotFound = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try SafariDataStore.readPlist(sourceURL: dir)) {
            guard case SafariBrowserError.safariDataReadFailed = $0 else { return XCTFail("\($0)") }
        }
    }

    func testWALSnapshotIsCoherentAndReleasesReadTransactionBeforeConsumer() throws {
        let url = dir.appendingPathComponent("History.db")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE t(n INTEGER, pad TEXT); BEGIN;", nil, nil, nil), SQLITE_OK)
        for i in 0..<2000 { XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO t VALUES(\(i),printf('%0500d',1))", nil, nil, nil), SQLITE_OK) }
        XCTAssertEqual(sqlite3_exec(writer, "COMMIT", nil, nil, nil), SQLITE_OK)
        var changed = false
        try SQLiteReader.withSnapshot(at: url, afterStep: {
            if !changed {
                changed = true
                XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO t VALUES(2000,'later')", nil, nil, nil), SQLITE_OK)
                // A pinned reader can block TRUNCATE; do not assume sidecars
                // copied before and after this operation constitute a snapshot.
                _ = sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
            }
        }) { snapshot in
            XCTAssertEqual(snapshot.sourceURL, url)
            XCTAssertEqual(try SQLiteReader.query(in: snapshot, sql: "SELECT count(*) FROM t") { $0[0].intValue }, [2000])
            let files = try SQLiteReader.query(in: snapshot, sql: "PRAGMA database_list") { $0[2].stringValue }
            XCTAssertEqual(files, [""])
            XCTAssertEqual(try SQLiteReader.query(in: snapshot, sql: "PRAGMA temp_store") { $0[0].intValue }, [2])
            XCTAssertThrowsError(try SQLiteReader.query(in: snapshot, sql: "DELETE FROM t") { _ -> Int? in nil })
            XCTAssertEqual(sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil), SQLITE_OK,
                           "consumer must not hold the source transaction open")
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(try SQLiteReader.query(at: url, sql: "SELECT count(*) FROM t") { $0[0].intValue }, [2001])
    }

    func testSnapshotSupportsNonDefaultPageSizesAndSourcePathsOnFailure() throws {
        let url = dir.appendingPathComponent("CloudTabs.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"PRAGMA page_size=1024; CREATE TABLE t(x); INSERT INTO t VALUES(3)",nil,nil,nil),SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: url)
        try SafariDataStore.withDatabaseSnapshot(sourceURL: url) { memory in
            XCTAssertEqual(try SQLiteReader.query(in: memory,sql:"SELECT x FROM t") { $0[0].intValue },[3])
            XCTAssertThrowsError(try SQLiteReader.query(in: memory,sql:"SELECT missing FROM t") { $0[0].intValue }) {
                guard case SafariBrowserError.safariDataParseFailed(let path, _) = $0 else { return XCTFail("\($0)") }
                XCTAssertEqual(path,url.path)
            }
        }
        XCTAssertEqual(try Data(contentsOf: url),before)
    }

    func testSnapshotDeadlineAndThrowingConsumerLeaveNoCopy() throws {
        let url=dir.appendingPathComponent("t.db")
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE t(x)",nil,nil,nil),SQLITE_OK);sqlite3_close(db)
        XCTAssertThrowsError(try SQLiteReader.withSnapshot(at:url,timeout:0.01,afterStep:{Thread.sleep(forTimeInterval:0.02)}) { _ in XCTFail("late snapshot escaped") })
        struct ConsumerError: Error {}
        XCTAssertThrowsError(try SafariDataStore.withDatabaseSnapshot(sourceURL:url) { _ in throw ConsumerError() })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dir.path),["t.db"])
    }
}
