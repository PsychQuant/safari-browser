import Foundation

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

    /// SQLite sources run in WAL mode. Copying one without `-wal` drops rows
    /// that are committed but not yet checkpointed — and drops them
    /// *silently*, which is the whole reason this flag exists rather than
    /// always globbing sidecars.
    var hasWALSidecars: Bool {
        switch self {
        case .history, .cloudTabs: return true
        case .bookmarks, .downloads: return false
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
    /// WAL sidecar suffixes, in the order SQLite documents them.
    private static let walSuffixes = ["-wal", "-shm"]

    static var safariDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari", isDirectory: true)
    }

    static func sourceURL(for file: SafariDataFile) -> URL {
        safariDirectory.appendingPathComponent(file.filename)
    }

    /// Copies `file` into a private temp directory and hands the copy to
    /// `body`. The directory is removed when `body` returns *or throws*.
    ///
    /// Reading the live file in place is not an option: it is TCC-protected,
    /// Safari may be mid-write, and SQLite would want a lock on a database the
    /// browser owns.
    @discardableResult
    static func withCopy<T>(_ file: SafariDataFile, _ body: (URL) throws -> T) throws -> T {
        try withCopy(
            sourceURL: sourceURL(for: file),
            includeWALSidecars: file.hasWALSidecars,
            body)
    }

    /// Source-injectable core. Tests drive this directly with fixtures; the
    /// production entry point above supplies the real `~/Library/Safari` path.
    ///
    /// Cleanup is scoped rather than handed back to the caller: the spec
    /// requires the temp copy to be gone "whether successfully or with an
    /// error", and any contract that relies on callers remembering `defer`
    /// leaks on exactly the path that is hardest to notice.
    @discardableResult
    static func withCopy<T>(
        sourceURL: URL,
        includeWALSidecars: Bool,
        _ body: (URL) throws -> T
    ) throws -> T {
        let fm = FileManager.default

        guard fm.fileExists(atPath: sourceURL.path) else {
            throw SafariBrowserError.safariDataFileNotFound(path: sourceURL.path)
        }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("safari-data-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let destination = tempDir.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try fm.copyItem(at: sourceURL, to: destination)
        } catch {
            // A readable directory entry that will not copy is, in practice,
            // TCC refusing the read — the entry is visible but the bytes are
            // not. Surface it as the permission problem it is rather than as
            // an opaque Cocoa error.
            throw SafariBrowserError.fullDiskAccessRequired(
                path: sourceURL.path, signing: CodeSigningState.current())
        }

        if includeWALSidecars {
            for suffix in walSuffixes {
                let sidecar = URL(fileURLWithPath: sourceURL.path + suffix)
                // Absent sidecars are the normal steady state: Safari
                // checkpoints and removes them on a clean close.
                guard fm.fileExists(atPath: sidecar.path) else { continue }
                try? fm.copyItem(
                    at: sidecar,
                    to: tempDir.appendingPathComponent(sidecar.lastPathComponent))
            }
        }

        return try body(destination)
    }
}
