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

    func testMissingSidecarsIsNotAnError() throws {
        // Safari checkpoints and removes the sidecars when it closes cleanly,
        // so their absence is the normal steady state — not a failure.
        let main = try write("X.db", "main")

        try SafariDataStore.withCopy(sourceURL: main, includeWALSidecars: true) { copied in
            let dir = copied.deletingLastPathComponent()
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertEqual(Set(names), ["X.db"])
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
