import ArgumentParser
import CoreGraphics
import Darwin
import Foundation

/// A single monotonic budget shared by the native exporter and publication.
struct PDFExportDeadline: Sendable {
    private let started: UInt64
    private let timeout: TimeInterval

    init(timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout > 0 else {
            throw ValidationError("PDF export timeout must be finite and greater than zero.")
        }
        self.started = DispatchTime.now().uptimeNanoseconds
        self.timeout = timeout
    }

    func remaining() throws -> TimeInterval {
        try Task.checkCancellation()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        guard elapsed < timeout else { throw PDFExportTransaction.Failure.timeout }
        return timeout - elapsed
    }

    func check() throws { _ = try remaining() }
}

enum PDFExportTransaction {
    enum Failure: LocalizedError {
        case timeout
        case filesystem(String, Int32)
        var errorDescription: String? {
            switch self {
            case .timeout: return "PDF export timed out before a complete PDF could be published."
            case .filesystem(let operation, let code):
                return "PDF export \(operation) failed: \(String(cString: strerror(code)))."
            }
        }
    }

    static func validateDestination(path: String, overwrite: Bool) throws {
        guard !path.isEmpty, !path.utf8.contains(0), !path.hasSuffix("/") else {
            throw ValidationError("PDF destination must name a file and cannot contain NUL.")
        }
        let url = URL(fileURLWithPath: path)
        let parent = try openParent(url)
        defer { close(parent) }
        _ = try destinationMode(parent: parent, name: url.lastPathComponent, overwrite: overwrite)
    }

    static func run(
        destination: URL, overwrite: Bool, timeout: TimeInterval = 60,
        isolation: isolated (any Actor)? = #isolation,
        exporter: (URL, PDFExportDeadline) async throws -> Void
    ) async throws -> URL {
        let deadline = try PDFExportDeadline(timeout: timeout)
        try deadline.check()
        guard destination.isFileURL else { throw ValidationError("PDF destination must be a file URL.") }
        try validateDestination(path: destination.path, overwrite: overwrite)
        let parent = try openParent(destination)
        defer { close(parent) }
        _ = try destinationMode(parent: parent, name: destination.lastPathComponent, overwrite: overwrite)

        var template = Array((NSTemporaryDirectory() + "safari-browser-pdf-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw Failure.filesystem("creating private staging", errno) }
        let stagingDirectory = URL(fileURLWithPath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let staging = stagingDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try await exporter(staging, deadline)
        try deadline.check()

        // Keep even the final output mode inaccessible until the atomic rename.
        let privateName = ".safari-browser-pdf-\(UUID().uuidString)"
        guard mkdirat(parent, privateName, 0o700) == 0 else {
            throw Failure.filesystem("creating private snapshot directory", errno)
        }
        defer { unlinkat(parent, privateName, AT_REMOVEDIR) }
        let privateDirectory = openat(parent, privateName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard privateDirectory >= 0 else { throw Failure.filesystem("opening private snapshot directory", errno) }
        defer { close(privateDirectory) }
        let snapshotName = "snapshot.pdf"
        let snapshot = openat(privateDirectory, snapshotName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard snapshot >= 0 else { throw Failure.filesystem("creating snapshot", errno) }
        defer {
            close(snapshot)
            // The snapshot name vanishes on success; this never removes the destination.
            unlinkat(privateDirectory, snapshotName, 0)
        }

        var sourceMode: mode_t?
        while sourceMode == nil {
            try deadline.check()
            sourceMode = try coherentSnapshot(source: staging, snapshot: snapshot, deadline: deadline)
            if sourceMode == nil {
                let delay = min(0.025, try deadline.remaining())
                try await Task.sleep(for: .seconds(delay))
            }
        }
        // Reinspect late entries, including their permissions, through the same parent fd.
        let existingMode = try destinationMode(parent: parent, name: destination.lastPathComponent, overwrite: overwrite)
        guard fchmod(snapshot, existingMode ?? sourceMode!) == 0 else {
            throw Failure.filesystem("setting output permissions", errno)
        }
        // The fd binds publication; this check also catches an already-moved parent path.
        // It cannot make arbitrary subsequent ancestor renames atomic with publication.
        var boundParent = stat(), namedParent = stat()
        guard fstat(parent, &boundParent) == 0,
              stat(destination.deletingLastPathComponent().path, &namedParent) == 0,
              boundParent.st_dev == namedParent.st_dev, boundParent.st_ino == namedParent.st_ino else {
            throw ValidationError("PDF destination directory changed before publication.")
        }
        try deadline.check()
        try publishSnapshot(snapshotDirectory: privateDirectory, snapshotName: snapshotName,
                            parent: parent, destinationName: destination.lastPathComponent, overwrite: overwrite)

        return destination
    }

    static func publishSnapshot(snapshotDirectory: Int32, snapshotName: String,
                                parent: Int32, destinationName: String, overwrite: Bool) throws {
        // One publication attempt only. Never replay a syscall with an uncertain result.
        let result: Int32
        if overwrite {
            result = renameat(snapshotDirectory, snapshotName, parent, destinationName)
        } else {
            result = renameatx_np(snapshotDirectory, snapshotName, parent, destinationName, UInt32(RENAME_EXCL))
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST { throw ValidationError("PDF destination already exists; use --overwrite to replace it.") }
            throw Failure.filesystem("publishing snapshot (not retried)", code)
        }
    }

    private static func openParent(_ url: URL) throws -> Int32 {
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ValidationError("Cannot inspect PDF destination directory: \(String(cString: strerror(errno))).") }
        return fd
    }

    /// A leaf symlink is an entry to replace, never a file to open for writing.
    private static func destinationMode(parent: Int32, name: String, overwrite: Bool) throws -> mode_t? {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw ValidationError("Cannot inspect PDF destination: \(String(cString: strerror(errno))).")
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK {
            var target = stat()
            if fstatat(parent, name, &target, 0) == 0 {
                guard target.st_mode & S_IFMT == S_IFREG else {
                    throw ValidationError("PDF destination symlink must point to a regular file or be dangling, not a directory or special file.")
                }
            } else if errno != ENOENT {
                throw ValidationError("Cannot inspect PDF destination symlink: \(String(cString: strerror(errno))).")
            }
        } else if type != S_IFREG {
            throw ValidationError("PDF destination must be a regular file, not a directory or special file.")
        }
        guard overwrite else { throw ValidationError("PDF destination already exists; use --overwrite to replace it.") }
        return type == S_IFREG ? info.st_mode & 0o777 : nil
    }

    /// A changed generation is retried inside the original deadline; the exporter is not replayed.
    static func coherentSnapshot(source: URL, snapshot: Int32, deadline: PDFExportDeadline) throws -> mode_t? {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw Failure.filesystem("opening staging PDF", errno)
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw Failure.filesystem("inspecting staging PDF", errno) }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw ValidationError("PDF staging output is not a regular file.")
        }
        guard before.st_size > 0 else { return nil }
        guard ftruncate(snapshot, 0) == 0 else { throw Failure.filesystem("resetting snapshot", errno) }
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        var offset: off_t = 0
        while offset < before.st_size {
            try deadline.check()
            let requested = Int(min(off_t(buffer.count), before.st_size - offset))
            let count = pread(fd, &buffer, requested, offset)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.filesystem("reading staging PDF", errno)
            }
            if count == 0 { return nil }
            var written = 0
            try buffer.withUnsafeBytes { bytes in
                while written < count {
                    try deadline.check()
                    let result = pwrite(snapshot, bytes.baseAddress!.advanced(by: written), count - written, offset + off_t(written))
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else { throw Failure.filesystem("writing snapshot", errno) }
                    written += result
                }
            }
            offset += off_t(count)
        }
        guard unchanged(fd: fd, path: source.path, before: before) else { return nil }
        guard try readablePDF(fd: snapshot, size: before.st_size, deadline: deadline) else { return nil }
        guard unchanged(fd: fd, path: source.path, before: before) else { return nil }
        return before.st_mode & 0o777
    }

    private static func unchanged(fd: Int32, path: String, before: stat) -> Bool {
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, lstat(path, &named) == 0 else { return false }
        return sameGeneration(before, after) && sameGeneration(after, named)
    }

    private static func sameGeneration(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_gen == rhs.st_gen
            && lhs.st_size == rhs.st_size && lhs.st_mode == rhs.st_mode
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func readablePDF(fd: Int32, size: off_t, deadline: PDFExportDeadline) throws -> Bool {
        var header = [UInt8](repeating: 0, count: 5)
        guard pread(fd, &header, header.count, 0) == header.count, header == Array("%PDF-".utf8) else { return false }
        // Read backwards in bounded blocks so arbitrarily long trailing whitespace needs no size cap.
        var cursor = size
        var ending: [UInt8] = []
        var tail = [UInt8](repeating: 0, count: 4096)
        let whitespace: Set<UInt8> = [0, 9, 10, 12, 13, 32]
        while cursor > 0 && ending.count < 5 {
            try deadline.check()
            let count = Int(min(cursor, off_t(tail.count)))
            cursor -= off_t(count)
            guard pread(fd, &tail, count, cursor) == count else { return false }
            for byte in tail.prefix(count).reversed() {
                if ending.isEmpty && whitespace.contains(byte) { continue }
                ending.append(byte)
                if ending.count == 5 { break }
            }
        }
        guard ending.reversed().elementsEqual("%%EOF".utf8), size <= off_t(Int.max) else { return false }
        let reader = PDFSnapshotReader(fd: fd)
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info else { return 0 }
                let reader = Unmanaged<PDFSnapshotReader>.fromOpaque(info).takeUnretainedValue()
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
                if let info { Unmanaged<PDFSnapshotReader>.fromOpaque(info).release() }
            }
        )
        let info = Unmanaged.passRetained(reader).toOpaque()
        guard let provider = CGDataProvider(directInfo: info, size: size, callbacks: &callbacks) else {
            Unmanaged<PDFSnapshotReader>.fromOpaque(info).release()
            return false
        }
        guard let document = CGPDFDocument(provider), document.isUnlocked, document.numberOfPages > 0 else { return false }
        for number in 1...document.numberOfPages {
            try deadline.check()
            guard document.page(at: number) != nil else { return false }
        }
        return true
    }
}

/// CoreGraphics reads the immutable snapshot fd, without reopening a path or mapping mutable staging.
private final class PDFSnapshotReader {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
}
