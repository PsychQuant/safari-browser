import Foundation

/// AX nodes and visibility evidence stay on the worker that read them.
struct CurrentDialogWindow<Node> {
    let element: Node
    let isOnScreen: Bool
    let isMinimized: Bool?
    var allowsClear: Bool { isOnScreen && isMinimized == false }
}
protocol CurrentWindowDialogProvider: DialogProbeProvider {
    func currentWindow(deadline: DispatchTime) throws -> CurrentDialogWindow<Node>
}

final class CurrentWindowDialogProbe: @unchecked Sendable {
    static let shared = CurrentWindowDialogProbe(worker: .shared) { AXDialogProbeProvider() }
    private let worker: BoundedAXWorker
    private let inspect: @Sendable (DispatchTime) -> WindowDialogStatus

    init<P: CurrentWindowDialogProvider>(
        worker: BoundedAXWorker = BoundedAXWorker(),
        provider: @escaping @Sendable () -> P
    ) {
        self.worker = worker
        inspect = { deadline in
            let source = provider()
            var windowID: Int?
            do {
                let before = try source.currentWindow(deadline: deadline)
                let id = try source.windowID(before.element, timeout: Self.remaining(deadline))
                guard id > 0 else { return Self.unknown("missingID") }
                windowID = id
                let snapshot = DialogTreeScanner<P>().scan(
                    provider: source, deadline: deadline, roots: [before.element])
                let after = try source.currentWindow(deadline: deadline)
                let finalID = try source.windowID(after.element, timeout: Self.remaining(deadline))
                guard finalID == id else { return Self.unknown("identityChanged") }
                _ = try Self.remaining(deadline)
                let result = WindowDialogObservation(snapshot: snapshot).status(for: id)
                if result.state == .clear && !(before.allowsClear && after.allowsClear) {
                    return Self.unknown("visibilityUnconfirmed", windowID: id)
                }
                return result
            } catch DialogProbeReadError.accessibilityDenied {
                return Self.unknown("denied", windowID: windowID)
            } catch {
                return Self.unknown("incomplete", windowID: windowID)
            }
        }
    }

    /// Explicit inspection, independent of automatic entry-probe opt-out.
    func observe(budget: TimeInterval = 0.8, session: GUISession = .live) -> WindowDialogStatus {
        if let failure = Self.sessionFailure(session) { return failure }
        let result = worker.run(budget: budget, fallback: Self.unknown("incomplete")) { [inspect] deadline in
            if let failure = Self.sessionFailure(session) { return failure }
            return inspect(deadline)
        }
        return Self.sessionFailure(session) ?? result
    }

    static func remaining(_ deadline: DispatchTime) throws -> Float {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { throw DialogProbeReadError.unavailable }
        return Float(Double(deadline.uptimeNanoseconds - now) / 1_000_000_000)
    }
    static func unknown(_ reason: String, windowID: Int? = nil) -> WindowDialogStatus {
        .init(state: .unknown, windowID: windowID, messages: [], reason: reason)
    }
    private static func sessionFailure(_ session: GUISession) -> WindowDialogStatus? {
        switch session.state {
        case .available: return nil
        case .locked: return unknown("locked")
        case .unavailable: return unknown("unavailable")
        }
    }
}
