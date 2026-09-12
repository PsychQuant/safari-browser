import Foundation

/// State owned by one incoming request, inherited through async bridge calls.
final class DaemonRequestContext: @unchecked Sendable {
    typealias AppleScriptRunner = @Sendable (String) async throws -> String
    @TaskLocal static var current: DaemonRequestContext?
    @TaskLocal static var appleScriptRunner: AppleScriptRunner?

    let id = UUID()
    private let probe: ((BlockingDialogGate.WindowKey) -> BlockingDialogState)?
    private var probeEnvironment: [String: String]
    init(
        probe: ((BlockingDialogGate.WindowKey) -> BlockingDialogState)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.probe = probe
        self.probeEnvironment = environment
    }

    /// Envelope options must be installed before a command creates its gate.
    /// Absent options intentionally preserve the legacy daemon environment.
    func configureDialogProbe(_ options: DialogProbeOptions?) throws {
        guard let options else { return }
        lock.lock(); defer { lock.unlock() }
        guard storedGate == nil else {
            throw DaemonDispatch.ExecRunScriptError.malformedEnvelope(
                "dialogProbe cannot be configured after probing starts")
        }
        probeEnvironment = options.environment
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
    var dialogProbeDisabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return probeEnvironment[BlockingDialogGate.optOutVariable] == "1"
    }

    var gate: BlockingDialogGate {
        lock.lock(); defer { lock.unlock() }
        if let gate = storedGate { return gate }
        let gate = BlockingDialogGate(probe: probe, stderr: { [weak self] in self?.emit($0) },
                                      environment: probeEnvironment)
        storedGate = gate
        return gate
    }
}
