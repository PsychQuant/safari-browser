import Foundation

/// 單一消費者的結果／取消仲裁；所有可變狀態均由 lock 保護。
/// 第一個終止結果勝出，transport 取消等待時不需等待原 handler 返回。
final class DaemonRequestCompletion<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Value?, Never>)
        case completed(Value)
        case finished
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var consumerClaimed = false

    /// 只有第一個呼叫可消費結果；重複呼叫立即回傳 nil，且不取消原消費者。
    /// nil 表示取消或重複等待。已勝出的結果即使稍後取消仍會交付一次。
    func wait() async -> Value? {
        let claimed = lock.withLock {
            guard !consumerClaimed else { return false }
            consumerClaimed = true
            return true
        }
        guard claimed else { return nil }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: (resume: Bool, value: Value?) = lock.withLock {
                    switch state {
                    case .pending:
                        state = .waiting(continuation)
                        return (false, nil)
                    case .completed(let value):
                        state = .finished
                        return (true, value)
                    case .finished:
                        return (true, nil)
                    case .waiting:
                        preconditionFailure("completion consumer already registered")
                    }
                }
                if immediate.resume { continuation.resume(returning: immediate.value) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// 只有首次結果可被接受。取消或完成後的晚到值不會存入本物件。
    @discardableResult
    func complete(_ value: Value) -> Bool {
        let resolution: (accepted: Bool, waiter: CheckedContinuation<Value?, Never>?) = lock.withLock {
            switch state {
            case .pending:
                state = .completed(value)
                return (true, nil)
            case .waiting(let continuation):
                state = .finished
                return (true, continuation)
            case .completed, .finished:
                return (false, nil)
            }
        }
        resolution.waiter?.resume(returning: value)
        return resolution.accepted
    }

    /// 取消只撤銷尚未完成的等待，不覆蓋已勝出的結果。
    func cancel() {
        let waiter: CheckedContinuation<Value?, Never>? = lock.withLock {
            switch state {
            case .pending:
                state = .finished
                return nil
            case .waiting(let continuation):
                state = .finished
                return continuation
            case .completed, .finished:
                return nil
            }
        }
        waiter?.resume(returning: nil)
    }
}
