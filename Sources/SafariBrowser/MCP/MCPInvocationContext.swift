import Foundation

/// One parsed CLI invocation in a persistent process. Immutable references are
/// task-local; the gate and trace guard their own mutable state with locks.
final class MCPInvocationContext: @unchecked Sendable {
    @TaskLocal static var current: MCPInvocationContext?
    let gate: BlockingDialogGate
    let timing: PerformanceTrace.Collector?
    init(probe: ((BlockingDialogGate.WindowKey) -> BlockingDialogState)? = nil,
         stderr: ((String) -> Void)? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        gate = BlockingDialogGate(probe: probe, stderr: stderr, environment: environment)
        timing = PerformanceTrace.isEnabled(environment) ? PerformanceTrace.Collector() : nil
    }
    /// Cancellation is a request, not proof that the last write has finished.
    /// A persistent invocation cannot hand its stdio to the next request yet.
    /// Standalone CLI behavior remains cancel-only.
    static func finishAuxiliary(_ task: Task<Void, Never>) async {
        task.cancel()
        if current != nil { await task.value }
    }
    static func finishingAuxiliary<Value>(_ task: Task<Void, Never>, operation: () async throws -> Value) async rethrows -> Value {
        do {
            let result = try await operation()
            await finishAuxiliary(task)
            return result
        } catch {
            await finishAuxiliary(task)
            throw error
        }
    }
}
