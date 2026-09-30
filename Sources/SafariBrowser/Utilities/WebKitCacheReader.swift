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
/// type (`"Resource"`), identifier — where the identifier is the request URL.
/// A string is `uint32 length`, one `is8Bit` byte, then the characters, with no
/// alignment padding. Nothing after the identifier is parsed: the response
/// headers' encoding is more involved and whether a body is a PDF is decided
/// from the body's own first bytes.
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
    }

    enum RecordError: Error, Equatable {
        case truncated
        case unsupportedVersion(UInt32)
        case unexpectedType(String)
        case invalidStringFlag(UInt8)
        case nullString
        case stringTooLong(Int)
    }

    static func parseRecordKey(_ data: Data) throws -> RecordKey {
        var cursor = Cursor(bytes: Array(data))
        let version = try cursor.uint32()
        guard version == supportedVersion else { throw RecordError.unsupportedVersion(version) }
        let partition = try cursor.string()
        let type = try cursor.string()
        guard type == "Resource" else { throw RecordError.unexpectedType(type) }
        let identifier = try cursor.string()
        return RecordKey(version: version, partition: partition, type: type, identifier: identifier)
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

        mutating func string() throws -> String {
            let length = try uint32()
            if length == UInt32.max { throw RecordError.nullString }
            guard length <= UInt32(maximumStringLength) else { throw RecordError.stringTooLong(Int(length)) }
            let flag = try take(1).first!
            switch flag {
            case 1:
                return String(String.UnicodeScalarView(try take(Int(length)).map { Unicode.Scalar($0) }))
            case 0:
                let raw = Array(try take(Int(length) * 2))
                let units = stride(from: 0, to: raw.count, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
                return String(decoding: units, as: UTF16.self)
            default:
                throw RecordError.invalidStringFlag(flag)
            }
        }
    }

    // MARK: - Scan

    struct Scan {
        /// Newest first; ties broken by key.
        let pdfs: [WebKitCachedPDF]
        /// Bodies that start with `%PDF-` whose record could not be read.
        let unreadableKeys: [String]
        var unreadableRecords: Int { unreadableKeys.count }
    }

    /// Lists the PDFs in the cache. Looks at five bytes of each body and opens
    /// a record only when its body is a PDF.
    static func scan(
        cacheRoot: URL = defaultCacheRoot,
        reader: WebKitCacheFileReading = POSIXFilePrefixReader()
    ) throws -> Scan {
        let versionDirectory = try versionDirectory(in: cacheRoot)
        let records = versionDirectory.appendingPathComponent("Records", isDirectory: true)
        guard let partitions = try listDirectoryIfPresent(records) else {
            let seen = (try? listDirectory(versionDirectory)) ?? []
            throw SafariBrowserError.pdfCache(.recordLayoutUnsupported(
                detail: "\(supportedVersionFolder) has no Records folder (it holds: \(seen.isEmpty ? "nothing" : seen.joined(separator: ", ")))"))
        }

        var pdfs: [WebKitCachedPDF] = []
        var unreadable: [String] = []
        for partitionDirectory in partitions {
            let resources = records
                .appendingPathComponent(partitionDirectory, isDirectory: true)
                .appendingPathComponent("Resource", isDirectory: true)
            guard let names = try listDirectoryIfPresent(resources) else { continue }
            for name in names where name.hasSuffix("-blob") {
                let key = String(name.dropLast("-blob".count))
                let bodyURL = resources.appendingPathComponent(name)
                guard try startsWithPDFMagic(bodyURL, reader: reader) else { continue }
                let recordURL = resources.appendingPathComponent(key)
                guard let entry = try readEntry(
                    key: key, partitionDirectory: partitionDirectory,
                    recordURL: recordURL, bodyURL: bodyURL, reader: reader)
                else {
                    unreadable.append(key)
                    continue
                }
                pdfs.append(entry)
            }
        }
        if pdfs.isEmpty && !unreadable.isEmpty {
            throw SafariBrowserError.pdfCache(.recordLayoutUnsupported(
                detail: "\(unreadable.count) PDF body file(s) have no record that parses as version \(supportedVersion) with a 'Resource' key"))
        }
        pdfs.sort { lhs, rhs in
            switch (lhs.modified, rhs.modified) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.key < rhs.key
            }
        }
        return Scan(pdfs: pdfs, unreadableKeys: unreadable.sorted())
    }

    /// `nil` when the body vanished between listing and reading (the cache
    /// evicts while Safari runs). Every other failure — permission included —
    /// propagates with its cause.
    private static func startsWithPDFMagic(_ url: URL, reader: WebKitCacheFileReading) throws -> Bool {
        do {
            return try reader.readPrefix(at: url, maxBytes: pdfMagic.count) == pdfMagic
        } catch SafariBrowserError.safariDataFileNotFound {
            return false
        }
    }

    private static func readEntry(
        key: String, partitionDirectory: String, recordURL: URL, bodyURL: URL, reader: WebKitCacheFileReading
    ) throws -> WebKitCachedPDF? {
        let head: Data
        do {
            head = try reader.readPrefix(at: recordURL, maxBytes: recordHeadLimit)
        } catch SafariBrowserError.safariDataFileNotFound {
            return nil
        }
        guard let parsed = try? parseRecordKey(head) else { return nil }
        let bodyValues = try? bodyURL.resourceValues(forKeys: [.fileSizeKey])
        let recordValues = try? recordURL.resourceValues(forKeys: [.contentModificationDateKey])
        return WebKitCachedPDF(
            key: key, partitionDirectory: partitionDirectory, partition: parsed.partition,
            requestURL: parsed.identifier, bodyURL: bodyURL, recordURL: recordURL,
            size: Int64(bodyValues?.fileSize ?? 0), modified: recordValues?.contentModificationDate)
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
        throw SafariBrowserError.pdfCache(.noSupportedVersion(
            path: root.path, seen: names.filter { $0.hasPrefix("Version ") }.sorted()))
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
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        if errno != 0 { throw SafariDataStore.ioError(path: url.path, code: errno) }
        return names.sorted()
    }
}
