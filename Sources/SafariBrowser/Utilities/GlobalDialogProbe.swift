import Foundation

extension DialogTreeSnapshot {
    var scanResult: SafariBridge.DialogScan {
        if accessibilityDenied { return .accessibilityDenied }
        if candidates.count > 1 { return .many(messages: candidates.map { $0.dialog.message }) }
        guard isComplete else { return .inspectionIncomplete }
        return candidates.first.map { .one($0.dialog) } ?? .none
    }
}

final class GlobalDialogProbe: @unchecked Sendable {
    static let shared = GlobalDialogProbe(worker: .shared) { AXDialogProbeProvider() }
    private let worker: BoundedAXWorker
    private let inspect: @Sendable (DispatchTime) -> WindowDialogObservation

    init<P: DialogProbeProvider>(
        worker: BoundedAXWorker = BoundedAXWorker(),
        provider: @escaping @Sendable () -> P
    ) {
        self.worker = worker
        inspect = { deadline in
            WindowDialogObservation(snapshot: DialogTreeScanner<P>().scan(provider: provider(), deadline: deadline))
        }
    }

    func observe(budget: TimeInterval = 0.8) -> WindowDialogObservation {
        worker.run(budget: budget, fallback: .unavailable(reason: "incomplete"), operation: inspect)
    }

    func scan(budget: TimeInterval = 0.8) -> SafariBridge.DialogScan {
        observe(budget: budget).scanResult
    }
}

/// This operation stays synchronous: an abandoned read worker must never
/// decide or press a button after its caller has returned an error.
enum DialogPressExecutor {
    static func perform<Node>(
        snapshot: DialogTreeSnapshot<Node>, deadline: DispatchTime, session: GUISession,
        expectedWindowID: Int? = nil,
        decide: (SafariBridge.BlockingDialog) -> Int?,
        press: (Node, Float) -> SafariBridge.DialogPressOutcome
    ) -> SafariBridge.DialogPressOutcome {
        switch session.state {
        case .locked: return .sessionLocked
        case .unavailable: return .sessionUnavailable
        case .available: break
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds else { return .inspectionIncomplete }
        switch snapshot.scanResult {
        case .accessibilityDenied: return .accessibilityDenied
        case .inspectionIncomplete: return .inspectionIncomplete
        case .many(let messages): return .ambiguous(messages: messages)
        case .none: return .noDialogFound
        case .sessionLocked: return .sessionLocked
        case .sessionUnavailable: return .sessionUnavailable
        case .one: break
        }
        guard let current = snapshot.candidates.first,
            current.buttons.map(\.title) == current.dialog.buttons
        else { return .inspectionIncomplete }
        if let expectedWindowID, current.windowID != expectedWindowID {
            return .refused(current: current.dialog)
        }
        guard let index = decide(current.dialog) else { return .refused(current: current.dialog) }
        guard current.buttons.indices.contains(index) else {
            return .indexOutOfRange(buttonCount: current.buttons.count)
        }
        switch session.state {
        case .locked: return .sessionLocked
        case .unavailable: return .sessionUnavailable
        case .available: break
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { return .inspectionIncomplete }
        let remaining = Float(Double(deadline.uptimeNanoseconds - now) / 1_000_000_000)
        return press(current.buttons[index].element, remaining)
    }
}
