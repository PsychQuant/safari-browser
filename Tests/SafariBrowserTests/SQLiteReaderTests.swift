import Foundation
import SQLite3
import XCTest

@testable import SafariBrowser

/// #109 verify HIGH-3: `SQLiteReader.query` used `while sqlite3_step(stmt) == SQLITE_ROW`,
/// which exits on *any* non-ROW code. SQLITE_CORRUPT, SQLITE_IOERR and SQLITE_BUSY
/// were therefore indistinguishable from a clean end-of-results — the caller got a
/// truncated answer and a zero exit status. These tests pin the distinction.
final class SQLiteReaderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sqlreader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir, FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Builds a real SQLite file with `rows` single-column integer rows.
    private func makeDatabase(rows: Int) throws -> URL {
        let url = dir.appendingPathComponent("t.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE t (n INTEGER, s TEXT)", nil, nil, nil), SQLITE_OK)
        for i in 0..<rows {
            XCTAssertEqual(
                sqlite3_exec(db, "INSERT INTO t VALUES (\(i), 'row\(i)')", nil, nil, nil),
                SQLITE_OK)
        }
        return url
    }

    // MARK: - Happy path

    func testReadsEveryRow() throws {
        let url = try makeDatabase(rows: 5)
        let values = try SQLiteReader.query(at: url, sql: "SELECT n, s FROM t ORDER BY n") {
            row -> Int? in row[0].intValue
        }
        XCTAssertEqual(values, [0, 1, 2, 3, 4])
    }

    func testRowMapperReturningNilSkipsWithoutFailing() throws {
        let url = try makeDatabase(rows: 4)
        let values = try SQLiteReader.query(at: url, sql: "SELECT n FROM t ORDER BY n") {
            row -> Int? in
            guard let n = row[0].intValue, n % 2 == 0 else { return nil }
            return n
        }
        XCTAssertEqual(values, [0, 2], "a filtering mapper must not be read as an error")
    }

    func testEmptyResultIsNotAnError() throws {
        let url = try makeDatabase(rows: 3)
        let values = try SQLiteReader.query(at: url, sql: "SELECT n FROM t WHERE n > 999") {
            row -> Int? in row[0].intValue
        }
        XCTAssertEqual(values, [])
    }

    // MARK: - The regression this file exists for

    func testCorruptDatabaseThrowsInsteadOfReturningPartialRows() throws {
        let url = try makeDatabase(rows: 200)

        // Corrupt the page area past the header so the file still opens and
        // prepares, but stepping fails partway through the scan. This is the
        // shape of a real SQLITE_CORRUPT / SQLITE_IOERR: some rows arrive,
        // then the read dies.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 4096)
        handle.write(Data(repeating: 0xFF, count: 8192))
        try handle.close()

        do {
            let values = try SQLiteReader.query(at: url, sql: "SELECT n, s FROM t") {
                row -> Int? in row[0].intValue
            }
            // If SQLite happens to tolerate this particular corruption the
            // query legitimately succeeds; the assertion that matters is that
            // it never returns a SHORT result silently.
            XCTAssertEqual(
                values.count, 200,
                "returned \(values.count) of 200 rows without throwing — a truncated "
                    + "result with a success status is exactly the bug this guards")
        } catch let error as SafariBrowserError {
            guard case .safariDataParseFailed(_, let detail) = error else {
                return XCTFail("expected safariDataParseFailed, got \(error)")
            }
            XCTAssertTrue(
                detail.contains("sqlite code"),
                "the error must name the sqlite code so a corrupt DB is distinguishable "
                    + "from a permissions or schema problem — got: \(detail)")
        }
    }

    func testUnopenableDatabaseThrows() throws {
        let missing = dir.appendingPathComponent("does-not-exist.db")
        XCTAssertThrowsError(
            try SQLiteReader.query(at: missing, sql: "SELECT 1") { _ -> Int? in 1 }
        ) { error in
            guard case SafariBrowserError.safariDataParseFailed = error else {
                return XCTFail("expected safariDataParseFailed, got \(error)")
            }
        }
    }

    func testMalformedSQLThrows() throws {
        let url = try makeDatabase(rows: 1)
        XCTAssertThrowsError(
            try SQLiteReader.query(at: url, sql: "SELECT nope FROM missing_table") {
                _ -> Int? in 1
            }
        ) { error in
            guard case SafariBrowserError.safariDataParseFailed = error else {
                return XCTFail("expected safariDataParseFailed, got \(error)")
            }
        }
    }

    // MARK: - Read-only enforcement

    func testConnectionIsReadOnly() throws {
        let url = try makeDatabase(rows: 1)
        XCTAssertThrowsError(
            try SQLiteReader.query(at: url, sql: "DELETE FROM t") { _ -> Int? in nil },
            "the handle must refuse writes — these are the user's live browser databases")
    }
}
