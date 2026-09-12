import Foundation
import Darwin

/// The four on-disk files Safari keeps under `~/Library/Safari/` (#109).
///
/// Every other safari-browser command drives the *running* browser through
/// AppleScript, Accessibility, or CoreGraphics. These four are the only
/// sources that answer "what did I look at before", and they are read from
/// disk — which is why this is the repo's first filesystem path and why the
/// copy discipline below has no prior art to follow.
enum SafariDataFile: CaseIterable {
    case history
    case bookmarks
    case cloudTabs
    case downloads

    var filename: String {
        switch self {
        case .history: return "History.db"
        case .bookmarks: return "Bookmarks.plist"
        case .cloudTabs: return "CloudTabs.db"
        case .downloads: return "Downloads.plist"
        }
    }

    /// Human-facing name used in the "file is absent" notice.
    var describedSource: String {
        switch self {
        case .history: return "browsing history"
        case .bookmarks: return "bookmarks and Reading List"
        case .cloudTabs: return "iCloud tabs from your other devices"
        case .downloads: return "download history"
        }
    }
}

enum SafariDataStore {
    static var safariDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari", isDirectory: true)
    }
    static func sourceURL(for file: SafariDataFile) -> URL {
        safariDirectory.appendingPathComponent(file.filename)
    }

    /// No filesystem copy is produced. Memory belongs to this process and is
    /// reclaimed even when the process is interrupted before Swift defers run.
    static func readPlist(sourceURL: URL) throws -> Data {
        let fd = try openSource(sourceURL)
        defer { close(fd) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw ioError(path: sourceURL.path, code: code)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func withDatabaseSnapshot<T>(
        sourceURL: URL, timeout: TimeInterval = 5,
        _ body: (SQLiteReader.Database) throws -> T
    ) throws -> T {
        try SQLiteReader.withSnapshot(at: sourceURL, timeout: timeout, body)
    }

    /// Preserve the failing open's errno rather than inferring access from a
    /// Boolean existence probe. An unreadable source is not a missing source.
    static func openSource(_ url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ioError(path: url.path, code: errno, allowMissing: true) }
        var info = stat()
        if fstat(fd, &info) != 0 {
            let code = errno; close(fd)
            throw ioError(path: url.path, code: code)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw ioError(path: url.path, code: info.st_mode & S_IFMT == S_IFDIR ? EISDIR : EINVAL)
        }
        return fd
    }

    static func ioError(path: String, code: Int32, allowMissing: Bool = false) -> SafariBrowserError {
        switch code {
        case ENOENT where allowMissing: return .safariDataFileNotFound(path: path)
        case EACCES, EPERM:
            return .fullDiskAccessRequired(path: path, signing: CodeSigningState.current())
        default:
            return .safariDataReadFailed(path: path, detail: "\(String(cString: strerror(code))) (errno \(code))")
        }
    }
}
