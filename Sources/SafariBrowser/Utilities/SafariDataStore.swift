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
        // `withIntermediateDirectories: false` on purpose. With `true` the call
        // succeeds when the path already exists — including when it exists as a
        // symlink into somewhere else, which would silently redirect the copy.
        // A v4 UUID makes that unguessable today, but then the defence is name
        // entropy rather than the API, and nothing says so. `false` throws on a
        // pre-existing path and costs nothing here: the parent always exists.
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: false)
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
            var copiedWAL = false
            for suffix in walSuffixes {
                let sidecar = URL(fileURLWithPath: sourceURL.path + suffix)
                // An absent sidecar is rare, not the steady state. Apple's
                // SQLite ships with WAL persistence on, so `-wal` and `-shm`
                // survive a clean last-connection close — measured, and both
                // are present next to the live History.db right now. Skipping
                // is still correct when one is genuinely gone; see the
                // stand-in below for why that case is not benign.
                guard fm.fileExists(atPath: sidecar.path) else { continue }
                do {
                    try fm.copyItem(
                        at: sidecar,
                        to: tempDir.appendingPathComponent(sidecar.lastPathComponent))
                } catch {
                    // The two sidecars are NOT interchangeable here.
                    //
                    // `-wal` holds committed transactions that have not been
                    // checkpointed into the main file yet. Reading without it
                    // silently returns a database missing the most recent
                    // activity — the exact failure `hasWALSidecars` exists to
                    // prevent — so a copy failure has to be fatal. Swallowing
                    // it with `try?` reintroduced that silence.
                    //
                    // `-shm` is only the shared-memory index into `-wal`.
                    // SQLite rebuilds it on open when it is missing and the
                    // directory is writable, which the temp dir always is. A
                    // failure there costs nothing but is worth saying aloud.
                    if suffix == "-wal" {
                        throw SafariBrowserError.safariDataParseFailed(
                            path: sourceURL.path,
                            detail: """
                                the write-ahead log (\(sidecar.lastPathComponent)) exists but \
                                could not be copied: \(error.localizedDescription). Reading \
                                without it would silently omit recently recorded entries, so \
                                the command stopped instead of returning incomplete results.
                                """)
                    }
                    LocalDataOutput.writeStderr(
                        "note: could not copy \(sidecar.lastPathComponent) "
                            + "(\(error.localizedDescription)); SQLite can rebuild it from "
                            + "the WAL. If it cannot, the query stops with an error rather "
                            + "than returning a partial answer.\n")
                }
                if suffix == "-wal" { copiedWAL = true }
            }

            // A database whose header says WAL cannot be opened read-only when
            // no -wal file is present: SQLite returns SQLITE_CANTOPEN rather
            // than treating the main file as complete. It will happily create a
            // missing -shm, but it will not create a missing -wal on a
            // read-only connection.
            //
            // That state is not exotic — it is what the guard above calls the
            // normal steady state, because Safari checkpoints and deletes the
            // -wal on a clean quit. Without this, `history` and `cloud-tabs`
            // report the user's data file as unparseable whenever Safari has
            // been closed cleanly, which is the opposite of true.
            //
            // An empty -wal is the fix SQLite itself expects: a zero-length WAL
            // has no valid header, so recovery treats it as "no frames to
            // replay" and reads the main file, which by then holds everything.
            // Verified against libsqlite3 3.54.0: main-only fails to open,
            // main + zero-length -wal returns every row.
            if !copiedWAL {
                fm.createFile(atPath: destination.path + "-wal", contents: nil)
            }
        }

        return try body(destination)
    }
}
