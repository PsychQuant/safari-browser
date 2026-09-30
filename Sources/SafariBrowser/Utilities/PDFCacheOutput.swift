import CoreGraphics
import Foundation
import Darwin

/// Writes a cached PDF to the caller's path (#210).
///
/// The cache file is read-only and belongs to WebKit; the copy is the
/// caller's. Nothing is published until the copy is known to be a PDF that
/// CoreGraphics can read, so a truncated or unrelated file never appears
/// under the name the caller asked for.
enum PDFCacheOutput {
    struct Result: Equatable {
        let path: String
        let size: Int64
        let pages: Int
    }

    private static let chunkSize = 64 * 1024

    /// The source is opened read-only and never modified. The copy is created
    /// exclusively in the destination's own folder (mode 0600, so a cached
    /// private document does not become world-readable by a permissive umask),
    /// verified, then renamed into place. On any failure no temporary file and
    /// no destination this call created remains.
    static func copyVerified(from source: URL, to destination: String, force: Bool) throws -> Result {
        let destinationURL = URL(fileURLWithPath: destination).standardizedFileURL
        let parent = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SafariBrowserError.pdfCache(.destinationDirectoryMissing(path: parent.path))
        }
        var existing = stat()
        if lstat(destinationURL.path, &existing) == 0 {
            if existing.st_mode & S_IFMT == S_IFDIR {
                throw SafariBrowserError.pdfCache(.destinationWriteFailed(path: destinationURL.path, detail: "it is a folder"))
            }
            if !force { throw SafariBrowserError.pdfCache(.destinationExists(path: destinationURL.path)) }
        }

        let sourceFD = try SafariDataStore.openSource(source)
        defer { close(sourceFD) }
        try refuseIfSameFile(sourceFD: sourceFD, destination: destinationURL.path)

        // Fixed length: a name derived from the destination's could exceed NAME_MAX.
        let temporary = parent.appendingPathComponent(".pdf-cache-\(UUID().uuidString).tmp").path
        let temporaryFD = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temporaryFD >= 0 else { throw writeFailure(destinationURL.path, errno) }
        var temporaryOpen = true
        var published = false
        defer {
            if temporaryOpen { close(temporaryFD) }
            if !published { unlink(temporary) }
        }

        let size = try copy(from: sourceFD, to: temporaryFD, sourceName: source.lastPathComponent, destination: destinationURL.path)
        guard fsync(temporaryFD) == 0 else { throw writeFailure(destinationURL.path, errno) }
        // Darwin releases the descriptor even when close() reports an error, so it
        // is never closed again or retried (the number may already belong to
        // someone else). EINTR is not a failure here: fsync has made the data
        // durable and nothing was left unwritten.
        temporaryOpen = false
        if close(temporaryFD) != 0, errno != EINTR { throw writeFailure(destinationURL.path, errno) }

        let pages = try verifiedPageCount(at: temporary)

        let renamed = force
            ? rename(temporary, destinationURL.path)
            : renamex_np(temporary, destinationURL.path, UInt32(RENAME_EXCL))
        guard renamed == 0 else {
            if errno == EEXIST { throw SafariBrowserError.pdfCache(.destinationExists(path: destinationURL.path)) }
            throw writeFailure(destinationURL.path, errno)
        }
        published = true
        return Result(path: destinationURL.path, size: size, pages: pages)
    }

    /// The source belongs to Safari and is never modified. Publishing over it —
    /// `--force` with the cache file itself, a symlink or a hard link to it as
    /// the destination — would replace its directory entry and permissions even
    /// though the bytes are the same. Compared by device and inode, not by path.
    private static func refuseIfSameFile(sourceFD: Int32, destination: String) throws {
        var sourceInfo = stat()
        var destinationInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0, stat(destination, &destinationInfo) == 0 else { return }
        if sourceInfo.st_dev == destinationInfo.st_dev, sourceInfo.st_ino == destinationInfo.st_ino {
            throw SafariBrowserError.pdfCache(.destinationWriteFailed(
                path: destination, detail: "it is the cached file this copy is read from"))
        }
    }

    /// Streams the source into the temporary file, refusing as soon as the
    /// leading bytes are not `%PDF-` so a large non-PDF body is not copied.
    private static func copy(from sourceFD: Int32, to temporaryFD: Int32, sourceName: String, destination: String) throws -> Int64 {
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var total: Int64 = 0
        var head = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { read(sourceFD, $0.baseAddress, chunkSize) }
            if count == 0 { break }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw SafariDataStore.ioError(path: sourceName, code: code)
            }
            if head.count < WebKitCacheReader.pdfMagic.count {
                head.append(contentsOf: buffer.prefix(min(count, WebKitCacheReader.pdfMagic.count - head.count)))
                if head.count == WebKitCacheReader.pdfMagic.count, head != WebKitCacheReader.pdfMagic {
                    throw SafariBrowserError.pdfCache(.notAPDF(name: sourceName))
                }
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { write(temporaryFD, $0.baseAddress! + written, count - written) }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw writeFailure(destination, errno)
                }
                written += result
            }
            total += Int64(count)
        }
        guard head == WebKitCacheReader.pdfMagic else { throw SafariBrowserError.pdfCache(.notAPDF(name: sourceName)) }
        return total
    }

    /// Every page's entry in the page tree must be readable, the same standard
    /// the PDF-export path applies: a PDF cut short loses its page tree and
    /// fails here. CoreGraphics parses lazily, so this does not decode content
    /// streams or images — a document whose page tree is intact but whose
    /// content is damaged passes.
    private static func verifiedPageCount(at path: String) throws -> Int {
        func fail(_ detail: String) -> SafariBrowserError { .pdfCache(.unreadablePDF(detail: detail)) }
        guard let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL) else {
            throw fail("CoreGraphics could not open it")
        }
        guard document.isUnlocked else { throw fail("it is password-protected") }
        guard document.numberOfPages > 0 else { throw fail("it has no pages") }
        for number in 1...document.numberOfPages where document.page(at: number) == nil {
            throw fail("page \(number) cannot be read")
        }
        return document.numberOfPages
    }

    private static func writeFailure(_ path: String, _ code: Int32) -> SafariBrowserError {
        .pdfCache(.destinationWriteFailed(path: path, detail: "\(String(cString: strerror(code))) (errno \(code))"))
    }
}
