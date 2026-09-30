import CoreGraphics
import Foundation
import Darwin

/// Writes a cached PDF to the caller's path (#210).
///
/// The cache file is read-only and belongs to WebKit; the copy is the
/// caller's. Nothing is published until the copy is known to be a PDF that
/// CoreGraphics can read, so a truncated or unrelated file never appears
/// under the name the caller asked for.
///
/// Threat model: this runs as the user against the user's own folders. It
/// defends against mistakes and stale state — forgetting `--force`, naming
/// the cache file as the destination, a copy that fails halfway — not against
/// another process of the same user rewriting the destination folder while it
/// runs; such a process could read and write those files directly. What it
/// does anchor, because it is cheap and the PDF-export path does the same, is
/// the destination folder: it is opened once and every later step names
/// entries relative to that one descriptor, so swapping the folder or one of
/// its ancestors for a symlink after the start cannot move the write, the
/// verification, the publication or the cleanup somewhere else.
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
    /// verified through the descriptor it was written with, then renamed into
    /// place. On any failure no temporary file and no destination this call
    /// created remains.
    ///
    /// `beforePublish` runs after verification and before the last checks and
    /// the rename. It exists so tests can create the races those checks are
    /// for; production callers leave it alone.
    static func copyVerified(
        from source: URL, to destination: String, force: Bool, beforePublish: (String) -> Void = { _ in }
    ) throws -> Result {
        let destinationURL = URL(fileURLWithPath: destination).standardizedFileURL
        let parentURL = destinationURL.deletingLastPathComponent()
        let name = destinationURL.lastPathComponent

        // The one place the destination folder is resolved by path.
        let parentFD = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                throw SafariBrowserError.pdfCache(.destinationDirectoryMissing(path: parentURL.path))
            }
            throw writeFailure(destinationURL.path, code)
        }
        defer { close(parentFD) }

        var existing = stat()
        if fstatat(parentFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            if existing.st_mode & S_IFMT == S_IFDIR {
                throw SafariBrowserError.pdfCache(.destinationWriteFailed(path: destinationURL.path, detail: "it is a folder"))
            }
            if !force { throw SafariBrowserError.pdfCache(.destinationExists(path: destinationURL.path)) }
        }

        let sourceFD = try SafariDataStore.openSource(source)
        defer { close(sourceFD) }
        try refuseIfSameFile(sourceFD: sourceFD, parentFD: parentFD, name: name, destination: destinationURL.path)

        // Fixed length: a name derived from the destination's could exceed NAME_MAX.
        let temporaryName = ".pdf-cache-\(UUID().uuidString).tmp"
        let temporaryFD = openat(parentFD, temporaryName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temporaryFD >= 0 else { throw writeFailure(destinationURL.path, errno) }
        var temporaryOpen = true
        var published = false
        defer {
            if temporaryOpen { close(temporaryFD) }
            if !published { unlinkat(parentFD, temporaryName, 0) }
        }

        let size = try copy(from: sourceFD, to: temporaryFD, sourceName: source.lastPathComponent, destination: destinationURL.path)
        guard fsync(temporaryFD) == 0 else { throw writeFailure(destinationURL.path, errno) }
        let pages = try verifiedPageCount(fd: temporaryFD, size: size)
        beforePublish(temporaryName)

        // The name must still be the file that was written and verified.
        var written = stat(), named = stat()
        guard fstat(temporaryFD, &written) == 0,
            fstatat(parentFD, temporaryName, &named, AT_SYMLINK_NOFOLLOW) == 0,
            written.st_dev == named.st_dev, written.st_ino == named.st_ino
        else {
            throw SafariBrowserError.pdfCache(.destinationWriteFailed(
                path: destinationURL.path, detail: "the staged copy was replaced before it could be published"))
        }

        // Darwin releases the descriptor even when close() reports an error, so it
        // is never closed again or retried (the number may already belong to
        // someone else). EINTR is not a failure here: fsync has made the data
        // durable and nothing was left unwritten.
        temporaryOpen = false
        if close(temporaryFD) != 0, errno != EINTR { throw writeFailure(destinationURL.path, errno) }

        let renamed = force
            ? renameat(parentFD, temporaryName, parentFD, name)
            : renameatx_np(parentFD, temporaryName, parentFD, name, UInt32(RENAME_EXCL))
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
    /// A destination that does not exist (or is a dangling symlink) cannot be the
    /// source; any other failure to look is a refusal, not a pass.
    private static func refuseIfSameFile(sourceFD: Int32, parentFD: Int32, name: String, destination: String) throws {
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0 else { throw SafariDataStore.ioError(path: destination, code: errno) }
        var destinationInfo = stat()
        if fstatat(parentFD, name, &destinationInfo, 0) != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return }
            throw writeFailure(destination, code)
        }
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
    ///
    /// CoreGraphics reads the descriptor the copy was written with, by
    /// position, so it verifies that inode and not whatever a path names later.
    private static func verifiedPageCount(fd: Int32, size: Int64) throws -> Int {
        func fail(_ detail: String) -> SafariBrowserError { .pdfCache(.unreadablePDF(detail: detail)) }
        guard size <= Int64(Int.max) else { throw fail("it is too large") }
        let reader = PDFCacheDescriptorReader(fd: fd)
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info else { return 0 }
                let reader = Unmanaged<PDFCacheDescriptorReader>.fromOpaque(info).takeUnretainedValue()
                var received = 0
                while received < count {
                    let result = pread(reader.fd, buffer.advanced(by: received), count - received, position + off_t(received))
                    if result < 0, errno == EINTR { continue }
                    if result <= 0 { break }
                    received += result
                }
                return received
            },
            releaseInfo: { info in
                if let info { Unmanaged<PDFCacheDescriptorReader>.fromOpaque(info).release() }
            }
        )
        let info = Unmanaged.passRetained(reader).toOpaque()
        guard let provider = CGDataProvider(directInfo: info, size: off_t(size), callbacks: &callbacks) else {
            Unmanaged<PDFCacheDescriptorReader>.fromOpaque(info).release()
            throw fail("CoreGraphics could not read it")
        }
        guard let document = CGPDFDocument(provider) else { throw fail("CoreGraphics could not open it") }
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

/// Lets CoreGraphics read the staged copy through the descriptor that wrote it.
private final class PDFCacheDescriptorReader {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
}
