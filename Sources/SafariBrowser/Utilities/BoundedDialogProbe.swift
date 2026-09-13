import AppKit
import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func dialogProbeWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A provider is constructed and used on one probe worker. Its nodes never
/// leave that worker; only the Sendable verdict crosses back to the caller.
protocol DialogProbeProvider: Sendable {
    associatedtype Node: Hashable
    func windows(timeout: Float) throws -> [Node]
    func windowID(_ node: Node, timeout: Float) throws -> Int
    func role(_ node: Node, timeout: Float) throws -> String
    func subrole(_ node: Node, timeout: Float) throws -> String?
    func children(_ node: Node, timeout: Float) throws -> [Node]
    func valueIsSettable(_ node: Node, timeout: Float) throws -> Bool?
    func text(_ node: Node, timeout: Float) throws -> String?
    func buttonTitle(_ node: Node, timeout: Float) throws -> String?
}

enum DialogProbeReadError: Error { case unavailable, accessibilityDenied }

final class BoundedDialogProbe: @unchecked Sendable {
    static let shared = BoundedDialogProbe(worker: .shared) { AXDialogProbeProvider() }

    private struct Budget: Sendable {
        let deadline: DispatchTime

        func remaining() throws -> Float {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { throw DialogProbeReadError.unavailable }
            return Float(Double(deadline.uptimeNanoseconds - now) / 1_000_000_000)
        }
    }

    private let worker: BoundedAXWorker
    private let waitBudget: TimeInterval
    private let inspect: @Sendable (Int, Budget) -> BlockingDialogState

    init<P: DialogProbeProvider>(
        waitBudget: TimeInterval = 0.095,
        maxDepth: Int = 5,
        maxNodes: Int = 128,
        worker: BoundedAXWorker = BoundedAXWorker(),
        provider: @escaping @Sendable () -> P
    ) {
        // Keep the production ceiling even when a caller supplies a larger
        // test budget. Invalid inputs use the regular finite budget.
        self.worker = worker
        self.waitBudget = waitBudget.isFinite && waitBudget > 0 ? min(waitBudget, 0.095) : 0.095
        self.inspect = { windowID, budget in
            Self.inspect(provider: provider(), windowID: windowID, budget: budget,
                         maxDepth: max(0, maxDepth), maxNodes: max(1, maxNodes))
        }
    }

    func check(windowKey: BlockingDialogGate.WindowKey, budget: TimeInterval = 0.1) -> BlockingDialogState {
        guard budget.isFinite, budget > 0 else { return .unprobed }
        let windowID: Int
        if case .id(let id) = windowKey, id > 0 { windowID = id }
        else { windowID = 0 }
        return worker.run(budget: min(waitBudget, budget), fallback: .unprobed) { [self] deadline in
            inspect(windowID, Budget(deadline: deadline))
        }
    }

    private static func inspect<P: DialogProbeProvider>(
        provider: P, windowID: Int, budget: Budget, maxDepth: Int, maxNodes: Int
    ) -> BlockingDialogState {
        do {
            let windows = try provider.windows(timeout: budget.remaining())
            if windows.isEmpty {
                // No positional target could be resolved: Safari has no visible
                // window evidence. A known ID missing from AX is still unknown.
                return windowID > 0 ? .unprobed : .clear
            }
            guard windowID > 0 else { return .unprobed }
            var target: P.Node?
            // A failed ID read cannot identify a window, but does not prevent
            // an exact positive ID later in the list from being identified.
            for window in windows.prefix(maxNodes) {
                if let id = try? provider.windowID(window, timeout: budget.remaining()),
                   id == windowID {
                    target = window
                    break
                }
            }
            guard let target else { return .unprobed }

            var pending: [(P.Node, Int)] = [(target, 0)]
            var inspected = 0
            var incomplete = false
            // Follow the first window-content path before sibling tab strips.
            // Breadth first visits every tab button before a depth-3 dialog in
            // Safari's content group, exhausting the budget on busy windows.
            while !pending.isEmpty && inspected < maxNodes {
                let (node, depth) = pending.removeLast()
                inspected += 1
                do {
                    let role = try provider.role(node, timeout: budget.remaining())
                    // Page ARIA dialogs are web content, not native UI that
                    // suspends JavaScript. Do not traverse into the WebArea.
                    if role == "AXWebArea" { continue }
                    let subrole = try provider.subrole(node, timeout: budget.remaining())
                    if role == "AXSheet" || role == "AXDialog" || subrole == "AXDialog" || subrole == "AXSystemDialog" {
                        return .present(details(of: node, provider: provider, budget: budget,
                                                maxDepth: maxDepth, maxNodes: maxNodes))
                    }
                    let children = try provider.children(node, timeout: budget.remaining())
                    if depth >= maxDepth {
                        incomplete = incomplete || !children.isEmpty
                    } else {
                        let room = max(0, maxNodes - inspected - pending.count)
                        if children.count > room { incomplete = true }
                        pending.append(contentsOf: children.prefix(room).reversed().map { ($0, depth + 1) })
                    }
                } catch {
                    incomplete = true
                }
            }
            return incomplete || !pending.isEmpty ? .unprobed : .clear
        } catch DialogProbeReadError.accessibilityDenied {
            return .accessibilityDenied
        } catch {
            return .unprobed
        }
    }

    private static func details<P: DialogProbeProvider>(
        of dialog: P.Node, provider: P, budget: Budget, maxDepth: Int, maxNodes: Int
    ) -> SafariBridge.BlockingDialog {
        var pending: [(P.Node, Int)] = [(dialog, 0)]
        var next = 0
        var messages: [String] = []
        var buttons: [String] = []
        while next < pending.count && next < maxNodes {
            let (node, depth) = pending[next]
            next += 1
            // A confirmed dialog remains present if optional details fail.
            if let role = try? provider.role(node, timeout: budget.remaining()) {
                if role == "AXWebArea" { continue }
                if let text = try? DialogMessageText.read(
                    node, role: role, provider: provider, remainingTimeout: budget.remaining), !text.isEmpty {
                    messages.append(text)
                }
                if role == "AXButton",
                   let title = try? provider.buttonTitle(node, timeout: budget.remaining()), !title.isEmpty {
                    buttons.append(title)
                }
            }
            if depth < maxDepth,
               let children = try? provider.children(node, timeout: budget.remaining()) {
                pending.append(contentsOf: children.prefix(max(0, maxNodes - pending.count))
                    .map { ($0, depth + 1) })
            }
        }
        return SafariBridge.BlockingDialog(
            message: messages.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            buttons: buttons)
    }
}

/// Real AX elements are born on and stay on the worker. Every attribute read
/// and window-ID SPI call first applies that operation's remaining budget.
struct AXDialogProbeProvider: DialogProbeProvider {
    var session: GUISession = .live
    func windows(timeout: Float) throws -> [AXUIElement] {
        guard session.state == .available else { throw DialogProbeReadError.unavailable }
        guard AXIsProcessTrusted() else { throw DialogProbeReadError.accessibilityDenied }
        guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first
        else { return [] }
        let app = AXUIElementCreateApplication(safari.processIdentifier)
        return try elements(app, attribute: kAXWindowsAttribute as CFString, timeout: timeout)
    }

    func windowID(_ node: AXUIElement, timeout: Float) throws -> Int {
        try prepare(node, timeout: timeout)
        var id: CGWindowID = 0
        guard dialogProbeWindowID(node, &id) == .success, id > 0 else {
            throw DialogProbeReadError.unavailable
        }
        return Int(id)
    }

    func role(_ node: AXUIElement, timeout: Float) throws -> String {
        guard let role = try string(node, attribute: kAXRoleAttribute as CFString, timeout: timeout) else {
            throw DialogProbeReadError.unavailable
        }
        return role
    }

    func subrole(_ node: AXUIElement, timeout: Float) throws -> String? {
        try string(node, attribute: kAXSubroleAttribute as CFString, timeout: timeout)
    }

    func children(_ node: AXUIElement, timeout: Float) throws -> [AXUIElement] {
        try elements(node, attribute: kAXChildrenAttribute as CFString, timeout: timeout, absentIsEmpty: true)
    }

    func valueIsSettable(_ node: AXUIElement, timeout: Float) throws -> Bool? {
        try prepare(node, timeout: timeout)
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success else { throw DialogProbeReadError.unavailable }
        return settable.boolValue
    }

    func text(_ node: AXUIElement, timeout: Float) throws -> String? {
        try string(node, attribute: kAXValueAttribute as CFString, timeout: timeout)
    }

    func buttonTitle(_ node: AXUIElement, timeout: Float) throws -> String? {
        try string(node, attribute: kAXTitleAttribute as CFString, timeout: timeout)
    }

    private func prepare(_ node: AXUIElement, timeout: Float) throws {
        guard AXUIElementSetMessagingTimeout(node, timeout) == .success else {
            throw DialogProbeReadError.unavailable
        }
    }

    private func string(_ node: AXUIElement, attribute: CFString, timeout: Float) throws -> String? {
        try prepare(node, timeout: timeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(node, attribute, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let string = value as? String else { throw DialogProbeReadError.unavailable }
        return string
    }

    private func elements(
        _ node: AXUIElement, attribute: CFString, timeout: Float, absentIsEmpty: Bool = false
    ) throws -> [AXUIElement] {
        try prepare(node, timeout: timeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(node, attribute, &value)
        if absentIsEmpty && (status == .attributeUnsupported || status == .noValue) { return [] }
        guard status == .success, let items = value as? [AnyObject],
              items.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
            throw DialogProbeReadError.unavailable
        }
        return items.map { $0 as! AXUIElement } // type IDs validated above
    }
}
