import AppKit
import Darwin

/// A bounded, explicitly restored file URL pasteboard lease.
/// NSPasteboard has no cross-process compare-and-swap: another writer can race
/// the final ownership check and write. Forced termination also prevents cleanup.
@MainActor
final class FileURLClipboard {
    enum RestoreOutcome: Equatable { case restored, preservedNewer }

    enum ClipboardError: LocalizedError {
        case invalidInput, unreadable, oversized, changedDuringSnapshot
        case writeFailedRestored, writeFailedPreservedNewer, writeAndRestoreFailed
        case restorationFailed
        case overlappingLease, unsafeLock, lockUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidInput: "Native upload requires a file URL and a nonnegative clipboard snapshot limit."
            case .unreadable: "Clipboard snapshot is unreadable; the clipboard was not changed."
            case .oversized: "Clipboard snapshot exceeds the size limit; the clipboard was not changed."
            case .changedDuringSnapshot: "Clipboard changed during snapshot; newer contents were preserved."
            case .writeFailedRestored: "Could not write the file URL; original clipboard contents were restored."
            case .writeFailedPreservedNewer: "Could not establish file URL clipboard ownership; observed newer contents were preserved."
            case .writeAndRestoreFailed: "Could not write the file URL, and clipboard restoration failed."
            case .restorationFailed: "Clipboard restoration failed."
            case .overlappingLease: "Another native upload owns this clipboard; wait for it to finish."
            case .unsafeLock: "Native upload clipboard lock has unsafe ownership, permissions, or file type."
            case .lockUnavailable: "Could not acquire the native upload clipboard lock."
            }
        }
    }

    struct Representation {
        let type: NSPasteboard.PasteboardType
        let data: () -> Data?
    }

    /// Internal seam for deterministic read/write failure and race tests.
    struct Operations {
        let boardIdentity: String
        var lockDirectory: URL?
        var changeCount: () -> Int
        var readItems: () -> [[Representation]]?
        var clear: () -> Int
        var writeFileURL: (URL) -> Bool
        var writeItems: ([NSPasteboardItem]) -> Bool

        init(pasteboard: NSPasteboard) {
            boardIdentity = pasteboard.name.rawValue
            lockDirectory = pasteboard.name == .general
                ? URL(fileURLWithPath: "/tmp/safari-browser-native-upload-\(getuid())", isDirectory: true) : nil
            changeCount = { pasteboard.changeCount }
            readItems = {
                guard let items = pasteboard.pasteboardItems else {
                    return (pasteboard.types ?? []).isEmpty ? [] : nil
                }
                return items.map { item in
                    item.types.map { type in Representation(type: type, data: { item.data(forType: type) }) }
                }
            }
            clear = { pasteboard.clearContents() }
            writeFileURL = { pasteboard.writeObjects([$0 as NSURL]) }
            writeItems = { pasteboard.writeObjects($0) }
        }
    }

    let ownedChangeCount: Int
    private let operations: Operations
    private let originalItems: [NSPasteboardItem]
    private var outcome: RestoreOutcome?
    private var restorationFailed = false
    private var exclusivity: FileURLClipboardExclusivity?

    convenience init(fileURL: URL, pasteboard: NSPasteboard = .general,
                     maximumBytes: Int = 64 * 1024 * 1024) throws {
        try self.init(fileURL: fileURL, operations: Operations(pasteboard: pasteboard), maximumBytes: maximumBytes)
    }

    init(fileURL: URL, operations: Operations, maximumBytes: Int = 64 * 1024 * 1024) throws {
        guard fileURL.isFileURL, maximumBytes >= 0 else { throw ClipboardError.invalidInput }
        // Acquire before snapshot: a second cooperating upload must never
        // mistake our temporary file URL for the user's original clipboard.
        let exclusivity = try FileURLClipboardExclusivity(identity: operations.boardIdentity,
                                                        directory: operations.lockDirectory)
        var initialized = false
        defer { if !initialized { exclusivity.release() } }
        let initialCount = operations.changeCount()
        guard let items = operations.readItems() else { throw ClipboardError.unreadable }
        var totalBytes = 0
        // Fully materialize restorable items before changing the actual board.
        let originalItems = try items.map { representations in
            let restored = NSPasteboardItem()
            for representation in representations {
                guard let data = representation.data() else { throw ClipboardError.unreadable }
                guard data.count <= maximumBytes - totalBytes else { throw ClipboardError.oversized }
                totalBytes += data.count
                guard restored.setData(data, forType: representation.type) else { throw ClipboardError.unreadable }
            }
            return restored
        }
        guard operations.changeCount() == initialCount else { throw ClipboardError.changedDuringSnapshot }
        self.operations = operations
        self.originalItems = originalItems
        self.exclusivity = exclusivity
        // clearContents establishes ownership. writeObjects populates that owner
        // without a second clear. Never adopt a subsequently observed owner.
        ownedChangeCount = operations.clear()
        guard operations.changeCount() == ownedChangeCount else { throw ClipboardError.writeFailedPreservedNewer }
        let wrote = operations.writeFileURL(fileURL)
        guard operations.changeCount() == ownedChangeCount else { throw ClipboardError.writeFailedPreservedNewer }
        if !wrote {
            do {
                let rollback = try restore()
                if rollback == .preservedNewer { throw ClipboardError.writeFailedPreservedNewer }
            } catch ClipboardError.writeFailedPreservedNewer {
                throw ClipboardError.writeFailedPreservedNewer
            } catch {
                throw ClipboardError.writeAndRestoreFailed
            }
            throw ClipboardError.writeFailedRestored
        }
        initialized = true
    }

    @discardableResult
    func restore() throws -> RestoreOutcome {
        defer { exclusivity?.release(); exclusivity = nil }
        guard !restorationFailed else { throw ClipboardError.restorationFailed }
        if let outcome { return outcome }
        guard operations.changeCount() == ownedChangeCount else {
            outcome = .preservedNewer
            return .preservedNewer
        }
        let restorationCount = operations.clear()
        guard operations.changeCount() == restorationCount else {
            outcome = .preservedNewer
            return .preservedNewer
        }
        if !originalItems.isEmpty {
            let wrote = operations.writeItems(originalItems)
            if operations.changeCount() != restorationCount {
                outcome = .preservedNewer
                return .preservedNewer
            }
            guard wrote else {
                restorationFailed = true
                throw ClipboardError.restorationFailed
            }
        }
        outcome = .restored
        return .restored
    }
}

/// Coordinates only cooperating native uploads, not arbitrary clipboard users.
/// Registry state is mutex-protected so deinitialization can release ownership
/// without accessing the main actor or changing the clipboard.
private final class FileURLClipboardExclusivity: @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let mutex = NSLock()
        var identities: Set<String> = []
    }
    private static let registry = Registry()
    private let mutex = NSLock()
    private let identity: String
    private var descriptor: Int32 = -1
    private var released = false
    private var registered = false

    init(identity: String, directory: URL?) throws {
        self.identity = identity
        let inserted = Self.registry.mutex.withLock {
            Self.registry.identities.insert(identity).inserted
        }
        guard inserted else { throw FileURLClipboard.ClipboardError.overlappingLease }
        registered = true
        do {
            if let directory { descriptor = try Self.acquire(directory: directory) }
        } catch {
            release()
            throw error
        }
    }

    private static func acquire(directory: URL) throws -> Int32 {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw FileURLClipboard.ClipboardError.lockUnavailable
        }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw FileURLClipboard.ClipboardError.unsafeLock }
        defer { close(parent) }
        var directoryInfo = stat()
        guard fstat(parent, &directoryInfo) == 0,
              directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o170000 == 0o040000,
              directoryInfo.st_mode & 0o7777 == 0o700 else {
            throw FileURLClipboard.ClipboardError.unsafeLock
        }
        let fd = openat(parent, "clipboard.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw FileURLClipboard.ClipboardError.unsafeLock }
        var keep = false
        defer { if !keep { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & 0o170000 == 0o100000,
              info.st_mode & 0o7777 == 0o600, info.st_nlink == 1 else {
            throw FileURLClipboard.ClipboardError.unsafeLock
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw FileURLClipboard.ClipboardError.overlappingLease }
            throw FileURLClipboard.ClipboardError.lockUnavailable
        }
        keep = true
        return fd
    }

    func release() {
        mutex.withLock {
            guard !released else { return }
            released = true
            if descriptor >= 0 {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
                descriptor = -1
            }
            if registered {
                _ = Self.registry.mutex.withLock { Self.registry.identities.remove(identity) }
                registered = false
            }
            // Keep the pathname permanently: unlinking permits a second inode
            // to be locked while another process still holds the first one.
        }
    }

    deinit { release() }
}
