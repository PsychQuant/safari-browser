import Foundation

/// One allowance for AX inspection and synchronous actions. A caller timeout
/// abandons only its result; an unresponsive OS operation retains the allowance
/// until it actually returns. Busy callers never enqueue additional work.
final class BoundedAXWorker: @unchecked Sendable {
    static let shared = BoundedAXWorker()

    private final class ResultBox<Value: Sendable>: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let fallback: Value
        private var acceptsResult = true
        private var result: Value

        init(fallback: Value) {
            self.fallback = fallback
            result = fallback
        }

        func complete(_ value: Value) {
            lock.lock()
            if acceptsResult { result = value }
            lock.unlock()
            ready.signal()
        }

        func take(completed: Bool) -> Value {
            lock.lock(); defer { lock.unlock() }
            acceptsResult = false
            return completed ? result : fallback
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "safari-browser.ax-inspection", qos: .userInitiated)
    private var inFlight = false

    func run<Value: Sendable>(
        budget: TimeInterval, fallback: Value,
        operation: @escaping @Sendable (DispatchTime) -> Value
    ) -> Value {
        guard budget.isFinite, budget > 0 else { return fallback }
        let deadline = DispatchTime.now() + min(budget, 0.8)
        guard acquire() else { return fallback }
        let box = ResultBox(fallback: fallback)
        queue.async { [self] in
            // Scheduling itself consumes the same budget. Do not start a new
            // AX operation if this request expired before its worker started.
            let value = DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds
                ? operation(deadline) : fallback
            release()
            box.complete(value)
        }
        let completed = box.ready.wait(timeout: deadline) == .success
            && DispatchTime.now().uptimeNanoseconds <= deadline.uptimeNanoseconds
        return box.take(completed: completed)
    }

    /// Keeps node references and side effects on the caller's thread. There is
    /// no background action that could run after the caller receives fallback.
    func withExclusive<Value>(fallback: Value, operation: () -> Value) -> Value {
        guard acquire() else { return fallback }
        defer { release() }
        return operation()
    }

    private func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    private func release() {
        lock.lock(); inFlight = false; lock.unlock()
    }
}
