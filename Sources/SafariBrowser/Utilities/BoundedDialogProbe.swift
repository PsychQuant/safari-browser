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
    /// Role, subrole and children of one node, for the traversal. A provider
    /// that can fetch them in one round trip should (#187: three IPCs per node
    /// left a process's first probe a few milliseconds inside its budget).
    func summary(_ node: Node, remaining: () throws -> Float) throws -> DialogProbeNodeSummary<Node>
}

/// What the traversal needs from one node.
struct DialogProbeNodeSummary<Node> {
    let role: String
    let subrole: String?
    /// Empty for a WebArea or a native modal: the traversal never enters them.
    let children: [Node]
}

extension DialogProbeProvider {
    func summary(_ node: Node, remaining: () throws -> Float) throws -> DialogProbeNodeSummary<Node> {
        try composedSummary(node, remaining: remaining)
    }

    /// The single-attribute reads in the order the traversal made them before
    /// #187: a WebArea's subrole and children, and a modal's children, are
    /// never read. Each read gets the budget remaining at that moment.
    func composedSummary(_ node: Node, remaining: () throws -> Float) throws -> DialogProbeNodeSummary<Node> {
        let role = try self.role(node, timeout: remaining())
        if role == "AXWebArea" { return .init(role: role, subrole: nil, children: []) }
        let subrole = try self.subrole(node, timeout: remaining())
        if BoundedDialogProbe.isNativeModal(role: role, subrole: subrole) {
            return .init(role: role, subrole: subrole, children: [])
        }
        return .init(role: role, subrole: subrole, children: try children(node, timeout: remaining()))
    }
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

    static func isNativeModal(role: String, subrole: String?) -> Bool {
        role == "AXSheet" || role == "AXDialog" || subrole == "AXDialog" || subrole == "AXSystemDialog"
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
                    let summary = try provider.summary(node, remaining: { try budget.remaining() })
                    // Page ARIA dialogs are web content, not native UI that
                    // suspends JavaScript. Do not traverse into the WebArea.
                    if summary.role == "AXWebArea" { continue }
                    if isNativeModal(role: summary.role, subrole: summary.subrole) {
                        return .present(details(of: node, provider: provider, budget: budget,
                                                maxDepth: maxDepth, maxNodes: maxNodes))
                    }
                    let children = summary.children
                    // #187: the page viewport — a scroll area hosting the
                    // WebArea — is page content like the WebArea itself; its
                    // other children are the viewport's scroll bars. Neither
                    // holds native modal UI, so it is a leaf, not a truncation.
                    if summary.role == "AXScrollArea",
                       try children.contains(where: { try provider.role($0, timeout: budget.remaining()) == "AXWebArea" }) {
                        continue
                    }
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
struct AXDialogProbeProvider: CurrentWindowDialogProvider {
    var session: GUISession = .live
    func currentWindow(deadline: DispatchTime) throws -> CurrentDialogWindow<AXUIElement> {
        guard session.state == .available else { throw DialogProbeReadError.unavailable }
        guard AXIsProcessTrusted() else { throw DialogProbeReadError.accessibilityDenied }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari")
        guard applications.count == 1, let safari = applications.first else {
            throw DialogProbeReadError.unavailable
        }
        let app = AXUIElementCreateApplication(safari.processIdentifier)
        try prepare(app, timeout: CurrentWindowDialogProbe.remaining(deadline))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw DialogProbeReadError.unavailable
        }
        let window = value as! AXUIElement // type ID validated above
        let id = try windowID(window, timeout: CurrentWindowDialogProbe.remaining(deadline))
        try prepare(window, timeout: CurrentWindowDialogProbe.remaining(deadline))
        var minimized: CFTypeRef?
        let minimizedStatus = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        let isMinimized: Bool? = minimizedStatus == .success ? minimized.flatMap {
            guard CFGetTypeID($0) == CFBooleanGetTypeID() else { return nil }
            return CFEqual($0, kCFBooleanTrue)
        } : nil
        _ = try CurrentWindowDialogProbe.remaining(deadline)
        let visible = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        let onScreen = visible?.contains { ($0[kCGWindowNumber as String] as? Int) == id } == true
        _ = try CurrentWindowDialogProbe.remaining(deadline)
        return .init(element: window, isOnScreen: onScreen, isMinimized: isMinimized)
    }

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

    /// One `AXUIElementCopyMultipleAttributeValues` round trip instead of
    /// three single reads (#187). An attribute the element cannot answer comes
    /// back as an AXError value in its slot: an unsupported or absent subrole
    /// is nil and absent children are empty, as with the single reads.
    func summary(_ node: AXUIElement, remaining: () throws -> Float) throws -> DialogProbeNodeSummary<AXUIElement> {
        try prepare(node, timeout: remaining())
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(node, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let items = values as? [AnyObject], items.count == 3,
              let role = items[0] as? String else {
            throw DialogProbeReadError.unavailable
        }
        let subrole: String?
        if try Self.isAbsent(items[1]) { subrole = nil }
        else if let string = items[1] as? String { subrole = string }
        else { throw DialogProbeReadError.unavailable }
        if role == "AXWebArea" || BoundedDialogProbe.isNativeModal(role: role, subrole: subrole) {
            return .init(role: role, subrole: subrole, children: [])
        }
        if try Self.isAbsent(items[2]) { return .init(role: role, subrole: subrole, children: []) }
        guard let list = items[2] as? [AnyObject],
              list.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
            throw DialogProbeReadError.unavailable
        }
        return .init(role: role, subrole: subrole, children: list.map { $0 as! AXUIElement }) // type IDs validated above
    }

    /// For a slot of a multiple-attribute read: true when the attribute is
    /// unsupported or has no value, false when the slot holds a value; throws
    /// for any other AXError.
    private static func isAbsent(_ item: AnyObject) throws -> Bool {
        guard CFGetTypeID(item) == AXValueGetTypeID() else { return false }
        let value = item as! AXValue // type ID checked above
        guard AXValueGetType(value) == .axError else { return false }
        var error = AXError.success
        guard AXValueGetValue(value, .axError, &error) else { throw DialogProbeReadError.unavailable }
        if error == .attributeUnsupported || error == .noValue { return true }
        throw DialogProbeReadError.unavailable
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
