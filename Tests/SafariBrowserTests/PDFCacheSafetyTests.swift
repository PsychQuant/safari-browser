import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import SafariBrowser

/// #210 re-review: the writer's destination handling, the protection of Safari's own folders, the
/// owner-only staging file, what a record says about its body, and the command layer. Every fixture
/// is synthetic; nothing here reads the user's real cache.
final class PDFCacheSafetyTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-cache-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        WebKitCacheReaderTests.restorePermissions(dir)
        try FileManager.default.removeItem(at: dir)
    }

    private func pdfSource(_ name: String = "body-blob", pages: Int = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try PDFCacheTests.makePDF(pages: pages).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        return url
    }

    private func folder(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func names(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    // MARK: - The destination text is the text the kernel resolves

    /// Foundation's `standardizedFileURL` folds `..` lexically. After a symlink that names another
    /// folder than the one the kernel (and `cp`) reach, and with `--force` it replaced a file the
    /// person never named.
    func testDotDotAfterASymlinkMeansWhatTheKernelMakesOfIt() throws {
        let real = try folder("real")
        let sub = try folder("real/sub")
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sub)
        // The file the literal reading would replace.
        let bystander = dir.appendingPathComponent("x.pdf")
        try Data("not yours".utf8).write(to: bystander)

        let result = try PDFCacheOutput.copyVerified(
            from: try pdfSource(), to: link.path + "/../x.pdf", force: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("x.pdf").path), "link/.. is the folder link points into")
        XCTAssertEqual(try Data(contentsOf: bystander), Data("not yours".utf8), "the file the literal text names is untouched")
        XCTAssertTrue(result.path.hasSuffix("/real/x.pdf"), result.path)
    }

    /// A quoted literal `~` is a folder named `~`, as for every POSIX tool; nothing expands it.
    func testALeadingTildeIsNotExpanded() throws {
        let cwd = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(cwd) }
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(dir.path))
        XCTAssertThrowsError(try PDFCacheOutput.copyVerified(from: try pdfSource(), to: "~/x.pdf", force: false)) {
            guard case SafariBrowserError.pdfCache(.destinationDirectoryMissing(let path)) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(path, "~", "it looked for a folder named ~ here, not for the home folder")
        }
    }

    func testADestinationThatDoesNotNameAFileIsRefused() throws {
        let out = try folder("out")
        let source = try pdfSource()
        for destination in ["", out.path + "/", out.path + "/.", out.path + "/..", ".", ".."] {
            XCTAssertThrowsError(try PDFCacheOutput.copyVerified(from: source, to: destination, force: true), destination.debugDescription) {
                guard case SafariBrowserError.pdfCache(.destinationWriteFailed) = $0 else { return XCTFail("\(destination): \($0)") }
            }
        }
        XCTAssertEqual(try names(in: out), [])
    }

    func testASingleNameIsWrittenInTheCurrentFolderAndARootNameInTheRoot() throws {
        let split = try PDFCacheOutput.splitDestination("a.pdf")
        XCTAssertEqual(split.parent, ".")
        XCTAssertEqual(split.name, "a.pdf")
        let root = try PDFCacheOutput.splitDestination("/a.pdf")
        XCTAssertEqual(root.parent, "/")
        XCTAssertEqual(root.name, "a.pdf")
        let nested = try PDFCacheOutput.splitDestination("/x/y/a b.pdf")
        XCTAssertEqual(nested.parent, "/x/y")
        XCTAssertEqual(nested.name, "a b.pdf")
    }

    /// The success line names the folder as the descriptor reports it, so it says where the file is.
    func testTheReportedPathIsWhereTheFileIs() throws {
        let real = try folder("real")
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let result = try PDFCacheOutput.copyVerified(from: try pdfSource(), to: alias.path + "/a.pdf", force: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path), result.path)
        XCTAssertFalse(result.path.contains("/alias/"), "the alias is not where the file is: \(result.path)")
    }

    // MARK: - Anchoring: the folder is opened once

    /// The folder is swapped for a symlink after it was opened. Every later step names entries
    /// relative to the descriptor, so the copy lands in the folder that was opened. Were the steps
    /// path-based again, it would land in the elsewhere folder.
    func testSwappingTheFolderAfterItWasOpenedCannotMoveTheWrite() throws {
        let out = try folder("out")
        let elsewhere = try folder("elsewhere")
        let moved = dir.appendingPathComponent("moved-aside")
        let result = try PDFCacheOutput.copyVerified(
            from: try pdfSource(), to: out.path + "/a.pdf", force: false,
            afterParentOpened: {
                try? FileManager.default.moveItem(at: out, to: moved)
                try? FileManager.default.createSymbolicLink(at: out, withDestinationURL: elsewhere)
            })
        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual(try names(in: moved), ["a.pdf"], "the folder that was opened got the file")
        XCTAssertEqual(try names(in: elsewhere), [], "the folder the name was swapped to got nothing")
    }

    // MARK: - Safari's own folders are never a destination

    private func cache(pdfs count: Int = 1) throws -> (paths: PDFCachePaths, recordURL: URL, bodyURL: URL) {
        let root = dir.appendingPathComponent("WebKitCache", isDirectory: true)
        let resources = root.appendingPathComponent("Version 17/Records/\(WebKitCacheReaderTests.partitionOne)/Resource", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let body = PDFCacheTests.makePDF(pages: 1)
        var last = (URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/"))
        for index in 0..<count {
            let name = WebKitCacheReaderTests.fullKey("AAAA\(1111 + index)")
            let record = resources.appendingPathComponent(name)
            let blob = resources.appendingPathComponent("\(name)-blob")
            try WebKitCacheReaderTests.record(
                identifier: "https://example.org/\(index).pdf", hash: WebKitCacheReaderTests.hashBytes(forKey: name), bodySize: UInt64(body.count))
                .write(to: record)
            try body.write(to: blob)
            last = (record, blob)
        }
        return (PDFCachePaths(cacheRoot: root, temporaryRoot: dir.appendingPathComponent("tmp", isDirectory: true)), last.0, last.1)
    }

    /// `--force` with the record of the entry being copied as the destination replaced the record
    /// and left the cache unlistable. Not only the body being copied is Safari's: the whole folder is.
    func testForceCannotReplaceAnyFileInSafarisCacheFolder() throws {
        let c = try cache(pdfs: 2)
        let recordBytes = try Data(contentsOf: c.recordURL)
        let other = c.recordURL.deletingLastPathComponent().appendingPathComponent(WebKitCacheReaderTests.fullKey("AAAA1111"))
        let alias = dir.appendingPathComponent("cache-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: c.paths.cacheRoot)
        let viaAlias = alias.path + "/Version 17/Records/\(WebKitCacheReaderTests.partitionOne)/Resource/" + c.recordURL.lastPathComponent
        for (label, destination) in [("its own record", c.recordURL.path), ("another entry's record", other.path), ("through a symlink", viaAlias)] {
            XCTAssertThrowsError(try PDFCacheService.retrieve(
                form: .key(String(c.recordURL.lastPathComponent.prefix(12))), tabURL: nil, paths: c.paths, destination: destination, force: true), label
            ) {
                guard case SafariBrowserError.pdfCache(.destinationWriteFailed(_, let detail)) = $0 else { return XCTFail("\(label): \($0)") }
                XCTAssertTrue(detail.contains("Safari's own cache folder"), "\(label): \(detail)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: c.recordURL), recordBytes, "the record is untouched")
        XCTAssertEqual(try WebKitCacheReader.scan(cacheRoot: c.paths.cacheRoot).pdfs.count, 2, "the cache still lists")
    }

    func testAFolderNextToSafarisCacheIsNotMistakenForInsideIt() throws {
        let c = try cache()
        let neighbour = try folder("WebKitCache-copy")
        let result = try PDFCacheService.retrieve(
            form: .key(String(c.recordURL.lastPathComponent.prefix(12))), tabURL: nil, paths: c.paths,
            destination: neighbour.path + "/a.pdf", force: false)
        XCTAssertEqual(result.result.pages, 1)
    }

    func testTheTemporaryFolderOfTheChosenPDFIsProtectedToo() throws {
        let tmp = dir.appendingPathComponent("tmp", isDirectory: true)
        let pdfFolder = tmp.appendingPathComponent("WebKitPDFs-abc", isDirectory: true)
        try FileManager.default.createDirectory(at: pdfFolder, withIntermediateDirectories: true)
        try PDFCacheTests.makePDF(pages: 1).write(to: pdfFolder.appendingPathComponent("doc.pdf"))
        let paths = PDFCachePaths(cacheRoot: dir.appendingPathComponent("none"), temporaryRoot: tmp)
        XCTAssertThrowsError(try PDFCacheService.retrieve(
            form: .file("doc.pdf"), tabURL: nil, paths: paths, destination: pdfFolder.path + "/copy.pdf", force: true)
        ) {
            guard case SafariBrowserError.pdfCache(.destinationWriteFailed) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try names(in: pdfFolder), ["doc.pdf"])
    }

    // MARK: - The source is checked again right before a forced publish

    /// A link from the cached file to the destination, made after the first look, would have the
    /// forced rename replace Safari's directory entry. The check is repeated before the rename.
    func testAForcedPublishRefusesADestinationThatBecameTheSourceInTheMeantime() throws {
        let out = try folder("out")
        let source = try pdfSource("cached-blob")
        let target = out.appendingPathComponent("a.pdf")
        XCTAssertThrowsError(try PDFCacheOutput.copyVerified(
            from: source, to: target.path, force: true,
            beforePublish: { _ in _ = link(source.path, target.path) })
        ) {
            guard case SafariBrowserError.pdfCache(.destinationWriteFailed(_, let detail)) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(detail.contains("read from"), detail)
        }
        var a = stat(), b = stat()
        XCTAssertEqual(stat(source.path, &a), 0)
        XCTAssertEqual(stat(target.path, &b), 0)
        XCTAssertEqual(a.st_ino, b.st_ino, "the link is still the source's own entry: it was not replaced")
        XCTAssertEqual(try names(in: out), ["a.pdf"], "no temporary file remains")
    }

    // MARK: - Owner-only, whatever the folder hands down

    private func addInheritableACL(to folder: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read,write,delete,file_inherit,directory_inherit", folder.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func hasExtendedACL(_ url: URL) -> Bool {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
    }

    /// An inheritable ACL on the destination folder is handed to every file created in it, and
    /// grants other users access independently of the mode bits.
    func testAnACLTheFolderHandsDownIsNotLeftOnTheCopy() throws {
        let out = try folder("out")
        guard try addInheritableACL(to: out) else { throw XCTSkip("this file system does not take ACLs") }
        // The control: a file created plainly in that folder does inherit the entry.
        let plain = out.appendingPathComponent("plain")
        try Data("x".utf8).write(to: plain)
        guard hasExtendedACL(plain) else { throw XCTSkip("this file system does not inherit ACLs") }
        try FileManager.default.removeItem(at: plain)

        let result = try PDFCacheOutput.copyVerified(from: try pdfSource(), to: out.appendingPathComponent("a.pdf").path, force: false)
        XCTAssertFalse(hasExtendedACL(URL(fileURLWithPath: result.path)), "the copy has no ACL entry")
        var info = stat()
        XCTAssertEqual(stat(result.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testTheCopyIsOwnerOnlyEvenUnderAPermissiveUmask() throws {
        let previous = umask(0)
        defer { umask(previous) }
        let out = try folder("out")
        let result = try PDFCacheOutput.copyVerified(from: try pdfSource(), to: out.appendingPathComponent("a.pdf").path, force: false)
        var info = stat()
        XCTAssertEqual(stat(result.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    /// The mode is 0600 as the spec says, not whatever the umask leaves of it: under a restrictive
    /// umask the plain creation mode would have given 0400, and a copy the owner cannot write to.
    func testTheCopyIsExactlyMode0600UnderARestrictiveUmask() throws {
        // Everything else is created first: under this umask the test's own folders would not be writable.
        let out = try folder("out")
        let source = try pdfSource()
        let previous = umask(0o277)
        defer { umask(previous) }
        let result = try PDFCacheOutput.copyVerified(from: source, to: out.appendingPathComponent("a.pdf").path, force: false)
        var info = stat()
        XCTAssertEqual(stat(result.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    // MARK: - Verification reads

    /// A read failure while verifying is reported with its errno, never as a verified copy. The extra
    /// check at the end of `verifiedPageCount` (pages that read fine from a copy that could not be
    /// read to the end) is not pinned here: CoreGraphics fails by itself as soon as a read it needs
    /// fails, and no PDF could be built for which it does not.
    func testAFailedReadDecidesTheVerdictEvenWhenCoreGraphicsAccepted() throws {
        let bytes = PDFCacheTests.makePDF(pages: 2)
        let url = dir.appendingPathComponent("two.pdf")
        try bytes.write(to: url)
        let fd = open(url.path, O_RDONLY)
        defer { close(fd) }
        // Baseline: the same reads succeed and the document is accepted.
        XCTAssertEqual(try PDFCacheOutput.verifiedPageCount(fd: fd, size: Int64(bytes.count)), 2)
        // Every read that CoreGraphics makes goes through the injected closure; the one that asks
        // for bytes ending at the end of the file fails, the rest are real.
        final class Counter: @unchecked Sendable { var failed = 0 }
        let counter = Counter()
        let size = Int64(bytes.count)
        XCTAssertThrowsError(try PDFCacheOutput.verifiedPageCount(fd: fd, size: size, read: { fd, buffer, count, position in
            if Int64(position) + Int64(count) >= size, counter.failed == 0 {
                counter.failed += 1
                return (-1, EIO)
            }
            let result = pread(fd, buffer, count, position)
            return (result, result < 0 ? errno : 0)
        })) {
            guard case SafariBrowserError.pdfCache(.unreadablePDF(let detail)) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(detail.contains("errno \(EIO)"), detail)
        }
        XCTAssertEqual(counter.failed, 1)
    }

    // MARK: - What a record says about its body

    func testARecordWhoseBodyLengthDisagreesIsNeitherListedNorTrusted() throws {
        let reader = WebKitCacheReaderTests()
        reader.root = dir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: reader.root, withIntermediateDirectories: true)
        try reader.addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: WebKitCacheReaderTests.pdfBody)
        try reader.addRecord(key: "BBBB2222", identifier: "https://e.org/b.pdf", body: WebKitCacheReaderTests.pdfBody, bodySizeOverride: 7)
        let scan = try WebKitCacheReader.scan(cacheRoot: reader.root)
        XCTAssertEqual(scan.pdfs.map(\.key), [WebKitCacheReaderTests.fullKey("AAAA1111")])
        XCTAssertEqual(scan.outOfSyncKeys, [WebKitCacheReaderTests.fullKey("BBBB2222")])
        XCTAssertEqual(scan.unreadableRecords, 0, "a record that parses is not a layout problem")
        // By key: its own message, not "no match" and not a copy.
        XCTAssertThrowsError(try PDFCacheSelection.select(keyPrefix: "BBBB2222", scan: scan)) {
            guard case SafariBrowserError.pdfCache(.recordDisagrees) = $0 else { return XCTFail("\($0)") }
        }
        // By tab: a miss says that part of the cache was not considered.
        XCTAssertThrowsError(try PDFCacheSelection.select(tabURL: "https://e.org/b.pdf", scan: scan)) {
            guard case SafariBrowserError.pdfCache(.noMatch(_, let note)) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(note?.contains("not considered") == true, "\(String(describing: note))")
            XCTAssertTrue("\($0)".contains("pdf-cache list") || ($0 as? SafariBrowserError)?.errorDescription?.contains("pdf-cache list") == true)
        }
    }

    func testARecordThatEndsBeforeTheBodyFieldsIsUnreadable() throws {
        let reader = WebKitCacheReaderTests()
        reader.root = dir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: reader.root, withIntermediateDirectories: true)
        let name = WebKitCacheReaderTests.fullKey("AAAA1111")
        let short = WebKitCacheReaderTests.record(
            identifier: "https://e.org/a.pdf", hash: WebKitCacheReaderTests.hashBytes(forKey: name), trailer: Data(repeating: 0, count: 10))
        try reader.addRecord(key: "AAAA1111", identifier: "x", body: WebKitCacheReaderTests.pdfBody, recordBytes: short)
        try reader.addRecord(key: "BBBB2222", identifier: "https://e.org/b.pdf", body: WebKitCacheReaderTests.pdfBody)
        let scan = try WebKitCacheReader.scan(cacheRoot: reader.root)
        XCTAssertEqual(scan.unreadableKeys, [name])
        XCTAssertEqual(scan.pdfs.count, 1)
    }

    func testTheBodyFieldsAreReadAtTheObservedOffsets() throws {
        let key = WebKitCacheReaderTests.fullKey("AAAA1111")
        let data = WebKitCacheReaderTests.record(
            identifier: "https://e.org/a.pdf", hash: WebKitCacheReaderTests.hashBytes(forKey: key), bodySize: 123_456_789_012)
        let body = try WebKitCacheReader.parseRecordBody(data)
        XCTAssertEqual(body.bodySize, 123_456_789_012)
        XCTAssertEqual(body.bodyHash, Data(repeating: 0xCD, count: 20))
        for cut in stride(from: 0, to: data.count - 16, by: 7) {
            XCTAssertThrowsError(try WebKitCacheReader.parseRecordBody(data.prefix(cut)), "cut at \(cut)")
        }
    }

    // MARK: - Layout and names

    func testAStoreThatWasNeverWrittenToIsEmptyNotLayoutDrift() throws {
        let version = dir.appendingPathComponent("Version 17", isDirectory: true)
        try FileManager.default.createDirectory(at: version.appendingPathComponent("Blobs"), withIntermediateDirectories: true)
        try Data("salt".utf8).write(to: version.appendingPathComponent("salt"))
        XCTAssertEqual(try WebKitCacheReader.scan(cacheRoot: dir).pdfs, [])
        // A Blobs folder with something in it, or another folder, is not that state.
        try Data("x".utf8).write(to: version.appendingPathComponent("Blobs/AAAA"))
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: dir)) {
            guard case SafariBrowserError.pdfCache(.recordLayoutUnsupported) = $0 else { return XCTFail("\($0)") }
        }
    }

    func testFoldersAndVersionNamesThatAreNotOfTheLayoutAreCountedNotNamed() throws {
        let reader = WebKitCacheReaderTests()
        reader.root = dir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: reader.root, withIntermediateDirectories: true)
        try reader.addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: WebKitCacheReaderTests.pdfBody)
        let strange = reader.root.appendingPathComponent("Version 17/Records/part?sig=SECRET/Resource", isDirectory: true)
        try FileManager.default.createDirectory(at: strange, withIntermediateDirectories: true)
        let scan = try WebKitCacheReader.scan(cacheRoot: reader.root)
        XCTAssertEqual(scan.skippedFolders, 1)
        XCTAssertEqual(scan.pdfs.count, 1)

        let versions = dir.appendingPathComponent("versions", isDirectory: true)
        try FileManager.default.createDirectory(at: versions.appendingPathComponent("Version 18?sig=SECRET"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: versions.appendingPathComponent("Version 16"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: versions)) {
            let text = ($0 as? SafariBrowserError)?.errorDescription ?? "\($0)"
            XCTAssertFalse(text.contains("SECRET"), text)
            XCTAssertTrue(text.contains("Version 16"), text)
            XCTAssertTrue(text.contains("1 other"), text)
        }

        // The layout error for a missing Records folder does not name what it should not either.
        let layout = dir.appendingPathComponent("layout", isDirectory: true)
        try FileManager.default.createDirectory(at: layout.appendingPathComponent("Version 17/Blob?sig=SECRET"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.appendingPathComponent("Version 17/SomethingNew"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: layout)) {
            let text = ($0 as? SafariBrowserError)?.errorDescription ?? "\($0)"
            XCTAssertFalse(text.contains("SECRET"), text)
            XCTAssertTrue(text.contains("SomethingNew"), text)
        }
    }

    /// A folder that can be listed and not searched answers every lookup with EACCES, and when no
    /// entry in it has a name the scan looks up, nothing would say so.
    func testAnUnsearchableResourceFolderIsAPermissionErrorWhateverItHolds() throws {
        for contents in [[], ["notes.txt"], ["not-a-key-blob"]] {
            let root = dir.appendingPathComponent("cache-\(contents.count)-\(contents.first ?? "empty")", isDirectory: true)
            let resources = root.appendingPathComponent("Version 17/Records/\(WebKitCacheReaderTests.partitionOne)/Resource", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            for name in contents { try Data("x".utf8).write(to: resources.appendingPathComponent(name)) }
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: resources.path)
            XCTAssertThrowsError(try WebKitCacheReader.scan(cacheRoot: root), "holding \(contents)") {
                guard case SafariBrowserError.fullDiskAccessRequired = $0 else { return XCTFail("holding \(contents): \($0)") }
            }
        }
    }

    // MARK: - A file that vanishes while the scan runs (Safari evicts while it runs)

    private struct VanishingReader: WebKitCacheFileReading {
        let vanishing: (URL) -> Bool
        func readPrefix(at url: URL, maxBytes: Int) throws -> Data {
            if vanishing(url) { throw SafariBrowserError.safariDataFileNotFound(path: url.path) }
            return try POSIXFilePrefixReader().readPrefix(at: url, maxBytes: maxBytes)
        }
    }

    func testABodyOrARecordThatVanishesMidScanIsNotAFailure() throws {
        let reader = WebKitCacheReaderTests()
        reader.root = dir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: reader.root, withIntermediateDirectories: true)
        try reader.addRecord(key: "AAAA1111", identifier: "https://e.org/a.pdf", body: WebKitCacheReaderTests.pdfBody)
        try reader.addRecord(key: "BBBB2222", identifier: "https://e.org/b.pdf", body: WebKitCacheReaderTests.pdfBody)
        // A body that is gone is not a PDF body.
        let bodyGone = try WebKitCacheReader.scan(cacheRoot: reader.root, reader: VanishingReader { $0.lastPathComponent.hasSuffix("-blob") && $0.lastPathComponent.hasPrefix("BBBB") })
        XCTAssertEqual(bodyGone.pdfs.map(\.key), [WebKitCacheReaderTests.fullKey("AAAA1111")])
        XCTAssertEqual(bodyGone.unreadableRecords, 0)
        // A record that is gone makes that entry unreadable, and the others are still listed.
        let recordGone = try WebKitCacheReader.scan(cacheRoot: reader.root, reader: VanishingReader { !$0.lastPathComponent.hasSuffix("-blob") && $0.lastPathComponent.hasPrefix("BBBB") })
        XCTAssertEqual(recordGone.pdfs.map(\.key), [WebKitCacheReaderTests.fullKey("AAAA1111")])
        XCTAssertEqual(recordGone.unreadableKeys, [WebKitCacheReaderTests.fullKey("BBBB2222")])
    }

    // MARK: - The scan orders what it lists

    func testTheScanListsTheNewestRecordFirst() throws {
        let reader = WebKitCacheReaderTests()
        reader.root = dir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: reader.root, withIntermediateDirectories: true)
        var dirs: [URL] = []
        for (key, age) in [("AAAA1111", 300.0), ("BBBB2222", 100.0), ("CCCC3333", 200.0)] {
            dirs.append(try reader.addRecord(key: key, identifier: "https://e.org/\(key).pdf", body: WebKitCacheReaderTests.pdfBody))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: dirs[0].appendingPathComponent(WebKitCacheReaderTests.fullKey(key)).path)
        }
        let scan = try WebKitCacheReader.scan(cacheRoot: reader.root)
        XCTAssertEqual(scan.pdfs.map { String($0.key.prefix(4)) }, ["BBBB", "CCCC", "AAAA"])
    }

    // MARK: - The command layer

    /// What `get` asks Safari for: the tab flags as given, `--first-match` only when given.
    func testGetPassesTheTargetAndFirstMatchOnToTheTabURLRead() async throws {
        let c = try cache()
        final class Seen: @unchecked Sendable {
            var firstMatch: [Bool] = []
            var targets: [SafariBridge.TargetDocument] = []
        }
        for given in [false, true] {
            let seen = Seen()
            var command = try PDFCacheGet.parse(["\(dir.path)/out-\(given).pdf", "--url", "example.org"] + (given ? ["--first-match"] : []))
            try await command.run(paths: c.paths, tabURL: { target, firstMatch in
                seen.targets.append(target); seen.firstMatch.append(firstMatch)
                return "https://example.org/0.pdf"
            })
            XCTAssertEqual(seen.firstMatch, [given], "first-match given: \(given)")
            XCTAssertEqual(seen.targets, [.urlMatch(.contains("example.org"))])
            XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir.path)/out-\(given).pdf"))
        }
    }

    func testGetWithNoTabFlagNeverReadsATab() async throws {
        let c = try cache()
        var command = try PDFCacheGet.parse(["\(dir.path)/out.pdf", "--key", String(c.recordURL.lastPathComponent.prefix(12))])
        try await command.run(paths: c.paths, tabURL: { _, _ in
            XCTFail("a --key selection must not ask Safari for anything")
            return ""
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir.path)/out.pdf"))
    }

    /// stdout and stderr of the body, through the process's real descriptors.
    private func captured(_ body: () throws -> Void) throws -> (out: String, err: String) {
        func redirect(_ fd: Int32) throws -> (file: URL, saved: Int32) {
            let url = dir.appendingPathComponent("cap-\(fd)-\(UUID().uuidString)")
            let target = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard target >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            fflush(nil)
            let saved = dup(fd)
            dup2(target, fd)
            close(target)
            return (url, saved)
        }
        let out = try redirect(STDOUT_FILENO), err = try redirect(STDERR_FILENO)
        var failure: Error?
        do { try body() } catch { failure = error }
        fflush(nil)
        dup2(out.saved, STDOUT_FILENO); close(out.saved)
        dup2(err.saved, STDERR_FILENO); close(err.saved)
        if let failure { throw failure }
        return (try String(contentsOf: out.file, encoding: .utf8), try String(contentsOf: err.file, encoding: .utf8))
    }

    private func listing(_ args: [String], paths: PDFCachePaths) throws -> (out: String, err: String) {
        let command = try PDFCacheList.parse(args)
        return try captured { try command.run(paths: paths, timeZone: TimeZone(identifier: "UTC")!) }
    }

    func testListDefaultsToFiftyRowsAndTakesALimitAndJSON() throws {
        let c = try cache(pdfs: 60)
        let all = try listing(["--json"], paths: c.paths)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(all.out.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 50, "the default limit is 50")
        XCTAssertEqual(try listing(["--json", "--limit", "3"], paths: c.paths).out.contains("\"key\""), true)
        let three = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try listing(["--json", "--limit", "3"], paths: c.paths).out.utf8)) as? [[String: Any]])
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(Set(rows.first?.keys.map { $0 } ?? []).isSuperset(of: ["key", "url", "size"]), true)
    }

    func testListSaysWhatItDidNotListAndWhenItFoundNothing() throws {
        let c = try cache()
        let resources = c.recordURL.deletingLastPathComponent()
        // One body with an unreadable record, one that is a byte range, one that disagrees with its body.
        let bad = WebKitCacheReaderTests.fullKey("BBBB0001")
        try WebKitCacheReaderTests.pdfBody.write(to: resources.appendingPathComponent("\(bad)-blob"))
        try Data(repeating: 0, count: 40).write(to: resources.appendingPathComponent(bad))
        let ranged = WebKitCacheReaderTests.fullKey("CCCC0002")
        try WebKitCacheReaderTests.pdfBody.write(to: resources.appendingPathComponent("\(ranged)-blob"))
        try WebKitCacheReaderTests.record(
            identifier: "https://e.org/r.pdf", range: "bytes=0-9", hash: WebKitCacheReaderTests.hashBytes(forKey: ranged))
            .write(to: resources.appendingPathComponent(ranged))
        let drift = WebKitCacheReaderTests.fullKey("DDDD0003")
        try WebKitCacheReaderTests.pdfBody.write(to: resources.appendingPathComponent("\(drift)-blob"))
        try WebKitCacheReaderTests.record(
            identifier: "https://e.org/d.pdf", hash: WebKitCacheReaderTests.hashBytes(forKey: drift), bodySize: 1)
            .write(to: resources.appendingPathComponent(drift))
        let text = try listing([], paths: c.paths)
        XCTAssertTrue(text.err.contains("1 cached PDF(s) have a record this command cannot read"), text.err)
        XCTAssertTrue(text.err.contains("hold only a byte range"), text.err)
        XCTAssertTrue(text.err.contains("does not describe the body"), text.err)
        XCTAssertFalse(text.out.isEmpty)
        XCTAssertFalse(text.err.contains("SECRET"))

        // Nothing at all: exit 0 with a note naming which cache it read.
        let empty = dir.appendingPathComponent("empty-cache/Version 17/Records", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let none = try listing([], paths: PDFCachePaths(cacheRoot: dir.appendingPathComponent("empty-cache"), temporaryRoot: dir))
        XCTAssertEqual(none.out, "")
        XCTAssertTrue(none.err.contains("default profile's network cache"), none.err)
    }

    func testListOfTheTemporaryFoldersCarriesItsOwnFields() throws {
        let tmp = dir.appendingPathComponent("tmp", isDirectory: true)
        let folderURL = tmp.appendingPathComponent("WebKitPDFs-abc", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try PDFCacheTests.makePDF(pages: 1).write(to: folderURL.appendingPathComponent("doc.pdf"))
        let text = try listing(["--source", "webkit-pdfs", "--json"], paths: PDFCachePaths(cacheRoot: dir.appendingPathComponent("none"), temporaryRoot: tmp))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.out.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(Set(rows[0].keys), ["file", "folder", "size", "modified"])
        XCTAssertEqual(rows[0]["file"] as? String, "doc.pdf")
    }
}
