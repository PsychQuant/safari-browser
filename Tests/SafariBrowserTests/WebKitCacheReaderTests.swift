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

    /// The record's file name is the SHA-1 of its key, in upper-case hex. Test keys are
    /// short labels; this pads them to a full name.
    static func fullKey(_ label: String) -> String {
        label.uppercased().padding(toLength: 40, withPad: "0", startingAt: 0)
    }

    static func hashBytes(forKey key: String) -> Data {
        let hex = Array(key)
        return Data(stride(from: 0, to: 40, by: 2).map { UInt8(String(hex[$0...$0 + 1]), radix: 16)! })
    }

    /// `range` nil encodes WebKit's null string (`0xFFFFFFFF`), as every observed record does.
    static func record(
        version: UInt32 = 17, partition: String = "", type: String = "Resource",
        identifier: String, is8Bit: Bool = true, range: String? = nil,
        hash: Data = Data(repeating: 0x11, count: 20), trailer: Data = Data(repeating: 0xAB, count: 64)
    ) -> Data {
        var out = Data(withUnsafeBytes(of: version.littleEndian, Array.init))
        out.append(string(partition))
        out.append(string(type))
        out.append(string(identifier, is8Bit: is8Bit))
        if let range { out.append(string(range)) } else { out.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) }
        out.append(hash)
        out.append(trailer)
        return out
    }

    // MARK: - parseRecordKey

    /// The leading bytes of a real record, observed on 2026-09-30:
    /// `11000000 00000000 01 08000000 01 "Resource" 3c000000 01 <60 chars> ffffffff <20-byte hash>`.
    /// Pins the layout to what was actually seen, not to a helper that could
    /// share the same misunderstanding. The URL and hash here are synthetic; only
    /// the structure and the lengths are the observed ones.
    func testParsesTheLeadingBytesObservedInARealRecord() throws {
        let url = "https://example.org/content/pdf/10.0000/EXAMPLE000000000.pdf"
        XCTAssertEqual(url.utf8.count, 0x3c)
        let hash = Array(0..<20).map { UInt8(0xA0 + $0) }
        var bytes: [UInt8] = [0x11, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x08, 0, 0, 0, 0x01]
        bytes += Array("Resource".utf8)
        bytes += [0x3c, 0, 0, 0, 0x01]
        bytes += Array(url.utf8)
        bytes += [0xFF, 0xFF, 0xFF, 0xFF]
        bytes += hash
        bytes += [UInt8](repeating: 0x55, count: 100)
        let key = try WebKitCacheReader.parseRecordKey(Data(bytes))
        XCTAssertEqual(key.version, 17)
        XCTAssertEqual(key.partition, "")
        XCTAssertEqual(key.type, "Resource")
        XCTAssertEqual(key.identifier, url)
        XCTAssertNil(key.range)
        XCTAssertEqual(key.hash, Data(hash))
    }

    func testARangeStringIsParsedAndDistinctFromNone() throws {
        let ranged = try WebKitCacheReader.parseRecordKey(Self.record(identifier: "https://e.org/a.pdf", range: "bytes=0-99"))
        XCTAssertEqual(ranged.range, "bytes=0-99")
        XCTAssertEqual(ranged.hash, Data(repeating: 0x11, count: 20))
        XCTAssertNil(try WebKitCacheReader.parseRecordKey(Self.record(identifier: "https://e.org/a.pdf")).range)
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
        atLimit.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        atLimit.append(Data(repeating: 0x11, count: 20))
        XCTAssertEqual(try WebKitCacheReader.parseRecordKey(atLimit).identifier.count, 65_536)
    }

    // MARK: - Fixture cache tree

    /// `key` is a short hex label; the file is named by its padded 40-character form and the
    /// record's hash is that name's bytes, as in a real cache.
    @discardableResult
    func addRecord(
        version: String = "Version 17", partition: String = "PARTITIONHASH1",
        key: String, identifier: String, body: Data?, recordBytes: Data? = nil, range: String? = nil
    ) throws -> URL {
        let name = Self.fullKey(key)
        let dir = root.appendingPathComponent("\(version)/Records/\(partition)/Resource", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = recordBytes ?? Self.record(identifier: identifier, range: range, hash: Self.hashBytes(forKey: name))
        try bytes.write(to: dir.appendingPathComponent(name))
        if let body { try body.write(to: dir.appendingPathComponent("\(name)-blob")) }
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
        XCTAssertEqual(scan.pdfs.map(\.key).sorted(), [Self.fullKey("AAAA1111"), Self.fullKey("DDDD4444")])
        let first = try XCTUnwrap(scan.pdfs.first { $0.key == Self.fullKey("AAAA1111") })
        XCTAssertEqual(first.requestURL, "https://example.org/a.pdf?sig=SECRET")
        XCTAssertEqual(first.size, Int64(Self.pdfBody.count))
        XCTAssertEqual(first.partitionDirectory, "PARTITIONHASH1")
        XCTAssertEqual(first.partition, "")
        XCTAssertNotNil(first.modified)
        XCTAssertEqual(first.bodyURL.lastPathComponent, "\(Self.fullKey("AAAA1111"))-blob")
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
        XCTAssertEqual(bodyReads.map(\.name).sorted(), ["\(Self.fullKey("AAAA1111"))-blob", "\(Self.fullKey("BBBB2222"))-blob"])
        XCTAssertTrue(bodyReads.allSatisfy { $0.maxBytes <= 5 }, "\(bodyReads)")
        XCTAssertEqual(recorder.reads.filter { $0.name == Self.fullKey("BBBB2222") }.count, 0, "a non-PDF record was opened")
        XCTAssertEqual(recorder.reads.filter { $0.name == Self.fullKey("AAAA1111") }.count, 1)
    }

    func testAPDFBodyWithoutARecordAndAGarbageRecordAreCountedNotSilentlyDropped() throws {
        try addRecord(key: "AAAA1111", identifier: "https://example.org/a.pdf", body: Self.pdfBody)
        let dir = try addRecord(key: "BBBB2222", identifier: "x", body: Self.pdfBody, recordBytes: Data(repeating: 0x00, count: 40))
        try Self.pdfBody.write(to: dir.appendingPathComponent("\(Self.fullKey("EEEE5555"))-blob"))   // no record file

        let scan = try WebKitCacheReader.scan(cacheRoot: root)
        XCTAssertEqual(scan.pdfs.map(\.key), [Self.fullKey("AAAA1111")])
        XCTAssertEqual(scan.unreadableRecords, 2)
        XCTAssertEqual(Set(scan.unreadableKeys), [Self.fullKey("BBBB2222"), Self.fullKey("EEEE5555")])
    }

    /// The hash inside a record is its file name. If WebKit reshaped the key, the bytes read as
    /// the hash would stop matching, so a record that does not name itself is not trusted.
    func testARecordWhoseHashIsNotItsFileNameIsUnreadableNotTrusted() throws {
        try addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: Self.pdfBody)
        let wrong = Self.record(identifier: "https://e.org/b.pdf", hash: Data(repeating: 0x22, count: 20))
        try addRecord(key: "BBBB2222", identifier: "x", body: Self.pdfBody, recordBytes: wrong)
        let scan = try WebKitCacheReader.scan(cacheRoot: root)
        XCTAssertEqual(scan.pdfs.map(\.key), [Self.fullKey("AAAA1111")])
        XCTAssertEqual(scan.unreadableKeys, [Self.fullKey("BBBB2222")])
    }

    /// A record whose key carries a range holds part of a resource. Its body can begin with
    /// `%PDF-` and still not be a document, so it is counted, never listed or selectable.
    func testARangedRecordIsNeitherListedNorUnreadable() throws {
        try addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: Self.pdfBody)
        try addRecord(key: "BBBB2222", identifier: "https://e.org/big.pdf", body: Self.pdfBody, range: "bytes=0-99")
        let scan = try WebKitCacheReader.scan(cacheRoot: root)
        XCTAssertEqual(scan.pdfs.map(\.key), [Self.fullKey("AAAA1111")])
        XCTAssertEqual(scan.partialKeys, [Self.fullKey("BBBB2222")])
        XCTAssertEqual(scan.unreadableKeys, [])
        // Only a partial body in the cache is an empty listing, not a layout error.
        let resources = root.appendingPathComponent("Version 17/Records/PARTITIONHASH1/Resource")
        for suffix in ["", "-blob"] {
            try FileManager.default.removeItem(at: resources.appendingPathComponent(Self.fullKey("AAAA1111") + suffix))
        }
        XCTAssertEqual(try WebKitCacheReader.scan(cacheRoot: root).pdfs, [])
    }

    /// A `-blob` that is a directory, or a symlink that could lead outside the cache, is not a
    /// cached body: it is skipped, and it does not fail the scan of everything else.
    func testADirectoryOrSymlinkNamedLikeABodyIsSkippedNotFatal() throws {
        let dir = try addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: Self.pdfBody)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("\(Self.fullKey("BBBB2222"))-blob"), withIntermediateDirectories: false)
        let outside = root.appendingPathComponent("outside.pdf")
        try Self.pdfBody.write(to: outside)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("\(Self.fullKey("CCCC3333"))-blob"), withDestinationURL: outside)
        try Self.record(identifier: "https://e.org/c.pdf", hash: Self.hashBytes(forKey: Self.fullKey("CCCC3333")))
            .write(to: dir.appendingPathComponent(Self.fullKey("CCCC3333")))
        let scan = try WebKitCacheReader.scan(cacheRoot: root)
        XCTAssertEqual(scan.pdfs.map(\.key), [Self.fullKey("AAAA1111")])
        XCTAssertEqual(scan.unreadableKeys, [], "not PDF bodies, so not unreadable PDF records either")
    }

    /// A record is a regular file, like a body: a symlink named like one is not trusted, even
    /// when it points at something that would parse.
    func testARecordThatIsASymlinkIsUnreadable() throws {
        try addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: Self.pdfBody)
        let dir = try addRecord(key: "BBBB2222", identifier: "https://e.org/b.pdf", body: Self.pdfBody)
        let name = Self.fullKey("BBBB2222")
        let elsewhere = root.appendingPathComponent("elsewhere-record")
        try FileManager.default.moveItem(at: dir.appendingPathComponent(name), to: elsewhere)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(name), withDestinationURL: elsewhere)
        let scan = try WebKitCacheReader.scan(cacheRoot: root)
        XCTAssertEqual(scan.pdfs.map(\.key), [Self.fullKey("AAAA1111")])
        XCTAssertEqual(scan.unreadableKeys, [name])
    }

    /// A folder that can be listed and not searched fails every lookup inside it with EACCES. The
    /// scan used to read that as "not a regular file" and answer "no PDFs" with exit 0.
    func testAnUnsearchableResourceFolderIsAPermissionErrorNotAnEmptyScan() throws {
        let dir = try addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: Self.pdfBody)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: root)) {
            guard case SafariBrowserError.fullDiskAccessRequired = $0 else { return XCTFail("\($0)") }
        }
    }

    /// A partial body that parsed fine is evidence the layout is understood; one unreadable record
    /// beside it is not "nothing parses", and `get --key` on the partial must reach its own message.
    func testAPartialRecordBesideAnUnreadableOneIsNotALayoutError() throws {
        try addRecord(key: "AAAA1111", identifier: "https://e.org/big.pdf", body: Self.pdfBody, range: "bytes=0-99")
        try addRecord(key: "BBBB2222", identifier: "x", body: Self.pdfBody, recordBytes: Data(repeating: 0, count: 40))
        let scan = try WebKitCacheReader.scan(cacheRoot: root)
        XCTAssertEqual(scan.pdfs, [])
        XCTAssertEqual(scan.partialKeys, [Self.fullKey("AAAA1111")])
        XCTAssertEqual(scan.unreadableKeys, [Self.fullKey("BBBB2222")])
        XCTAssertThrowsError(try PDFCacheSelection.select(keyPrefix: "AAAA1111", scan: scan)) {
            guard case SafariBrowserError.pdfCache(.partialBody) = $0 else { return XCTFail("\($0)") }
        }
    }

    /// A cache key is exactly 40 ASCII hex characters. A PDF body named anything else is counted,
    /// never named: the name is disk-derived text that could carry anything, and one that only
    /// looks like a key (a ligature that `uppercased()` turns into two letters) must not pass.
    func testAPDFBodyWhoseNameIsNotACacheKeyIsCountedAndNeverNamed() throws {
        let dir = try addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: Self.pdfBody)
        let signed = "ABCDEF12?sig=SECRET"
        try Self.pdfBody.write(to: dir.appendingPathComponent("\(signed)-blob"))
        try Self.record(identifier: "https://e.org/b.pdf").write(to: dir.appendingPathComponent(signed))
        // "ﬀ" + 38 × "A" uppercases to 40 hex characters; as a name it is 39 characters and not ASCII.
        let ligature = "\u{FB00}" + String(repeating: "A", count: 38)
        XCTAssertEqual(ligature.uppercased().count, 40)
        try Self.pdfBody.write(to: dir.appendingPathComponent("\(ligature)-blob"))
        try Self.record(identifier: "https://e.org/c.pdf", hash: Data([0xFF] + [UInt8](repeating: 0xAA, count: 19)))
            .write(to: dir.appendingPathComponent(ligature))

        let scan = try WebKitCacheReader.scan(cacheRoot: root)
        XCTAssertEqual(scan.pdfs.map(\.key), [Self.fullKey("AAAA1111")])
        XCTAssertEqual(scan.malformedNames, 2)
        XCTAssertEqual(scan.unreadableRecords, 2)
        XCTAssertEqual(scan.unreadableKeys, [], "a malformed name is never kept, so it can never be printed")
        XCTAssertThrowsError(try PDFCacheSelection.select(keyPrefix: "ABCDEF12", scan: scan)) {
            guard case SafariBrowserError.pdfCache(.noMatch) = $0 else { return XCTFail("\($0)") }
            XCTAssertFalse($0.localizedDescription.contains("SECRET"))
        }
        XCTAssertTrue(WebKitCacheReader.isCacheKey(String(repeating: "aB0", count: 13) + "f"))
        for bad in ["", String(repeating: "A", count: 39), String(repeating: "A", count: 41), String(repeating: "G", count: 40),
                    ligature, String(repeating: "A", count: 39) + "\u{0301}"] {
            XCTAssertFalse(WebKitCacheReader.isCacheKey(bad), bad)
        }
    }

    /// An I/O error carries the path. A name outside the key grammar is judged before anything
    /// touches the file, so a failure looking at it can neither fail the scan nor put the name
    /// into a message.
    func testAnUnreadableBodyWithAMalformedNameIsSkippedWithoutNamingIt() throws {
        let dir = try addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: Self.pdfBody)
        let locked = dir.appendingPathComponent("ABCDEF12?sig=SECRET-blob")
        try Self.pdfBody.write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("FOLDER?sig=SECRET-blob"), withIntermediateDirectories: false)
        let scan = try WebKitCacheReader.scan(cacheRoot: root)
        XCTAssertEqual(scan.pdfs.map(\.key), [Self.fullKey("AAAA1111")])
        XCTAssertEqual(scan.malformedNames, 0, "unreadable, so not known to be a PDF body")
    }

    /// Failing to list the version folder is a permission failure with its cause, not a folder that
    /// "holds nothing".
    func testAVersionFolderThatCannotBeListedKeepsItsCauseWhenRecordsIsMissing() throws {
        let version = root.appendingPathComponent("Version 17")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: version.path)   // search, no read
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: root)) {
            guard case SafariBrowserError.fullDiskAccessRequired = $0 else { return XCTFail("\($0)") }
        }
    }

    func testOnlyMalformedNamesIsAnUnsupportedLayoutNotAnEmptyCache() throws {
        let dir = try addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: nil)
        try Self.pdfBody.write(to: dir.appendingPathComponent("not-a-key-blob"))
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: root)) {
            guard case SafariBrowserError.pdfCache(.recordLayoutUnsupported(let detail)) = $0 else { return XCTFail("\($0)") }
            XCTAssertFalse(detail.contains("not-a-key"))
        }
    }

    /// `String(decoding:as:UTF16.self)` repairs an unpaired surrogate to U+FFFD, which would turn a
    /// broken record into a valid-looking URL. It is rejected instead.
    func testAnUnpairedSurrogateInASixteenBitStringIsRejectedNotRepaired() throws {
        func record(units: [UInt16]) -> Data {
            var out = Data(withUnsafeBytes(of: UInt32(17).littleEndian, Array.init))
            out.append(Self.string(""))
            out.append(Self.string("Resource"))
            out.append(contentsOf: withUnsafeBytes(of: UInt32(units.count).littleEndian, Array.init))
            out.append(0)
            for unit in units { out.append(contentsOf: withUnsafeBytes(of: unit.littleEndian, Array.init)) }
            out.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
            out.append(Data(repeating: 0x11, count: 20))
            return out
        }
        for units in [[0x0061, 0xD800], [0xDC00, 0x0061], [0xD800, 0x0061], [0xD800, 0xD800]] as [[UInt16]] {
            XCTAssertThrowsError(try WebKitCacheReader.parseRecordKey(record(units: units)), "\(units)") {
                XCTAssertEqual($0 as? WebKitCacheReader.RecordError, .malformedText)
            }
        }
        XCTAssertEqual(try WebKitCacheReader.parseRecordKey(record(units: Array("a😀b".utf16))).identifier, "a😀b")
    }

    func testEveryPDFRecordUnreadableIsAnUnsupportedLayoutNotAnEmptyCache() throws {
        try addRecord(key: "AAAA1111", identifier: "x", body: Self.pdfBody, recordBytes: Data(repeating: 0, count: 40))
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: root)) {
            guard case SafariBrowserError.pdfCache(.recordLayoutUnsupported) = $0 else { return XCTFail("\($0)") }
        }
    }

    func testAVersionFolderWithoutRecordsIsAnUnsupportedLayoutNotAnEmptyCache() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Version 17/SomethingNew"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: root)) {
            guard case SafariBrowserError.pdfCache(.recordLayoutUnsupported(let detail)) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(detail.contains("Records"), detail)
            XCTAssertTrue(detail.contains("SomethingNew"), "names what it did find: \(detail)")
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
        XCTAssertEqual(try WebKitCacheReader.scan(cacheRoot: root).pdfs.map(\.key), [Self.fullKey("AAAA1111")])
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
