import Darwin
import Foundation

/// A Run owns one append descriptor. Captured writers retain the same owner,
/// so teardown can release its reference without racing a still-live writer.
/// The last owner closes; no queue, flush task, or path reopening is involved.
final class DaemonLogFile: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private let onClose: @Sendable () -> Void

    init?(path: String, onClose: @escaping @Sendable () -> Void = {}) {
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { return nil }
        descriptor = fd
        self.onClose = onClose
    }

    var descriptorFlagsForTesting: Int32 { fcntl(descriptor, F_GETFD) }

    /// Preserve JSON-line writes within this owner. O_APPEND also prevents
    /// an old Run's offset from overwriting a replacement Run's records.
    /// I/O failure remains best-effort; this is not a durable flush contract.
    func write(_ line: String) {
        let data = Data(line.utf8)
        withExtendedLifetime(self) {
            lock.withLock {
                data.withUnsafeBytes { raw in
                    var written = 0
                    while written < raw.count {
                        let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { return }
                        written += count
                    }
                }
            }
        }
    }

    deinit {
        // No active write can outlive its owner. Never retry close on a
        // descriptor that the kernel could already have released/reused.
        _ = Darwin.close(descriptor)
        onClose()
    }
}
