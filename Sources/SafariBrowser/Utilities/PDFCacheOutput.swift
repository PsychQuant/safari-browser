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
    /// exclusively in the destination's own folder, owner-only (mode 0600 and no
    /// ACL entries, so neither a permissive umask nor an ACL the folder hands down
    /// makes a cached private document readable or writable by anyone else),
    /// verified through the descriptor it was written with, then renamed into
    /// place. On any failure no temporary file and no destination this call
    /// created remains.
    ///
    /// The destination text is split at its last `/` as plain text and is NOT
    /// standardised, expanded or resolved by Foundation: `..`, a symlink and a
    /// leading `~` mean what the kernel (and `cp`) make of them, because the folder
    /// is opened with the text as given. The success line names the folder as the
    /// descriptor reports it, so it says where the file is.
    ///
    /// `protectedFolders` are Safari's own folders; a destination inside one is
    /// refused, with or without `--force`. `afterParentOpened` and `beforePublish`
    /// exist so tests can create the races the anchoring and the last checks are
    /// for (swap the folder, swap the staged file); production callers leave them
    /// alone.
    static func copyVerified(
        from source: URL, to destination: String, force: Bool, protectedFolders: [URL] = [],
        afterParentOpened: () -> Void = {}, beforePublish: (String) -> Void = { _ in }
    ) throws -> Result {
        let split = try splitDestination(destination)
        let typedPath = destination

        // The one place the destination folder is resolved by path.
        let parentFD = open(split.parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                throw SafariBrowserError.pdfCache(.destinationDirectoryMissing(path: split.parent))
            }
            throw writeFailure(typedPath, code)
        }
        defer { close(parentFD) }
        afterParentOpened()

        let parentPath = canonicalPath(of: parentFD) ?? split.parent
        let name = split.name
        // A constant, so that `writeFailure(destinationPath, errno)` evaluates nothing but
        // a local between the failing call and the read of errno.
        let destinationPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        try refuseInside(protectedFolders, parentPath: parentPath, destination: destinationPath)

        var existing = stat()
        if fstatat(parentFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            if existing.st_mode & S_IFMT == S_IFDIR {
                throw SafariBrowserError.pdfCache(.destinationWriteFailed(path: destinationPath, detail: "it is a folder"))
            }
            if !force { throw SafariBrowserError.pdfCache(.destinationExists(path: destinationPath)) }
        }

        let sourceFD = try SafariDataStore.openSource(source)
        defer { close(sourceFD) }
        try refuseIfSameFile(sourceFD: sourceFD, parentFD: parentFD, name: name, destination: destinationPath)

        // Fixed length: a name derived from the destination's could exceed NAME_MAX.
        let temporaryName = ".pdf-cache-\(UUID().uuidString).tmp"
        let temporaryFD = openat(parentFD, temporaryName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temporaryFD >= 0 else { throw writeFailure(destinationPath, errno) }
        var temporaryOpen = true
        var published = false
        do {
            try restrictToOwner(temporaryFD, destination: destinationPath)
            let size = try copy(from: sourceFD, to: temporaryFD, sourceName: source.lastPathComponent, destination: destinationPath)
            guard fsync(temporaryFD) == 0 else { throw writeFailure(destinationPath, errno) }
            let pages = try verifiedPageCount(fd: temporaryFD, size: size)
            beforePublish(temporaryName)

            // The name must still be the file that was written and verified. This is the
            // identity of the file, not a check of its bytes: what keeps anyone else from
            // writing to it in between is that it is owner-only (above) and that this runs
            // as the user who owns it.
            var written = stat(), named = stat()
            guard fstat(temporaryFD, &written) == 0,
                fstatat(parentFD, temporaryName, &named, AT_SYMLINK_NOFOLLOW) == 0,
                written.st_dev == named.st_dev, written.st_ino == named.st_ino
            else {
                throw SafariBrowserError.pdfCache(.destinationWriteFailed(
                    path: destinationPath, detail: "the staged copy was replaced before it could be published"))
            }
            // A destination that became the cached file between the first look and now (a link
            // made in the meantime) is still refused, with or without --force; the window that
            // remains is the one between this call and the rename.
            try refuseIfSameFile(sourceFD: sourceFD, parentFD: parentFD, name: name, destination: destinationPath)

            // Darwin releases the descriptor even when close() reports an error, so it
            // is never closed again or retried (the number may already belong to
            // someone else). EINTR is not a failure here: fsync has made the data
            // durable and nothing was left unwritten.
            temporaryOpen = false
            if close(temporaryFD) != 0, errno != EINTR { throw writeFailure(destinationPath, errno) }

            let renamed = force
                ? renameat(parentFD, temporaryName, parentFD, name)
                : renameatx_np(parentFD, temporaryName, parentFD, name, UInt32(RENAME_EXCL))
            guard renamed == 0 else {
                let code = errno
                if code == EEXIST { throw SafariBrowserError.pdfCache(.destinationExists(path: destinationPath)) }
                if !force, code == ENOTSUP || code == EINVAL {
                    throw writeFailure(
                        destinationPath, code,
                        prefix: "This file system cannot refuse to replace an existing file in one step, so the copy would not be safe without --force.")
                }
                throw writeFailure(destinationPath, code)
            }
            published = true
            return Result(path: destinationPath, size: size, pages: pages)
        } catch {
            if temporaryOpen { close(temporaryFD) }
            // A folder can allow creating a file and deny removing it (an ACL with
            // delete_child denied). The original error must not claim that nothing
            // was left behind when something was.
            if !published, unlinkat(parentFD, temporaryName, 0) != 0, errno != ENOENT {
                let code = errno
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                throw writeFailure(
                    destinationPath, code, prefix: "\(reason) The staged copy \(temporaryName) could not be removed and was left in \(parentPath):")
            }
            throw error
        }
    }

    /// The destination as text: everything before the last `/` is the folder (`.` when there is no
    /// `/`, `/` when it is the only one), the rest is the file name. No normalisation, so the text
    /// the person typed is the text the kernel resolves.
    static func splitDestination(_ destination: String) throws -> (parent: String, name: String) {
        func refuse(_ detail: String) -> SafariBrowserError {
            .pdfCache(.destinationWriteFailed(path: destination, detail: detail))
        }
        guard !destination.isEmpty else { throw refuse("the destination is empty") }
        guard !destination.hasSuffix("/") else { throw refuse("it must name a file, not a folder") }
        guard let slash = destination.lastIndex(of: "/") else {
            guard destination != ".", destination != ".." else { throw refuse("it must name a file, not a folder") }
            return (".", destination)
        }
        let parent = String(destination[..<slash])
        let name = String(destination[destination.index(after: slash)...])
        guard name != ".", name != ".." else { throw refuse("it must name a file, not a folder") }
        return (parent.isEmpty ? "/" : parent, name)
    }

    /// The folder as the kernel reports it for an open descriptor: symlinks resolved, case as stored.
    private static func canonicalPath(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// A destination inside one of Safari's own folders is refused, with or without `--force`:
    /// writing there replaces a record, a body or a temporary of Safari's, not a copy of ours.
    /// Both sides are canonicalised through a descriptor, so a symlink or a different spelling
    /// of the same folder does not get past it.
    private static func refuseInside(_ folders: [URL], parentPath: String, destination: String) throws {
        for folder in folders {
            let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard let protected = canonicalPath(of: fd) else { continue }
            if parentPath == protected || parentPath.hasPrefix(protected == "/" ? "/" : protected + "/") {
                throw SafariBrowserError.pdfCache(.destinationWriteFailed(
                    path: destination, detail: "it is inside Safari's own cache folder, which this command only reads"))
            }
        }
    }

    /// Owner-only: mode 0600 whatever the umask, and no ACL entries — a folder can hand down an
    /// inheritable ACL that grants other users access independently of the mode bits. Done
    /// before a byte is written, so nothing private is ever in a file anyone else could open.
    /// A file system without ACLs has nothing to remove.
    private static func restrictToOwner(_ fd: Int32, destination: String) throws {
        guard fchmod(fd, 0o600) == 0 else { throw writeFailure(destination, errno) }
        guard let empty = acl_init(0) else { return }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) != 0 {
            let code = errno
            if code != ENOENT, code != ENOTSUP, code != EINVAL, code != EOPNOTSUPP { throw writeFailure(destination, code) }
        }
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
    ///
    /// A failed `pread` is not an end of file. The provider records the first such
    /// failure, and it decides the verdict: CoreGraphics would otherwise see a short
    /// read and report "could not open", or worse, verify a file it only half read.
    static func verifiedPageCount(fd: Int32, size: Int64, read: PositionalRead? = nil) throws -> Int {
        let reader = PDFCacheDescriptorReader(fd: fd, read: read)
        func fail(_ detail: String) -> SafariBrowserError {
            if reader.failure != 0 {
                return .pdfCache(.unreadablePDF(detail: "reading the copy back failed: \(String(cString: strerror(reader.failure))) (errno \(reader.failure))"))
            }
            return .pdfCache(.unreadablePDF(detail: detail))
        }
        guard size <= Int64(Int.max) else { throw fail("it is too large") }
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info else { return 0 }
                let reader = Unmanaged<PDFCacheDescriptorReader>.fromOpaque(info).takeUnretainedValue()
                var received = 0
                while received < count {
                    let step = reader.read(reader.fd, buffer.advanced(by: received), count - received, position + off_t(received))
                    if step.count < 0 {
                        if step.errno == EINTR { continue }
                        if reader.failure == 0 { reader.failure = step.errno }
                        break
                    }
                    if step.count == 0 { break }
                    received += step.count
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
        // Pages that read fine from a copy that could not be read to the end are not a pass.
        if reader.failure != 0 { throw fail("") }
        return document.numberOfPages
    }

    private static func writeFailure(_ path: String, _ code: Int32, prefix: String? = nil) -> SafariBrowserError {
        let cause = "\(String(cString: strerror(code))) (errno \(code))"
        return .pdfCache(.destinationWriteFailed(path: path, detail: prefix.map { "\($0) \(cause)" } ?? cause))
    }
}

/// One positional read: the bytes it returned (negative on failure, with the errno).
typealias PositionalRead = (Int32, UnsafeMutableRawPointer, Int, off_t) -> (count: Int, errno: Int32)

/// Lets CoreGraphics read the staged copy through the descriptor that wrote it.
private final class PDFCacheDescriptorReader {
    let fd: Int32
    let read: PositionalRead
    /// The first read errno that was not EINTR; 0 when every read succeeded.
    var failure: Int32 = 0
    init(fd: Int32, read: PositionalRead?) {
        self.fd = fd
        self.read = read ?? { fd, buffer, count, position in
            let result = pread(fd, buffer, count, position)
            return (result, result < 0 ? errno : 0)
        }
    }
}
