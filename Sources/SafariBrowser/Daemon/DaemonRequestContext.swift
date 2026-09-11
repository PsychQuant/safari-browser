import Foundation

/// State owned by one incoming request, inherited through async bridge calls.
final class DaemonRequestContext: @unchecked Sendable {
    typealias AppleScriptRunner = @Sendable (String) async throws -> String
    @TaskLocal static var current: DaemonRequestContext?
    @TaskLocal static var appleScriptRunner: AppleScriptRunner?

    let id = UUID()
    private let probe: ((BlockingDialogGate.WindowKey) -> BlockingDialogState)?
    init(probe: ((BlockingDialogGate.WindowKey) -> BlockingDialogState)? = nil) {
        self.probe = probe
    }
    private let lock = NSLock()
    private var messages: [String] = []
    private var storedGate: BlockingDialogGate?

    func emit(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append(message)
    }
    var diagnostics: [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
    var gate: BlockingDialogGate {
        lock.lock(); defer { lock.unlock() }
        if let gate = storedGate { return gate }
        let gate = BlockingDialogGate(probe: probe, stderr: { [weak self] in self?.emit($0) })
        storedGate = gate
        return gate
    }
}
