import SQLite3
import XCTest

@testable import SafariBrowser

/// #109: `SafariDataStore` is the repo's first filesystem read path — every
/// other command drives Safari through AppleScript, AX, or CoreGraphics. The
/// tests here pin the two properties that fail *silently* when wrong:
/// a WAL-mode database copied without its sidecars loses committed rows that
/// have not been checkpointed, and a temp directory left behind on the error
/// path leaks until reboot.
final class SafariDataStoreTests: XCTestCase {

    private var fixtureDir: URL!

    override func setUpWithError() throws {
        fixtureDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sds-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: fixtureDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = fixtureDir, FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = fixtureDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - WAL sidecars

    func testCopiesWALSidecarsAlongsideDatabase() throws {
        let main = try write("X.db", "main")
        _ = try write("X.db-wal", "wal")
        _ = try write("X.db-shm", "shm")

        try SafariDataStore.withCopy(sourceURL: main, includeWALSidecars: true) { copied in
            let dir = copied.deletingLastPathComponent()
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertEqual(
                Set(names), ["X.db", "X.db-wal", "X.db-shm"],
                "the -wal sidecar carries committed-but-uncheckpointed rows; copying "
                    + "the main file alone silently loses them")
            XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "main")
        }
    }

    func testMissingSidecarsProduceAStandInWAL() throws {
        // Safari checkpoints and removes the sidecars when it closes cleanly,
        // so their absence is the normal steady state — not a failure. But a
        // WAL-header database with no -wal cannot be opened read-only at all
        // (SQLITE_CANTOPEN), so the copy gets an empty stand-in: a zero-length
        // WAL has no valid header, so recovery replays nothing and reads the
        // main file, which after a checkpoint holds everything.
        let main = try write("X.db", "main")

        try SafariDataStore.withCopy(sourceURL: main, includeWALSidecars: true) { copied in
            let dir = copied.deletingLastPathComponent()
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertEqual(Set(names), ["X.db", "X.db-wal"])
            let size = try FileManager.default
                .attributesOfItem(atPath: copied.path + "-wal")[.size] as? Int
            XCTAssertEqual(size, 0, "the stand-in must be empty, not a copy of anything")
        }
    }

    func testPlistSourceGetsNoStandInWAL() throws {
        // The stand-in is meaningless for a plist and must not appear there.
        let main = try write("Bookmarks.plist", "plist")
        try SafariDataStore.withCopy(sourceURL: main, includeWALSidecars: false) { copied in
            let dir = copied.deletingLastPathComponent()
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertEqual(Set(names), ["Bookmarks.plist"])
        }
    }

    func testPlistSourceCopiesOnlyTheFileItself() throws {
        let main = try write("Bookmarks.plist", "plist")
        // A stray same-prefixed file must not be swept in when sidecars are off.
        _ = try write("Bookmarks.plist-wal", "should not be copied")

        try SafariDataStore.withCopy(sourceURL: main, includeWALSidecars: false) { copied in
            let dir = copied.deletingLastPathComponent()
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertEqual(Set(names), ["Bookmarks.plist"])
        }
    }

    // MARK: - Temp directory lifetime

    func testTempDirectoryIsRemovedAfterSuccess() throws {
        let main = try write("X.db", "main")
        var observed: URL?

        try SafariDataStore.withCopy(sourceURL: main, includeWALSidecars: false) { copied in
            observed = copied.deletingLastPathComponent()
        }

        let dir = try XCTUnwrap(observed)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.path),
            "temp copy must not outlive the call")
    }

    func testTempDirectoryIsRemovedWhenBodyThrows() throws {
        struct Boom: Error {}
        let main = try write("X.db", "main")
        var observed: URL?

        XCTAssertThrowsError(
            try SafariDataStore.withCopy(sourceURL: main, includeWALSidecars: false) { copied in
                observed = copied.deletingLastPathComponent()
                throw Boom()
            }
        ) { error in
            XCTAssertTrue(error is Boom, "the body's error must propagate unchanged")
        }

        let dir = try XCTUnwrap(observed)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.path),
            "the error path is exactly where a caller-managed cleanup contract leaks")
    }

    func testEachCallGetsItsOwnDirectory() throws {
        let main = try write("X.db", "main")
        var first: URL?
        var second: URL?

        try SafariDataStore.withCopy(sourceURL: main, includeWALSidecars: false) {
            first = $0.deletingLastPathComponent()
        }
        try SafariDataStore.withCopy(sourceURL: main, includeWALSidecars: false) {
            second = $0.deletingLastPathComponent()
        }

        XCTAssertNotEqual(first, second, "concurrent invocations must not share a directory")
    }

    // MARK: - Sidecar copy failure (#109 verify HIGH-2)

    /// `-wal` holds committed rows not yet checkpointed into the main file.
    /// The original code copied it with `try?`, so a copy failure silently
    /// produced a database missing the most recent activity — the exact
    /// silence `hasWALSidecars` was introduced to prevent.
    func testWALCopyFailureIsFatalRatherThanSilent() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses the mode-000 read denial this test needs")

        let main = try write("X.db", "main")
        // Present to `fileExists` but unreadable to `copyItem` — the shape of
        // a real mid-copy failure (I/O error, race with Safari's checkpoint,
        // permission change) without having to provoke one.
        let wal = try write("X.db-wal", "wal")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: wal.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: wal.path)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wal.path),
            "precondition: the guard in withCopy must see the sidecar as present")

        XCTAssertThrowsError(
            try SafariDataStore.withCopy(sourceURL: main, includeWALSidecars: true) { _ in }
        ) { error in
            guard case SafariBrowserError.safariDataParseFailed(_, let detail) = error else {
                return XCTFail("expected safariDataParseFailed, got \(error)")
            }
            XCTAssertTrue(
                detail.contains("write-ahead log"),
                "the error must say the WAL is the problem, not just 'copy failed' — got: \(detail)")
        }
    }

    /// `-shm` is only the shared-memory index; SQLite rebuilds it. Its loss
    /// must NOT abort the command — only `-wal` carries data.
    func testSHMCopyFailureIsNotFatal() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses the mode-000 read denial this test needs")

        let main = try write("X.db", "main")
        _ = try write("X.db-wal", "wal")
        let shm = try write("X.db-shm", "shm")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: shm.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: shm.path)
        }

        var ran = false
        try SafariDataStore.withCopy(sourceURL: main, includeWALSidecars: true) { copied in
            ran = true
            let dir = copied.deletingLastPathComponent()
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertTrue(names.contains("X.db-wal"), "the data-bearing sidecar must still land")
        }
        XCTAssertTrue(ran, "a -shm problem must not prevent the body from running")
    }

    // MARK: - Real WAL-mode databases (#109 verify round 2, LOGIC-1)

    /// Builds a genuine WAL-mode SQLite database. Every other fixture in this
    /// file writes text files named `*.db`, which is why no test in this repo
    /// ever exercised what SQLite actually does with a WAL header — and why
    /// LOGIC-1 survived two rounds of review.
    private func makeWALDatabase(rows: Int, checkpoint: Bool) throws -> URL {
        let url = fixtureDir.appendingPathComponent("W.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE t (n INTEGER)", nil, nil, nil), SQLITE_OK)
        for i in 0..<rows {
            XCTAssertEqual(
                sqlite3_exec(db, "INSERT INTO t VALUES (\(i))", nil, nil, nil), SQLITE_OK)
        }
        if checkpoint {
            XCTAssertEqual(
                sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        }
        sqlite3_close(db)
        return url
    }

    private func rowCount(at url: URL) throws -> Int {
        try SQLiteReader.query(at: url, sql: "SELECT n FROM t") { $0[0].intValue }.count
    }

    /// The case that broke: Safari checkpoints and removes the sidecars on a
    /// clean quit — the state the copy loop's own comment calls normal — and a
    /// WAL-header database with no `-wal` cannot be opened read-only at all.
    /// SQLite creates a missing `-shm` but refuses to create a missing `-wal`
    /// on a read-only connection, so the user was told their data file was
    /// unparseable when nothing was wrong with it.
    func testCheckpointedDatabaseWithNoSidecarsIsStillReadable() throws {
        let source = try makeWALDatabase(rows: 300, checkpoint: true)
        // A TRUNCATE checkpoint empties the -wal but the file can survive the
        // close; Safari's own clean quit removes it. Construct that state
        // explicitly rather than depending on which of the two happens here.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: source.path + suffix)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.path + "-wal"),
            "precondition: the source has no -wal, as after a clean Safari quit")

        try SafariDataStore.withCopy(sourceURL: source, includeWALSidecars: true) { copied in
            XCTAssertEqual(
                try self.rowCount(at: copied), 300,
                "a checkpointed WAL database must still read; without a stand-in -wal "
                    + "SQLite returns SQLITE_CANTOPEN and the command reports corruption")
        }
    }

    /// The complementary case: rows that live only in an uncheckpointed `-wal`
    /// must survive the copy. This is what `hasWALSidecars` exists for, and
    /// what a `try?` around the sidecar copy used to lose silently.
    func testUncheckpointedRowsSurviveTheCopy() throws {
        let source = try makeWALDatabase(rows: 300, checkpoint: false)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path + "-wal"),
            "precondition: without a checkpoint the rows are still in the -wal")

        try SafariDataStore.withCopy(sourceURL: source, includeWALSidecars: true) { copied in
            XCTAssertEqual(
                try self.rowCount(at: copied), 300,
                "rows committed to the -wal but not checkpointed must be visible")
        }
    }

    // MARK: - Missing source

    func testMissingSourceThrowsDataFileNotFound() throws {
        let absent = fixtureDir.appendingPathComponent("NoSuchFile.db")

        XCTAssertThrowsError(
            try SafariDataStore.withCopy(sourceURL: absent, includeWALSidecars: true) { _ in }
        ) { error in
            guard case SafariBrowserError.safariDataFileNotFound = error else {
                return XCTFail("expected safariDataFileNotFound, got \(error)")
            }
        }
    }

    // MARK: - File descriptors

    func testFilenamesForEachSource() {
        XCTAssertEqual(SafariDataFile.history.filename, "History.db")
        XCTAssertEqual(SafariDataFile.bookmarks.filename, "Bookmarks.plist")
        XCTAssertEqual(SafariDataFile.cloudTabs.filename, "CloudTabs.db")
        XCTAssertEqual(SafariDataFile.downloads.filename, "Downloads.plist")
    }

    func testOnlySQLiteSourcesCarryWALSidecars() {
        XCTAssertTrue(SafariDataFile.history.hasWALSidecars)
        XCTAssertTrue(SafariDataFile.cloudTabs.hasWALSidecars)
        XCTAssertFalse(SafariDataFile.bookmarks.hasWALSidecars)
        XCTAssertFalse(SafariDataFile.downloads.hasWALSidecars)
    }
}
