import Foundation
import XCTest
@testable import SafariBrowser

/// #210: reading Safari's WebKit network cache. Every fixture here is
/// synthetic — the tests never touch the user's real cache.
final class WebKitCacheReaderTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webkit-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        // A test may have removed permissions to provoke EACCES.
        Self.restorePermissions(root)
        try FileManager.default.removeItem(at: root)
    }

    static func restorePermissions(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        for child in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
            restorePermissions(url.appendingPathComponent(child))
        }
    }

    // MARK: - Record bytes

    /// Encodes one WTF persistence string: `uint32 length`, `is8Bit`, characters.
    static func string(_ text: String, is8Bit: Bool = true) -> Data {
        var out = Data()
        if is8Bit {
            let bytes = Array(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
            out.append(contentsOf: withUnsafeBytes(of: UInt32(bytes.count).littleEndian, Array.init))
            out.append(1)
            out.append(contentsOf: bytes)
        } else {
            let units = Array(text.utf16)
            out.append(contentsOf: withUnsafeBytes(of: UInt32(units.count).littleEndian, Array.init))
            out.append(0)
            for unit in units { out.append(contentsOf: withUnsafeBytes(of: unit.littleEndian, Array.init)) }
        }
        return out
    }

    static func record(
        version: UInt32 = 17, partition: String = "", type: String = "Resource",
        identifier: String, is8Bit: Bool = true, trailer: Data = Data(repeating: 0xAB, count: 64)
    ) -> Data {
        var out = Data(withUnsafeBytes(of: version.littleEndian, Array.init))
        out.append(string(partition))
        out.append(string(type))
        out.append(string(identifier, is8Bit: is8Bit))
        out.append(trailer)
        return out
    }

    // MARK: - parseRecordKey

    /// The leading bytes of the real Springer record observed on 2026-09-30:
    /// `11000000 00000000 01 08000000 01 "Resource" 3c000000 01 <60 chars>`.
    /// Pins the layout to what was actually seen, not to a helper that could
    /// share the same misunderstanding.
    func testParsesTheLeadingBytesObservedInARealRecord() throws {
        let url = "https://link.springer.com/content/pdf/10.3758/BF03208840.pdf"
        XCTAssertEqual(url.utf8.count, 0x3c)
        var bytes: [UInt8] = [0x11, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x08, 0, 0, 0, 0x01]
        bytes += Array("Resource".utf8)
        bytes += [0x3c, 0, 0, 0, 0x01]
        bytes += Array(url.utf8)
        bytes += [UInt8](repeating: 0x55, count: 100)
        let key = try WebKitCacheReader.parseRecordKey(Data(bytes))
        XCTAssertEqual(key.version, 17)
        XCTAssertEqual(key.partition, "")
        XCTAssertEqual(key.type, "Resource")
        XCTAssertEqual(key.identifier, url)
    }

    func testParsesNonEmptyPartitionAndSixteenBitIdentifier() throws {
        let identifier = "https://例え.example/文件.pdf"
        let key = try WebKitCacheReader.parseRecordKey(Self.record(
            partition: "https://top.example", identifier: identifier, is8Bit: false))
        XCTAssertEqual(key.partition, "https://top.example")
        XCTAssertEqual(key.identifier, identifier)
    }

    func testEveryTruncationOfTheKeyRegionFails() throws {
        let full = Self.record(partition: "p", identifier: "https://example.org/a.pdf", trailer: Data())
        for length in 0..<full.count {
            XCTAssertThrowsError(try WebKitCacheReader.parseRecordKey(full.prefix(length)), "prefix \(length)") {
                XCTAssertEqual($0 as? WebKitCacheReader.RecordError, .truncated, "prefix \(length)")
            }
        }
        XCTAssertNoThrow(try WebKitCacheReader.parseRecordKey(full))
    }

    func testWrongVersionTypeAndStringFlagAreRejected() {
        XCTAssertThrowsError(try WebKitCacheReader.parseRecordKey(Self.record(version: 18, identifier: "https://e.org/a.pdf"))) {
            XCTAssertEqual($0 as? WebKitCacheReader.RecordError, .unsupportedVersion(18))
        }
        XCTAssertThrowsError(try WebKitCacheReader.parseRecordKey(Self.record(type: "Other", identifier: "https://e.org/a.pdf"))) {
            XCTAssertEqual($0 as? WebKitCacheReader.RecordError, .unexpectedType("Other"))
        }
        var flagged = Self.record(identifier: "https://e.org/a.pdf")
        // Byte layout: 4 version + (4+1) empty partition + (4+1+8) type + 4 length → flag at 26.
        flagged[26] = 7
        XCTAssertThrowsError(try WebKitCacheReader.parseRecordKey(flagged)) {
            XCTAssertEqual($0 as? WebKitCacheReader.RecordError, .invalidStringFlag(7))
        }
    }

    func testNullStringAndOversizedIdentifierAreRejectedBeforeReading() {
        var nullPartition = Data(withUnsafeBytes(of: UInt32(17).littleEndian, Array.init))
        nullPartition.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try WebKitCacheReader.parseRecordKey(nullPartition)) {
            XCTAssertEqual($0 as? WebKitCacheReader.RecordError, .nullString)
        }
        var oversized = Data(withUnsafeBytes(of: UInt32(17).littleEndian, Array.init))
        oversized.append(Self.string(""))
        oversized.append(Self.string("Resource"))
        oversized.append(contentsOf: withUnsafeBytes(of: UInt32(65_537).littleEndian, Array.init))
        oversized.append(1)
        oversized.append(Data(repeating: 0x61, count: 70_000))
        XCTAssertThrowsError(try WebKitCacheReader.parseRecordKey(oversized)) {
            XCTAssertEqual($0 as? WebKitCacheReader.RecordError, .stringTooLong(65_537))
        }
        var atLimit = Data(withUnsafeBytes(of: UInt32(17).littleEndian, Array.init))
        atLimit.append(Self.string(""))
        atLimit.append(Self.string("Resource"))
        atLimit.append(Self.string(String(repeating: "a", count: 65_536)))
        XCTAssertEqual(try WebKitCacheReader.parseRecordKey(atLimit).identifier.count, 65_536)
    }

    // MARK: - Fixture cache tree

    @discardableResult
    func addRecord(
        version: String = "Version 17", partition: String = "PARTITIONHASH1",
        key: String, identifier: String, body: Data?, recordBytes: Data? = nil
    ) throws -> URL {
        let dir = root.appendingPathComponent("\(version)/Records/\(partition)/Resource", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (recordBytes ?? Self.record(identifier: identifier)).write(to: dir.appendingPathComponent(key))
        if let body { try body.write(to: dir.appendingPathComponent("\(key)-blob")) }
        return dir
    }

    static let pdfBody = Data("%PDF-1.7\n1 0 obj\n<<>>\nendobj\n".utf8)

    func testScanListsOnlyPDFBodiesAndReportsTheirMetadata() throws {
        try addRecord(key: "AAAA1111", identifier: "https://example.org/a.pdf?sig=SECRET", body: Self.pdfBody)
        try addRecord(key: "BBBB2222", identifier: "https://example.org/page.html", body: Data("<html>".utf8))
        try addRecord(key: "CCCC3333", identifier: "https://example.org/inline", body: nil)
        try addRecord(partition: "PARTITIONHASH2", key: "DDDD4444", identifier: "https://example.org/b.pdf", body: Self.pdfBody)

        let scan = try WebKitCacheReader.scan(cacheRoot: root)
        XCTAssertEqual(scan.unreadableRecords, 0)
        XCTAssertEqual(scan.pdfs.map(\.key).sorted(), ["AAAA1111", "DDDD4444"])
        let first = try XCTUnwrap(scan.pdfs.first { $0.key == "AAAA1111" })
        XCTAssertEqual(first.requestURL, "https://example.org/a.pdf?sig=SECRET")
        XCTAssertEqual(first.size, Int64(Self.pdfBody.count))
        XCTAssertEqual(first.partitionDirectory, "PARTITIONHASH1")
        XCTAssertEqual(first.partition, "")
        XCTAssertNotNil(first.modified)
        XCTAssertEqual(first.bodyURL.lastPathComponent, "AAAA1111-blob")
    }

    /// The cache holds thousands of bodies from every site the user visited.
    /// Non-PDF bodies must be looked at for five bytes and no more, and their
    /// records must not be opened at all.
    func testScanReadsAtMostFiveBytesOfABodyAndNeverOpensANonPDFRecord() throws {
        try addRecord(key: "AAAA1111", identifier: "https://example.org/a.pdf", body: Self.pdfBody)
        try addRecord(key: "BBBB2222", identifier: "https://example.org/page.html", body: Data(repeating: 0x20, count: 200_000))

        final class Recorder: WebKitCacheFileReading, @unchecked Sendable {
            var reads: [(name: String, maxBytes: Int)] = []
            func readPrefix(at url: URL, maxBytes: Int) throws -> Data {
                reads.append((url.lastPathComponent, maxBytes))
                return try POSIXFilePrefixReader().readPrefix(at: url, maxBytes: maxBytes)
            }
        }
        let recorder = Recorder()
        _ = try WebKitCacheReader.scan(cacheRoot: root, reader: recorder)

        let bodyReads = recorder.reads.filter { $0.name.hasSuffix("-blob") }
        XCTAssertEqual(bodyReads.map(\.name).sorted(), ["AAAA1111-blob", "BBBB2222-blob"])
        XCTAssertTrue(bodyReads.allSatisfy { $0.maxBytes <= 5 }, "\(bodyReads)")
        XCTAssertEqual(recorder.reads.filter { $0.name == "BBBB2222" }.count, 0, "a non-PDF record was opened")
        XCTAssertEqual(recorder.reads.filter { $0.name == "AAAA1111" }.count, 1)
    }

    func testAPDFBodyWithoutARecordAndAGarbageRecordAreCountedNotSilentlyDropped() throws {
        try addRecord(key: "AAAA1111", identifier: "https://example.org/a.pdf", body: Self.pdfBody)
        let dir = try addRecord(key: "BBBB2222", identifier: "x", body: Self.pdfBody, recordBytes: Data(repeating: 0x00, count: 40))
        try Self.pdfBody.write(to: dir.appendingPathComponent("EEEE5555-blob"))   // no record file

        let scan = try WebKitCacheReader.scan(cacheRoot: root)
        XCTAssertEqual(scan.pdfs.map(\.key), ["AAAA1111"])
        XCTAssertEqual(scan.unreadableRecords, 2)
        XCTAssertEqual(Set(scan.unreadableKeys), ["BBBB2222", "EEEE5555"])
    }

    func testEveryPDFRecordUnreadableIsAnUnsupportedLayoutNotAnEmptyCache() throws {
        try addRecord(key: "AAAA1111", identifier: "x", body: Self.pdfBody, recordBytes: Data(repeating: 0, count: 40))
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: root)) {
            guard case SafariBrowserError.pdfCache(.recordLayoutUnsupported) = $0 else { return XCTFail("\($0)") }
        }
    }

    func testNoPDFAtAllIsAnEmptyScanNotAnError() throws {
        try addRecord(key: "BBBB2222", identifier: "https://example.org/page.html", body: Data("<html>".utf8))
        let scan = try WebKitCacheReader.scan(cacheRoot: root)
        XCTAssertEqual(scan.pdfs, [])
        XCTAssertEqual(scan.unreadableRecords, 0)
    }

    // MARK: - Version directory

    func testMissingCacheFolderIsNamedAsSuch() {
        let missing = root.appendingPathComponent("does-not-exist")
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: missing)) {
            guard case SafariBrowserError.pdfCache(.cacheFolderMissing(let path)) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(path, missing.path)
        }
    }

    func testOnlyAnUnsupportedVersionListsWhatWasSeen() throws {
        try addRecord(version: "Version 18", key: "AAAA1111", identifier: "https://e.org/a.pdf", body: Self.pdfBody)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Version 16"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: root)) {
            guard case SafariBrowserError.pdfCache(.noSupportedVersion(_, let seen)) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(seen, ["Version 16", "Version 18"])
        }
    }

    func testSupportedVersionIsUsedEvenWhenAnotherVersionIsPresent() throws {
        try addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: Self.pdfBody)
        try addRecord(version: "Version 18", key: "FFFF6666", identifier: "https://e.org/z.pdf", body: Self.pdfBody)
        XCTAssertEqual(try WebKitCacheReader.scan(cacheRoot: root).pdfs.map(\.key), ["AAAA1111"])
    }

    // MARK: - Access errors keep their cause

    func testAnUnreadableVersionDirectoryIsAFullDiskAccessErrorNotAnEmptyCache() throws {
        try addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: Self.pdfBody)
        let version = root.appendingPathComponent("Version 17")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: version.path)
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: root)) {
            guard case SafariBrowserError.fullDiskAccessRequired = $0 else { return XCTFail("\($0)") }
        }
    }

    func testAnUnreadableRecordDirectoryIsNotReportedAsMissingPDFs() throws {
        let dir = try addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: Self.pdfBody)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: root)) {
            guard case SafariBrowserError.fullDiskAccessRequired = $0 else { return XCTFail("\($0)") }
        }
    }
}
