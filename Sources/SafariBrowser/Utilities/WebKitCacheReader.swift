import Foundation
import Darwin

/// One PDF that Safari's WebKit network cache holds (#210).
struct WebKitCachedPDF: Equatable {
    /// The record's file name (40 hex characters as WebKit writes them).
    let key: String
    /// The hashed folder under `Records/` this record lives in.
    let partitionDirectory: String
    /// The partition string stored in the record; empty when the cache is not partitioned.
    let partition: String
    /// The complete request URL, query included. Display code must redact it
    /// (`PDFCacheURL`); matching code needs the complete string.
    let requestURL: String
    let bodyURL: URL
    let recordURL: URL
    let size: Int64
    /// The record file's modification time.
    let modified: Date?
}

/// Reads a bounded prefix of a file. Injectable so tests can prove how little
/// of each cached body the scan looks at.
protocol WebKitCacheFileReading {
    func readPrefix(at url: URL, maxBytes: Int) throws -> Data
}

struct POSIXFilePrefixReader: WebKitCacheFileReading {
    func readPrefix(at url: URL, maxBytes: Int) throws -> Data {
        let fd = try SafariDataStore.openSource(url)
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        var total = 0
        while total < maxBytes {
            let count = buffer.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress! + total, maxBytes - total, off_t(total))
            }
            if count == 0 { break }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw SafariDataStore.ioError(path: url.path, code: code)
            }
            total += count
        }
        return Data(buffer.prefix(total))
    }
}

/// Reads the WebKit network cache that Safari keeps under
/// `~/Library/Containers/com.apple.Safari/…/WebKitCache/` (#210).
///
/// Layout, established on 2026-09-30 by reading the structure of a real cache
/// (no request was made and no content beyond a few leading bytes was read):
///
///     WebKitCache/Version 17/Records/<partition hash>/Resource/<key>        record
///                                                            /<key>-blob    response body
///
/// A record begins `uint32 version (17)`, then three strings — partition,
/// type (`"Resource"`), identifier — where the identifier is the request URL,
/// then the range (`0xFFFFFFFF` for none, otherwise a string) and a 20-byte
/// SHA-1 that equals the record's file name. A string is `uint32 length`, one
/// `is8Bit` byte, then the characters, with no alignment padding. All 9221
/// records in the cache it was observed on parsed this way, 649 with a 16-bit
/// identifier and 658 with a non-empty partition, every one with no range and
/// a hash equal to its file name.
///
/// Two fields after the key are also read, and only these (the response
/// headers' encoding between them is more involved and is skipped): at 56
/// bytes after the key hash the 20-byte SHA-1 of the body (`bodyHash`, the name
/// of the body's link under `Blobs/`), at 76 bytes after it the body's length
/// as `uint64`. Observed on 2026-10-01 on the default store: of 4603 records
/// that have a `-blob` file, 4602 carry a `bodySize` equal to that file's size
/// and a `bodyHash` that names a `Blobs/` entry which is the same inode; one
/// disagreed. WebKit writes the record and the body separately and says so in
/// its own source ("Blob and record are read separately, so we need to check
/// if blob hash matches record hash"), so a record that does not describe the
/// body beside it is a copy of a resource that is half replaced. It is never
/// listed or copied. Whether a body is a PDF is decided from the body's own
/// first bytes.
///
/// The hash equalling the file name is what makes a wrong parse visible: if
/// WebKit reshaped the key, the 20 bytes read here would no longer be the
/// name, and the record is rejected instead of trusted.
///
/// A record whose key carries a range holds a *part* of a resource; its body
/// may start with `%PDF-` and still not be a document, so it is never listed.
///
/// This is WebKit's private format with no stability promise, so every
/// departure from what was observed is an error that says what was seen —
/// never an empty result.
enum WebKitCacheReader {
    static let supportedVersion: UInt32 = 17
    static var supportedVersionFolder: String { "Version \(supportedVersion)" }
    static let maximumStringLength = 65_536
    static let pdfMagic = Data("%PDF-".utf8)
    /// Enough for a version and three strings at the length cap, UTF-16 included.
    static let recordHeadLimit = 512 * 1024

    static var defaultCacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari/WebKitCache",
            isDirectory: true)
    }

    // MARK: - Record key

    struct RecordKey: Equatable {
        let version: UInt32
        let partition: String
        let type: String
        let identifier: String
        /// `nil` when the key names the whole resource.
        let range: String?
        /// 20 bytes; equals the record's file name in hex.
        let hash: Data
    }

    enum RecordError: Error, Equatable {
        case truncated
        case unsupportedVersion(UInt32)
        case unexpectedType(String)
        case invalidStringFlag(UInt8)
        case nullString
        case stringTooLong(Int)
        /// A 16-bit string with an unpaired surrogate. Decoding it would silently
        /// replace it with U+FFFD and turn a broken record into a valid-looking URL.
        case malformedText
    }

    static let hashLength = 20

    static func parseRecordKey(_ data: Data) throws -> RecordKey {
        var cursor = Cursor(bytes: Array(data))
        let version = try cursor.uint32()
        guard version == supportedVersion else { throw RecordError.unsupportedVersion(version) }
        let partition = try cursor.string()
        let type = try cursor.string()
        guard type == "Resource" else { throw RecordError.unexpectedType(type) }
        let identifier = try cursor.string()
        let range = try cursor.optionalString()
        let hash = Data(try cursor.take(hashLength))
        return RecordKey(
            version: version, partition: partition, type: type, identifier: identifier, range: range, hash: hash)
    }

    /// What the record says about its body, read after the key (see the layout above).
    struct RecordBody: Equatable {
        let bodyHash: Data
        let bodySize: UInt64
    }

    /// Where the fields sit relative to the end of the key hash.
    static let bodyHashOffsetAfterKey = 56

    /// Throws `RecordError.truncated` when the record ends before the fields do: a record
    /// that does not carry them is not the layout that was observed.
    static func parseRecordBody(_ data: Data) throws -> RecordBody {
        var cursor = Cursor(bytes: Array(data))
        _ = try cursor.uint32()
        _ = try cursor.string()
        _ = try cursor.string()
        _ = try cursor.string()
        _ = try cursor.optionalString()
        _ = try cursor.take(hashLength)
        _ = try cursor.take(bodyHashOffsetAfterKey)
        let bodyHash = Data(try cursor.take(hashLength))
        return RecordBody(bodyHash: bodyHash, bodySize: try cursor.uint64())
    }

    private struct Cursor {
        let bytes: [UInt8]
        var offset = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, bytes.count - offset >= count else { throw RecordError.truncated }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }

        mutating func uint32() throws -> UInt32 {
            try take(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }

        mutating func uint64() throws -> UInt64 {
            try take(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        }

        mutating func string() throws -> String {
            guard let value = try optionalString(nullAllowed: false) else { throw RecordError.nullString }
            return value
        }

        /// A string whose length field may be `0xFFFFFFFF`, WebKit's null string.
        mutating func optionalString(nullAllowed: Bool = true) throws -> String? {
            let length = try uint32()
            if length == UInt32.max {
                if nullAllowed { return nil }
                throw RecordError.nullString
            }
            guard length <= UInt32(maximumStringLength) else { throw RecordError.stringTooLong(Int(length)) }
            let flag = try take(1).first!
            switch flag {
            case 1:
                return String(String.UnicodeScalarView(try take(Int(length)).map { Unicode.Scalar($0) }))
            case 0:
                let raw = Array(try take(Int(length) * 2))
                let units = stride(from: 0, to: raw.count, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
                guard isWellFormedUTF16(units) else { throw RecordError.malformedText }
                return String(decoding: units, as: UTF16.self)
            default:
                throw RecordError.invalidStringFlag(flag)
            }
        }
    }

    static func isWellFormedUTF16(_ units: [UInt16]) -> Bool {
        var index = 0
        while index < units.count {
            switch units[index] {
            case 0xD800...0xDBFF:
                guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else { return false }
                index += 2
            case 0xDC00...0xDFFF:
                return false
            default:
                index += 1
            }
        }
        return true
    }

    // MARK: - Scan

    struct Scan {
        /// Newest first; ties broken by key.
        let pdfs: [WebKitCachedPDF]
        /// Bodies that start with `%PDF-` whose record could not be read.
        let unreadableKeys: [String]
        /// Bodies that start with `%PDF-` but belong to a range request: part of a resource, not a document.
        let partialKeys: [String]
        /// PDF bodies whose file name is not a cache key at all. Counted, never named: a disk-derived
        /// name outside the key grammar is not safe to print.
        let malformedNames: Int
        /// Bodies that start with `%PDF-` whose record parses but does not describe the body beside it
        /// (a different length): WebKit was writing or replacing one of the two. Not a layout problem,
        /// and never listed or copied.
        let outOfSyncKeys: [String]
        /// Folders under `Records/` whose names are not what the layout has (a hash). Skipped and
        /// counted, never named.
        let skippedFolders: Int
        var unreadableRecords: Int { unreadableKeys.count + malformedNames }

        init(
            pdfs: [WebKitCachedPDF], unreadableKeys: [String], partialKeys: [String] = [], malformedNames: Int = 0,
            outOfSyncKeys: [String] = [], skippedFolders: Int = 0
        ) {
            self.pdfs = pdfs
            self.unreadableKeys = unreadableKeys
            self.partialKeys = partialKeys
            self.malformedNames = malformedNames
            self.outOfSyncKeys = outOfSyncKeys
            self.skippedFolders = skippedFolders
        }
    }

    /// Lists the PDFs in the cache. Looks at five bytes of each body and opens
    /// a record only when its body is a PDF.
    static func scan(
        cacheRoot: URL = defaultCacheRoot,
        reader: WebKitCacheFileReading = POSIXFilePrefixReader()
    ) throws -> Scan {
        let versionDirectory = try versionDirectory(in: cacheRoot)
        let records = versionDirectory.appendingPathComponent("Records", isDirectory: true)
        guard let allPartitions = try listDirectoryIfPresent(records) else {
            // A failure to list keeps its cause; it is not a folder that "holds nothing".
            let seen = try listDirectory(versionDirectory)
            // A store WebKit has never written to holds `Blobs` (empty) and `salt` and no `Records`
            // (observed on 2026-10-01: three of the machine's 21 stores). That is an empty cache. Any
            // other shape is not what was observed and is reported as such.
            if !seen.isEmpty, Set(seen).isSubset(of: ["Blobs", "salt"]),
                try (listDirectoryIfPresent(versionDirectory.appendingPathComponent("Blobs", isDirectory: true)) ?? []).isEmpty
            {
                return Scan(pdfs: [], unreadableKeys: [])
            }
            throw SafariBrowserError.pdfCache(.recordLayoutUnsupported(
                detail: "\(supportedVersionFolder) has no Records folder (it holds: \(describe(names: seen)))"))
        }
        // The partition folders are hashes (40 hexadecimal characters as observed). A folder named
        // otherwise is skipped and counted, not followed: its name would reach a path, and an I/O
        // error carries the path.
        let partitions = allPartitions.filter(isHashFolderName)
        let skippedFolders = allPartitions.count - partitions.count

        var pdfs: [WebKitCachedPDF] = []
        var unreadable: [String] = []
        var partial: [String] = []
        var outOfSync: [String] = []
        var malformed = 0
        for partitionDirectory in partitions {
            let resources = records
                .appendingPathComponent(partitionDirectory, isDirectory: true)
                .appendingPathComponent("Resource", isDirectory: true)
            guard let names = try listDirectoryIfPresent(resources) else { continue }
            // A folder that can be listed and not searched fails every lookup inside it, and the
            // lookups of a name outside the key grammar are skipped on purpose: ask the folder
            // itself, once, so that no entry's name decides whether the permission error is seen.
            try requireSearchable(resources)
            for name in names where name.hasSuffix("-blob") {
                let key = String(name.dropLast("-blob".count))
                let bodyURL = resources.appendingPathComponent(name)
                // The name is judged before anything touches the file: an I/O error carries the
                // path, and a name outside the key grammar must never reach a message. Such an
                // entry can only be counted, and only if it is a PDF body; any failure looking
                // at it is skipped (deliberate `try?`) — it cannot be a cache entry, and a real
                // access problem in this folder is reported by the entries that do have valid names.
                guard isCacheKey(key) else {
                    if (try? regularFileInfo(bodyURL)) != nil, (try? startsWithPDFMagic(bodyURL, reader: reader)) == true {
                        malformed += 1
                    }
                    continue
                }
                guard let bodyInfo = try regularFileInfo(bodyURL),
                    try startsWithPDFMagic(bodyURL, reader: reader)
                else { continue }
                let recordURL = resources.appendingPathComponent(key)
                switch try readEntry(
                    key: key, partitionDirectory: partitionDirectory,
                    recordURL: recordURL, bodyURL: bodyURL, bodySize: bodyInfo.size, reader: reader)
                {
                case .pdf(let entry): pdfs.append(entry)
                case .partial: partial.append(key)
                case .unreadable: unreadable.append(key)
                case .outOfSync: outOfSync.append(key)
                }
            }
        }
        if pdfs.isEmpty && partial.isEmpty && (!unreadable.isEmpty || malformed > 0) {
            throw SafariBrowserError.pdfCache(.recordLayoutUnsupported(
                detail: "\(unreadable.count + malformed) PDF body file(s) have no record that parses as version \(supportedVersion) with a 'Resource' key and a hash equal to its file name"))
        }
        pdfs.sort { lhs, rhs in
            switch (lhs.modified, rhs.modified) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.key < rhs.key
            }
        }
        return Scan(
            pdfs: pdfs, unreadableKeys: unreadable.sorted(), partialKeys: partial.sorted(), malformedNames: malformed,
            outOfSyncKeys: outOfSync.sorted(), skippedFolders: skippedFolders)
    }

    /// `ENOENT` for a name that cannot exist means the folder can be searched; `EACCES` means it
    /// cannot, and that is a permission error with its path, never an empty folder.
    static func requireSearchable(_ folder: URL) throws {
        var info = stat()
        if lstat(folder.appendingPathComponent(".pdf-cache-probe").path, &info) == 0 { return }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return }
        throw SafariDataStore.ioError(path: folder.path, code: code)
    }

    /// A folder name the layout produces: hexadecimal, as the partition folders are.
    static func isHashFolderName(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count) && name.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// Names that are safe to show: a folder name of the layout (`Version 17`, `Records`, `salt`).
    /// Anything else on disk is counted, not printed — a name can be text a person typed, and a
    /// query-like secret in it is not removed by escaping control characters.
    static func isShowableName(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count)
            && name.unicodeScalars.allSatisfy { $0.isASCII && (("0"..."9").contains($0) || ("a"..."z").contains($0) || ("A"..."Z").contains($0) || " ._-".unicodeScalars.contains($0)) }
    }

    static func describe(names: [String]) -> String {
        if names.isEmpty { return "nothing" }
        let shown = names.filter(isShowableName)
        let other = names.count - shown.count
        var parts = shown
        if other > 0 { parts.append("\(other) other \(other == 1 ? "entry" : "entries") with unexpected names") }
        return parts.joined(separator: ", ")
    }

    /// A body that vanished between listing and reading (the cache evicts while
    /// Safari runs) is not a PDF body. Every other failure — permission included —
    /// propagates with its cause.
    private static func startsWithPDFMagic(_ url: URL, reader: WebKitCacheFileReading) throws -> Bool {
        do {
            return try reader.readPrefix(at: url, maxBytes: pdfMagic.count) == pdfMagic
        } catch SafariBrowserError.safariDataFileNotFound {
            return false
        }
    }

    private enum EntryOutcome {
        case pdf(WebKitCachedPDF)
        case partial
        case unreadable
        /// The record parses and does not describe the body beside it.
        case outOfSync
    }

    private static func readEntry(
        key: String, partitionDirectory: String, recordURL: URL, bodyURL: URL, bodySize: Int64, reader: WebKitCacheFileReading
    ) throws -> EntryOutcome {
        // Same rule as the body: a folder or symlink is not a record.
        guard let recordInfo = try regularFileInfo(recordURL) else { return .unreadable }
        let head: Data
        do {
            head = try reader.readPrefix(at: recordURL, maxBytes: recordHeadLimit)
        } catch SafariBrowserError.safariDataFileNotFound {
            return .unreadable
        }
        guard let parsed = try? parseRecordKey(head),
            parsed.hash.map({ String(format: "%02X", $0) }).joined() == key.uppercased()
        else { return .unreadable }
        guard parsed.range == nil else { return .partial }
        // The record must carry the fields that describe its body; one that ends before them is
        // not the layout that was observed.
        guard let described = try? parseRecordBody(head) else { return .unreadable }
        guard described.bodySize == UInt64(bodySize) else { return .outOfSync }
        return .pdf(WebKitCachedPDF(
            key: key, partitionDirectory: partitionDirectory, partition: parsed.partition,
            requestURL: parsed.identifier, bodyURL: bodyURL, recordURL: recordURL,
            size: bodySize, modified: recordInfo.modified))
    }

    /// A record's file name is the SHA-1 of its key: exactly 40 ASCII hexadecimal
    /// characters. Checked before the name is case-folded, printed or compared,
    /// so a name that only looks like one (`uppercased()` turns one ligature into
    /// two letters) or carries text a person would not expect is never trusted.
    static func isCacheKey(_ name: String) -> Bool {
        name.utf8.count == 40 && name.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    struct FileInfo {
        let size: Int64
        let modified: Date
        /// `nil` when the file system reports no birth time.
        let created: Date?
    }

    /// `lstat`, so a symlink is not a regular file: `nil` for anything that is not
    /// one, and for an entry that is gone (the cache evicts while Safari runs).
    /// Any other failure — a folder that can be listed and not searched, say —
    /// keeps its cause: it must not turn into "no PDFs here". Size and times come
    /// from the same call, so nothing is invented when a later lookup would fail.
    static func regularFileInfo(_ url: URL) throws -> FileInfo? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw SafariDataStore.ioError(path: url.path, code: code)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return nil }
        func date(_ spec: timespec) -> Date { Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1e9) }
        return FileInfo(
            size: Int64(info.st_size), modified: date(info.st_mtimespec),
            created: info.st_birthtimespec.tv_sec > 0 ? date(info.st_birthtimespec) : nil)
    }

    // MARK: - Folders

    static func versionDirectory(in root: URL) throws -> URL {
        let names: [String]
        do {
            names = try listDirectory(root)
        } catch SafariBrowserError.safariDataFileNotFound {
            throw SafariBrowserError.pdfCache(.cacheFolderMissing(path: root.path))
        }
        if names.contains(supportedVersionFolder) {
            return root.appendingPathComponent(supportedVersionFolder, isDirectory: true)
        }
        let versions = names.filter { $0.hasPrefix("Version ") }.sorted()
        let shown = versions.filter(isShowableName)
        let other = versions.count - shown.count
        throw SafariBrowserError.pdfCache(.noSupportedVersion(
            path: root.path,
            seen: shown + (other > 0 ? ["\(other) other \(other == 1 ? "folder" : "folders") with unexpected names"] : [])))
    }

    /// Entry names of a folder with the failing call's errno preserved, so an
    /// unreadable folder is a permission error and never an empty one.
    static func listDirectory(_ url: URL) throws -> [String] {
        guard let names = try listDirectoryIfPresent(url, absentIsError: true) else { return [] }
        return names
    }

    /// Like `listDirectory`, but a folder that is gone (or is not a folder) is
    /// `nil`: the cache evicts and reorganises while Safari runs.
    static func listDirectoryIfPresent(_ url: URL, absentIsError: Bool = false) throws -> [String]? {
        guard let directory = opendir(url.path) else {
            let code = errno
            if !absentIsError && (code == ENOENT || code == ENOTDIR) { return nil }
            throw SafariDataStore.ioError(path: url.path, code: code, allowMissing: true)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            // readdir returns nil at the end and on error, and only errno tells them
            // apart: clear it right before the call and read it right after, with
            // nothing in between that could change it.
            errno = 0
            guard let entry = readdir(directory) else { break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        let code = errno
        if code != 0 { throw SafariDataStore.ioError(path: url.path, code: code) }
        return names.sorted()
    }
}
