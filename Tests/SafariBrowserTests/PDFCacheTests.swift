import ArgumentParser
import CoreGraphics
import Foundation
import XCTest
@testable import SafariBrowser

/// #210: selecting, copying, and presenting cached PDFs. Synthetic fixtures
/// only — nothing here reads the user's real cache or any live Safari state.
final class PDFCacheTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        WebKitCacheReaderTests.restorePermissions(dir)
        try FileManager.default.removeItem(at: dir)
    }

    static func makePDF(pages: Int) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return data as Data
    }

    func names(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    // MARK: - URL redaction

    func testRedactionRemovesQueryAndFragmentAndSaysWhetherAQueryWasThere() {
        XCTAssertEqual(PDFCacheURL.redact("https://e.org/a.pdf?X-Signature=abc#page=2"),
                       .init(display: "https://e.org/a.pdf", hadQuery: true))
        XCTAssertEqual(PDFCacheURL.redact("https://e.org/a.pdf"), .init(display: "https://e.org/a.pdf", hadQuery: false))
        // A `?` after the `#` belongs to the fragment, not to a query.
        XCTAssertEqual(PDFCacheURL.redact("https://e.org/a.pdf#frag?x=1"),
                       .init(display: "https://e.org/a.pdf", hadQuery: false))
        XCTAssertEqual(PDFCacheURL.removingFragment("https://e.org/a.pdf?x=1#p=2"), "https://e.org/a.pdf?x=1")
    }

    // MARK: - Selection form

    func testNothingSelectedIsRefusedAndAProfileOrFirstMatchAloneIsNotASelection() {
        // `hasTab` is TargetOptions.hasExplicitTarget; --profile / --first-match never set it.
        XCTAssertThrowsError(try PDFCacheSelection.form(hasTab: false, key: nil, file: nil, source: .cache)) {
            guard case SafariBrowserError.pdfCache(.selectionRequired) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try PDFCacheSelection.form(hasTab: false, key: nil, file: nil, source: .webkitPDFs)) {
            guard case SafariBrowserError.pdfCache(.selectionRequired) = $0 else { return XCTFail("\($0)") }
        }
    }

    func testEachOfTheThreeFormsAloneIsAccepted() throws {
        XCTAssertEqual(try PDFCacheSelection.form(hasTab: true, key: nil, file: nil, source: .cache), .tab)
        XCTAssertEqual(try PDFCacheSelection.form(hasTab: false, key: "0123abcd", file: nil, source: .cache), .key("0123abcd"))
        XCTAssertEqual(try PDFCacheSelection.form(hasTab: false, key: nil, file: "a.pdf", source: .webkitPDFs), .file("a.pdf"))
    }

    func testCombinationsAndMisplacedFlagsAreUsageErrors() {
        let cases: [(Bool, String?, String?, PDFCacheSource, String)] = [
            (true, "0123abcd", nil, .cache, "two forms"),
            (true, nil, "a.pdf", .webkitPDFs, "tab + file"),
            (false, "0123abcd", "a.pdf", .webkitPDFs, "key + file"),
            (false, nil, "a.pdf", .cache, "--file without --source webkit-pdfs"),
            (false, "0123abcd", nil, .webkitPDFs, "--key with --source webkit-pdfs"),
            (true, nil, nil, .webkitPDFs, "tab flag with --source webkit-pdfs"),
        ]
        for (hasTab, key, file, source, label) in cases {
            XCTAssertThrowsError(try PDFCacheSelection.form(hasTab: hasTab, key: key, file: file, source: source), label) {
                XCTAssertTrue($0 is PDFCacheSelection.UsageError, "\(label): \($0)")
            }
        }
    }

    func testKeyPrefixNeedsAtLeastEightHexCharacters() {
        for bad in ["0123", "0123abc", "zzzzzzzz", "0123abc!", ""] {
            XCTAssertThrowsError(try PDFCacheSelection.form(hasTab: false, key: bad, file: nil, source: .cache), bad) {
                XCTAssertTrue($0 is PDFCacheSelection.UsageError)
            }
        }
        XCTAssertThrowsError(try PDFCacheSelection.form(hasTab: false, key: "0123", file: nil, source: .cache)) {
            XCTAssertTrue(($0 as? PDFCacheSelection.UsageError)?.message.contains("8") == true)
        }
        XCTAssertNoThrow(try PDFCacheSelection.form(hasTab: false, key: "0123ABCD", file: nil, source: .cache))
    }

    // MARK: - Matching

    func pdf(key: String, url: String, partitionDirectory: String = "P1", partition: String = "", size: Int64 = 100, modified: Date? = nil) -> WebKitCachedPDF {
        WebKitCachedPDF(
            key: key, partitionDirectory: partitionDirectory, partition: partition, requestURL: url,
            bodyURL: dir.appendingPathComponent("\(key)-blob"), recordURL: dir.appendingPathComponent(key),
            size: size, modified: modified)
    }

    func testATabURLMatchesByExactStringWithTheFragmentRemoved() throws {
        let cached = [pdf(key: "AAAA1111AAAA", url: "https://example.org/a.pdf"),
                      pdf(key: "BBBB2222BBBB", url: "https://example.org/b.pdf")]
        XCTAssertEqual(try PDFCacheSelection.select(tabURL: "https://example.org/a.pdf#page=3", from: cached).key, "AAAA1111AAAA")
    }

    func testNoNormalisationAndACachedURLWithoutTheQueryIsNotAFallback() {
        let cached = [pdf(key: "AAAA1111AAAA", url: "https://example.org/a.pdf")]
        for tab in ["https://example.org/a.pdf?x=1", "https://example.org/a.pdf/", "HTTPS://example.org/a.pdf",
                    "https://example.org:443/a.pdf", "https://example.org/A.pdf"] {
            XCTAssertThrowsError(try PDFCacheSelection.select(tabURL: tab, from: cached), tab) {
                guard case SafariBrowserError.pdfCache(.noMatch) = $0 else { return XCTFail("\(tab): \($0)") }
            }
        }
    }

    func testTheSameURLInTwoPartitionsIsRefusedAndBothAreListed() {
        let cached = [pdf(key: "AAAA1111AAAA", url: "https://example.org/a.pdf", partitionDirectory: "P1", partition: "https://one.example"),
                      pdf(key: "CCCC3333CCCC", url: "https://example.org/a.pdf", partitionDirectory: "P2", partition: "https://two.example")]
        XCTAssertThrowsError(try PDFCacheSelection.select(tabURL: "https://example.org/a.pdf", from: cached)) {
            guard case SafariBrowserError.pdfCache(.ambiguous(_, let candidates)) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(candidates.count, 2)
            XCTAssertTrue(candidates[0].contains("AAAA1111AAAA".prefix(12)) && candidates[1].contains("CCCC3333CCCC".prefix(12)))
            XCTAssertTrue($0.localizedDescription.contains("--key"))
        }
    }

    func testFailureMessagesNeverCarryTheQueryOfASignedURL() {
        let signed = "https://cdn.example.org/f.pdf?X-Signature=SECRETVALUE#frag"
        let cached = [pdf(key: "AAAA1111AAAA", url: "https://cdn.example.org/f.pdf?X-Signature=SECRETVALUE", partition: ""),
                      pdf(key: "BBBB2222BBBB", url: "https://cdn.example.org/f.pdf?X-Signature=SECRETVALUE", partitionDirectory: "P2")]
        for other in [[], cached] {
            XCTAssertThrowsError(try PDFCacheSelection.select(tabURL: other.isEmpty ? signed : "https://cdn.example.org/f.pdf?X-Signature=SECRETVALUE", from: other)) {
                let text = $0.localizedDescription
                XCTAssertFalse(text.contains("SECRETVALUE"), text)
                XCTAssertFalse(text.contains("X-Signature"), text)
                XCTAssertTrue(text.contains("https://cdn.example.org/f.pdf"), text)
            }
        }
    }

    func testKeyPrefixMatchIsCaseInsensitiveAndMustBeUnique() throws {
        let scan = WebKitCacheReader.Scan(
            pdfs: [pdf(key: "ABCD1234EEEE", url: "https://e.org/a.pdf"), pdf(key: "ABCD1234FFFF", url: "https://e.org/b.pdf"),
                   pdf(key: "99990000AAAA", url: "https://e.org/c.pdf")],
            unreadableKeys: ["DEADBEEF0000"])
        XCTAssertEqual(try PDFCacheSelection.select(keyPrefix: "99990000", scan: scan).key, "99990000AAAA")
        XCTAssertEqual(try PDFCacheSelection.select(keyPrefix: "abcd1234e", scan: scan).key, "ABCD1234EEEE")
        XCTAssertThrowsError(try PDFCacheSelection.select(keyPrefix: "ABCD1234", scan: scan)) {
            guard case SafariBrowserError.pdfCache(.ambiguous(_, let candidates)) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(candidates.count, 2)
        }
        XCTAssertThrowsError(try PDFCacheSelection.select(keyPrefix: "00000000", scan: scan)) {
            guard case SafariBrowserError.pdfCache(.noMatch) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try PDFCacheSelection.select(keyPrefix: "DEADBEEF", scan: scan)) {
            guard case SafariBrowserError.pdfCache(.unreadableRecord(let key)) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(key, "DEADBEEF0000")
        }
    }

    // MARK: - Verified atomic copy

    func source(_ name: String, _ bytes: Data, mode: Int = 0o400) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    func outDir() throws -> URL {
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    func testAVerifiedCopyIsPublishedWithMode0600AndLeavesNoTemporaryFile() throws {
        let bytes = Self.makePDF(pages: 2)
        let src = try source("body-blob", bytes)
        let before = try FileManager.default.attributesOfItem(atPath: src.path)
        let out = try outDir()
        let result = try PDFCacheOutput.copyVerified(from: src, to: out.appendingPathComponent("a.pdf").path, force: false)
        XCTAssertEqual(result.pages, 2)
        XCTAssertEqual(result.size, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("a.pdf")), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("a.pdf").path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try names(in: out), ["a.pdf"])
        // The read-only source is untouched.
        let after = try FileManager.default.attributesOfItem(atPath: src.path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(after[.posixPermissions] as? Int, 0o400)
        XCTAssertEqual(try Data(contentsOf: src), bytes)
    }

    func testABodyThatIsNotAPDFOrIsTooShortCreatesNothing() throws {
        let out = try outDir()
        for (label, body) in [("html", Data("<html>hello</html>".utf8)), ("short", Data("%PD".utf8)), ("empty", Data())] {
            let src = try source("\(label)-blob", body)
            XCTAssertThrowsError(try PDFCacheOutput.copyVerified(from: src, to: out.appendingPathComponent("\(label).pdf").path, force: false), label) {
                guard case SafariBrowserError.pdfCache(.notAPDF) = $0 else { return XCTFail("\(label): \($0)") }
            }
        }
        XCTAssertEqual(try names(in: out), [])
    }

    func testAPDFMagicFollowedByGarbageIsRejectedAndNothingRemains() throws {
        let out = try outDir()
        let src = try source("garbage-blob", Data("%PDF-1.7\nthis is not a pdf at all\n".utf8) + Data(repeating: 0x41, count: 4000))
        XCTAssertThrowsError(try PDFCacheOutput.copyVerified(from: src, to: out.appendingPathComponent("g.pdf").path, force: false)) {
            guard case SafariBrowserError.pdfCache(.unreadablePDF) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try names(in: out), [])
    }

    func testATruncatedRealPDFIsRejected() throws {
        let out = try outDir()
        let full = Self.makePDF(pages: 3)
        let src = try source("cut-blob", full.prefix(full.count / 2))
        XCTAssertThrowsError(try PDFCacheOutput.copyVerified(from: src, to: out.appendingPathComponent("c.pdf").path, force: false)) {
            guard case SafariBrowserError.pdfCache(.unreadablePDF) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try names(in: out), [])
    }

    func testAnExistingDestinationIsKeptUnlessForceIsGiven() throws {
        let out = try outDir()
        let target = out.appendingPathComponent("a.pdf")
        try Data("old contents".utf8).write(to: target)
        let bytes = Self.makePDF(pages: 1)
        let src = try source("body-blob", bytes)
        XCTAssertThrowsError(try PDFCacheOutput.copyVerified(from: src, to: target.path, force: false)) {
            guard case SafariBrowserError.pdfCache(.destinationExists) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("old contents".utf8))
        XCTAssertEqual(try names(in: out), ["a.pdf"])
        _ = try PDFCacheOutput.copyVerified(from: src, to: target.path, force: true)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try names(in: out), ["a.pdf"])
    }

    /// The refusal comes before the source is read: a caller who forgot
    /// `--force` hears about the destination, not about whatever else would
    /// have been wrong with a copy that was never going to be published.
    func testAnExistingDestinationIsRefusedBeforeTheSourceIsRead() throws {
        let out = try outDir()
        let target = out.appendingPathComponent("a.pdf")
        try Data("old contents".utf8).write(to: target)
        let notAPDF = try source("html-blob", Data("<html>".utf8))
        XCTAssertThrowsError(try PDFCacheOutput.copyVerified(from: notAPDF, to: target.path, force: false)) {
            guard case SafariBrowserError.pdfCache(.destinationExists) = $0 else { return XCTFail("\($0)") }
        }
        let locked = try source("locked-blob", Self.makePDF(pages: 1), mode: 0o000)
        XCTAssertThrowsError(try PDFCacheOutput.copyVerified(from: locked, to: target.path, force: false)) {
            guard case SafariBrowserError.pdfCache(.destinationExists) = $0 else { return XCTFail("\($0)") }
        }
    }

    func testForceWithABadCopyLeavesTheExistingDestinationAlone() throws {
        let out = try outDir()
        let target = out.appendingPathComponent("a.pdf")
        try Data("old contents".utf8).write(to: target)
        let src = try source("html-blob", Data("<html>".utf8))
        XCTAssertThrowsError(try PDFCacheOutput.copyVerified(from: src, to: target.path, force: true))
        XCTAssertEqual(try Data(contentsOf: target), Data("old contents".utf8))
        XCTAssertEqual(try names(in: out), ["a.pdf"])
    }

    func testAMissingDestinationFolderAndADirectoryDestinationAreRefused() throws {
        let src = try source("body-blob", Self.makePDF(pages: 1))
        XCTAssertThrowsError(try PDFCacheOutput.copyVerified(from: src, to: dir.appendingPathComponent("nope/a.pdf").path, force: false)) {
            guard case SafariBrowserError.pdfCache(.destinationDirectoryMissing) = $0 else { return XCTFail("\($0)") }
        }
        let out = try outDir()
        let asDirectory = out.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: false)
        for force in [false, true] {
            XCTAssertThrowsError(try PDFCacheOutput.copyVerified(from: src, to: asDirectory.path, force: force))
            XCTAssertEqual(try names(in: out), ["dest"])
            XCTAssertEqual(try names(in: asDirectory), [])
        }
    }

    func testAnUnreadableSourceKeepsItsCauseAndCreatesNothing() throws {
        let out = try outDir()
        let src = try source("locked-blob", Self.makePDF(pages: 1), mode: 0o000)
        XCTAssertThrowsError(try PDFCacheOutput.copyVerified(from: src, to: out.appendingPathComponent("a.pdf").path, force: false)) {
            guard case SafariBrowserError.fullDiskAccessRequired = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try names(in: out), [])
    }

    // MARK: - Service: end to end over a synthetic cache

    func makeCache(_ entries: [(key: String, url: String, body: Data?, partition: String)]) throws -> PDFCachePaths {
        let root = dir.appendingPathComponent("WebKitCache", isDirectory: true)
        for entry in entries {
            let resources = root.appendingPathComponent("Version 17/Records/\(entry.partition)/Resource", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try WebKitCacheReaderTests.record(identifier: entry.url).write(to: resources.appendingPathComponent(entry.key))
            if let body = entry.body { try body.write(to: resources.appendingPathComponent("\(entry.key)-blob")) }
        }
        return PDFCachePaths(cacheRoot: root, temporaryRoot: dir.appendingPathComponent("tmp", isDirectory: true))
    }

    func testRetrieveByTabURLWritesTheCachedBodyAndReportsWhereItCameFrom() throws {
        let bytes = Self.makePDF(pages: 2)
        let paths = try makeCache([
            (key: "AAAA1111AAAA", url: "https://example.org/a.pdf?sig=SECRET", body: bytes, partition: "P1"),
            (key: "BBBB2222BBBB", url: "https://example.org/other.pdf", body: Self.makePDF(pages: 1), partition: "P1"),
        ])
        let out = try outDir()
        let retrieved = try PDFCacheService.retrieve(
            form: .tab, tabURL: "https://example.org/a.pdf?sig=SECRET#page=2", paths: paths,
            destination: out.appendingPathComponent("a.pdf").path, force: false)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("a.pdf")), bytes)
        XCTAssertEqual(retrieved.result.pages, 2)
        XCTAssertEqual(retrieved.origin, .networkCache(key: "AAAA1111AAAA", displayURL: "https://example.org/a.pdf"))
    }

    func testRetrieveByKeyAndTheTabFormNeedsAURL() throws {
        let paths = try makeCache([(key: "AAAA1111AAAA", url: "https://example.org/a.pdf", body: Self.makePDF(pages: 1), partition: "P1")])
        let out = try outDir()
        _ = try PDFCacheService.retrieve(form: .key("aaaa1111"), tabURL: nil, paths: paths,
                                         destination: out.appendingPathComponent("k.pdf").path, force: false)
        XCTAssertEqual(try names(in: out), ["k.pdf"])
        XCTAssertThrowsError(try PDFCacheService.retrieve(form: .tab, tabURL: nil, paths: paths,
                                                          destination: out.appendingPathComponent("t.pdf").path, force: false))
        XCTAssertEqual(try names(in: out), ["k.pdf"])
    }

    func testRetrieveWithAnAmbiguousTabWritesNothing() throws {
        let paths = try makeCache([
            (key: "AAAA1111AAAA", url: "https://example.org/a.pdf", body: Self.makePDF(pages: 1), partition: "P1"),
            (key: "CCCC3333CCCC", url: "https://example.org/a.pdf", body: Self.makePDF(pages: 1), partition: "P2"),
        ])
        let out = try outDir()
        XCTAssertThrowsError(try PDFCacheService.retrieve(form: .tab, tabURL: "https://example.org/a.pdf", paths: paths,
                                                          destination: out.appendingPathComponent("a.pdf").path, force: false)) {
            guard case SafariBrowserError.pdfCache(.ambiguous) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try names(in: out), [])
    }

    func testTheCacheIsNotFallenBackToWhenTheTemporaryFolderHoldsAMatch() throws {
        let paths = try makeCache([(key: "BBBB2222BBBB", url: "https://example.org/other.pdf", body: Self.makePDF(pages: 1), partition: "P1")])
        let folder = paths.temporaryRoot.appendingPathComponent("WebKitPDFs-abc", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.makePDF(pages: 1).write(to: folder.appendingPathComponent("a.pdf"))
        let out = try outDir()
        XCTAssertThrowsError(try PDFCacheService.retrieve(form: .tab, tabURL: "https://example.org/a.pdf", paths: paths,
                                                          destination: out.appendingPathComponent("a.pdf").path, force: false)) {
            guard case SafariBrowserError.pdfCache(.noMatch) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try names(in: out), [])
    }

    // MARK: - WebKitPDFs source

    func testTheTemporaryFolderSourceListsPDFsByNameAndFolderAndSelectsOnlyByFileName() throws {
        let tmp = dir.appendingPathComponent("tmp", isDirectory: true)
        for (folder, name, body) in [("WebKitPDFs-one", "a.pdf", Self.makePDF(pages: 1)),
                                      ("WebKitPDFs-two", "a.pdf", Self.makePDF(pages: 2)),
                                      ("WebKitPDFs-two", "b.pdf", Self.makePDF(pages: 3)),
                                      ("WebKitPDFs-two", "notes.txt", Data("plain".utf8)),
                                      ("SomethingElse", "c.pdf", Self.makePDF(pages: 1))] {
            let d = tmp.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try body.write(to: d.appendingPathComponent(name))
        }
        let paths = PDFCachePaths(cacheRoot: dir.appendingPathComponent("unused"), temporaryRoot: tmp)
        let listed = try WebKitTemporaryPDFs.scan(temporaryRoot: tmp)
        XCTAssertEqual(listed.map { "\($0.folder)/\($0.name)" }.sorted(), ["WebKitPDFs-one/a.pdf", "WebKitPDFs-two/a.pdf", "WebKitPDFs-two/b.pdf"])

        let out = try outDir()
        let retrieved = try PDFCacheService.retrieve(form: .file("b.pdf"), tabURL: nil, paths: paths,
                                                     destination: out.appendingPathComponent("b.pdf").path, force: false)
        XCTAssertEqual(retrieved.result.pages, 3)
        // The same name in two folders is refused, and both folders are listed.
        XCTAssertThrowsError(try PDFCacheService.retrieve(form: .file("a.pdf"), tabURL: nil, paths: paths,
                                                          destination: out.appendingPathComponent("a.pdf").path, force: false)) {
            guard case SafariBrowserError.pdfCache(.ambiguous(_, let candidates)) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(candidates.count, 2)
        }
        XCTAssertThrowsError(try PDFCacheService.retrieve(form: .file("missing.pdf"), tabURL: nil, paths: paths,
                                                          destination: out.appendingPathComponent("m.pdf").path, force: false)) {
            guard case SafariBrowserError.pdfCache(.noMatch) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try names(in: out), ["b.pdf"])
    }

    /// A name is compared to the names actually found in the folders; it is never
    /// joined onto a path. A naive join would resolve `../../secret.pdf` to a
    /// readable PDF outside the folder.
    func testAFileNameCannotEscapeItsFolder() throws {
        let tmp = dir.appendingPathComponent("tmp", isDirectory: true)
        let folder = tmp.appendingPathComponent("WebKitPDFs-x", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.makePDF(pages: 1).write(to: folder.appendingPathComponent("a.pdf"))
        try Self.makePDF(pages: 1).write(to: dir.appendingPathComponent("secret.pdf"))
        let paths = PDFCachePaths(cacheRoot: dir, temporaryRoot: tmp)
        let out = try outDir()
        for name in ["../../secret.pdf", "../WebKitPDFs-x/a.pdf", "sub/a.pdf", ".", "..", ""] {
            XCTAssertThrowsError(try PDFCacheService.retrieve(form: .file(name), tabURL: nil, paths: paths,
                                                              destination: out.appendingPathComponent("x.pdf").path, force: false), name)
        }
        XCTAssertEqual(try names(in: out), [])
    }

    func testAMissingTemporaryRootIsAnEmptyListingNotAnError() throws {
        XCTAssertEqual(try WebKitTemporaryPDFs.scan(temporaryRoot: dir.appendingPathComponent("does-not-exist")).count, 0)
    }

    // MARK: - Listing output

    func testTextRowsAndJSONNeverCarryTheQueryAndJSONSaysWhetherThereWasOne() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let entries = [pdf(key: "AAAA1111AAAA5555", url: "https://cdn.example.org/f.pdf?X-Signature=SECRETVALUE", size: 1234, modified: date),
                       pdf(key: "BBBB2222BBBB6666", url: "https://example.org/plain.pdf", partition: "https://top.example", size: 99, modified: date.addingTimeInterval(-60))]
        let rendered = PDFCacheFormat.cacheListing(entries, limit: 50, timeZone: TimeZone(identifier: "Asia/Taipei")!)
        XCTAssertEqual(rendered.rows.count, 2)
        XCTAssertTrue(rendered.rows[0].contains("AAAA1111AAAA"))
        XCTAssertFalse(rendered.rows[0].contains("AAAA1111AAAA5"), "only the first 12 characters of the key")
        XCTAssertTrue(rendered.rows[0].contains("https://cdn.example.org/f.pdf"))
        XCTAssertTrue(rendered.rows[1].contains("https://top.example"))
        XCTAssertFalse(rendered.rows.joined().contains("SECRETVALUE"))
        XCTAssertTrue(rendered.rows[0].contains("1234 B"))

        let json = try PDFCacheFormat.cacheListingJSON(entries, limit: 50)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(text.contains("SECRETVALUE"))
        XCTAssertFalse(text.contains("X-Signature"))
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0]["key"] as? String, "AAAA1111AAAA5555", "JSON carries the full key")
        XCTAssertEqual(array[0]["url"] as? String, "https://cdn.example.org/f.pdf")
        XCTAssertEqual(array[0]["has_query"] as? Bool, true)
        XCTAssertEqual(array[1]["has_query"] as? Bool, false)
        XCTAssertEqual(array[0]["size"] as? Int, 1234)
        XCTAssertEqual(Set(array[0].keys), ["key", "partition", "url", "has_query", "size", "modified"])
    }

    func testTheLimitAppliesToTheNewestFirstAndAnEmptyListingIsEmptyJSON() throws {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let entries = (0..<80).map { pdf(key: String(format: "%012d", $0), url: "https://e.org/\($0).pdf", modified: base.addingTimeInterval(Double($0))) }
        let ordered = entries.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        let rendered = PDFCacheFormat.cacheListing(ordered, limit: 50, timeZone: .current)
        XCTAssertEqual(rendered.rows.count, 50)
        XCTAssertTrue(rendered.rows[0].contains("000000000079"))
        XCTAssertEqual(String(decoding: try PDFCacheFormat.cacheListingJSON([], limit: 50), as: UTF8.self), "[]")
    }

    func testControlCharactersInAURLCannotBreakARow() {
        let entries = [pdf(key: "AAAA1111AAAA", url: "https://e.org/a\u{1B}[31m\nfake row.pdf")]
        let rows = PDFCacheFormat.cacheListing(entries, limit: 50, timeZone: .current).rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].contains("\n"))
        XCTAssertFalse(rows[0].contains("\u{1B}"))
    }

    // MARK: - Command surface

    func testGetParsesTheThreeFormsAndRefusesConflictsAtParseTime() throws {
        XCTAssertNoThrow(try PDFCacheGet.parse(["out.pdf", "--url", "example.org/a.pdf"]))
        XCTAssertNoThrow(try PDFCacheGet.parse(["out.pdf", "--key", "0123abcd"]))
        XCTAssertNoThrow(try PDFCacheGet.parse(["out.pdf", "--source", "webkit-pdfs", "--file", "a.pdf"]))
        XCTAssertNoThrow(try PDFCacheGet.parse(["out.pdf"]), "no selection is refused by run(), before any read, not by the parser")
        XCTAssertThrowsError(try PDFCacheGet.parse(["out.pdf", "--url", "x", "--key", "0123abcd"]))
        XCTAssertThrowsError(try PDFCacheGet.parse(["out.pdf", "--key", "0123"]))
        XCTAssertThrowsError(try PDFCacheGet.parse(["out.pdf", "--file", "a.pdf"]))
    }

    func testAProfileAloneIsNotATargetSelection() throws {
        let profileOnly = try PDFCacheGet.parse(["out.pdf", "--profile", "Work", "--first-match"])
        XCTAssertFalse(profileOnly.target.hasExplicitTarget)
        for flags in [["--url", "a"], ["--url-exact", "a"], ["--url-endswith", "a"], ["--url-regex", "a"],
                      ["--window", "1"], ["--window", "1", "--tab-in-window", "2"], ["--document", "1"], ["--tab", "1"]] {
            XCTAssertTrue(try PDFCacheGet.parse(["out.pdf"] + flags).target.hasExplicitTarget, "\(flags)")
        }
    }

    func testListRejectsANonPositiveLimit() {
        XCTAssertThrowsError(try PDFCacheList.parse(["--limit", "0"]))
        XCTAssertThrowsError(try PDFCacheList.parse(["--limit", "-3"]))
        XCTAssertNoThrow(try PDFCacheList.parse(["--limit", "5", "--json", "--source", "webkit-pdfs"]))
    }

    // MARK: - Structure: no request, no script, no control

    /// The command exists so that nothing reaches the publisher. This pins that
    /// structurally: the files that implement it name no network, script or UI
    /// automation API, and the command file reaches Safari for exactly one
    /// passive read — the target tab's URL.
    func testTheImplementationNamesNoNetworkScriptOrControlAPI() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SafariBrowser")
        let files = ["Utilities/WebKitCacheReader.swift", "Utilities/PDFCacheSelection.swift", "Utilities/PDFCacheOutput.swift",
                     "Utilities/PDFCacheService.swift", "Utilities/PDFCacheFormat.swift", "Utilities/WebKitTemporaryPDFs.swift",
                     "Commands/PDFCacheCommand.swift"]
        let forbidden = ["URLSession", "URLRequest", "NSURLConnection", "CFNetwork", "Network.framework", "import Network", "fetch(",
                         "doJavaScript", "NSAppleScript", "osascript", "AXUIElement", "AXPress", "CGEvent", "Process(", "NSWorkspace",
                         "SafariBridge.open", "SafariBridge.click", "reload"]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for token in forbidden {
                XCTAssertFalse(code.contains(token), "\(file) names \(token)")
            }
            let pattern = try NSRegularExpression(pattern: #"SafariBridge\.(\w+)"#)
            let bridgeCalls = Set(pattern.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
                Range($0.range(at: 1), in: code).map { String(code[$0]) }
            })
            if file == "Commands/PDFCacheCommand.swift" {
                XCTAssertEqual(bridgeCalls, ["getCurrentURL"], "\(file): \(bridgeCalls)")
            } else {
                XCTAssertEqual(bridgeCalls, [], "\(file): \(bridgeCalls)")
            }
        }
    }
}
