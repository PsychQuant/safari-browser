import Foundation

/// A read-only description of a visible native dialog in one stable window.
/// It neither authorizes dismissal nor describes background tabs' pending dialogs.
struct WindowDialogStatus: Sendable {
    enum State: String, Sendable { case present, clear, unknown }
    let state: State
    let windowID: Int?
    let messages: [String]
    let reason: String?

    var jsonObject: [String: Any] {
        ["state": state.rawValue,
         "window_id": windowID.map { $0 as Any } ?? NSNull(),
         "messages": messages,
         "reason": reason.map { $0 as Any } ?? NSNull()]
    }

    var textSuffix: String? {
        switch state {
        case .clear: return nil
        case .present:
            if messages.count > 1 { return "[dialogs: \(messages.count)]" }
            return "[dialog: \(BlockingDialogWarning.messageText(messages.first ?? ""))]"
        case .unknown:
            return "[dialog: unknown (\(TerminalText.escaped(reason ?? "incomplete", limit: 64)))]"
        }
    }
}

/// Only Sendable values cross the bounded worker boundary; AX nodes stay there.
/// The legacy verdict is preserved even when partial candidate details cannot
/// safely be associated with listing rows.
struct WindowDialogObservation: Sendable {
    @TaskLocal static var provider: (@Sendable () -> WindowDialogObservation)?
    let scanResult: SafariBridge.DialogScan
    private let observedWindowIDs: Set<Int>
    private let messagesByWindowID: [Int: [String]]
    private let reason: String?

    init<Node>(snapshot: DialogTreeSnapshot<Node>) {
        scanResult = snapshot.scanResult
        observedWindowIDs = snapshot.observedWindowIDs
        reason = snapshot.accessibilityDenied ? "denied" : (snapshot.isComplete ? nil : "incomplete")
        var messages: [Int: [String]] = [:]
        if reason == nil {
            for candidate in snapshot.candidates {
                messages[candidate.windowID, default: []].append(candidate.dialog.message)
            }
        }
        messagesByWindowID = messages
    }

    private init(reason: String, scanResult: SafariBridge.DialogScan) {
        self.reason = reason
        self.scanResult = scanResult
        observedWindowIDs = []
        messagesByWindowID = [:]
    }

    static func unavailable(reason: String) -> Self {
        let scan: SafariBridge.DialogScan
        switch reason {
        case "locked": scan = .sessionLocked
        case "unavailable": scan = .sessionUnavailable
        case "denied": scan = .accessibilityDenied
        default: scan = .inspectionIncomplete
        }
        return .init(reason: reason, scanResult: scan)
    }

    static func capture(session: GUISession = .live, environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let disabled = DaemonRequestContext.current?.dialogProbeDisabled
            ?? (environment[BlockingDialogGate.optOutVariable] == "1")
        if disabled {
            return .unavailable(reason: "disabled")
        }
        if let provider { return provider() }
        switch session.state {
        case .locked: return .unavailable(reason: "locked")
        case .unavailable: return .unavailable(reason: "unavailable")
        case .available: return GlobalDialogProbe.shared.observe()
        }
    }

    func status(for windowID: Int?) -> WindowDialogStatus {
        if let reason { return .init(state: .unknown, windowID: windowID, messages: [], reason: reason) }
        guard let windowID, windowID > 0 else {
            return .init(state: .unknown, windowID: windowID, messages: [], reason: "missingID")
        }
        guard observedWindowIDs.contains(windowID) else {
            return .init(state: .unknown, windowID: windowID, messages: [], reason: "notobserved")
        }
        let messages = messagesByWindowID[windowID] ?? []
        return .init(state: messages.isEmpty ? .clear : .present, windowID: windowID, messages: messages, reason: nil)
    }
}
