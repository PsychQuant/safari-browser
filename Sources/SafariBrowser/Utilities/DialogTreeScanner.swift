import Foundation

struct CapturedDialog<Node> {
    let windowID: Int
    let element: Node
    let dialog: SafariBridge.BlockingDialog
    let buttons: [(element: Node, title: String)]
}
struct DialogTreeSnapshot<Node> {
    var candidates: [CapturedDialog<Node>] = []
    var observedWindowIDs: Set<Int> = []
    var isComplete = true
    var accessibilityDenied = false
}
struct DialogTreeScanner<P: DialogProbeProvider> {
    var maxWindows = 64
    var maxNodes = 512
    var maxDepth = 8
    var maxDetailNodes = 256
    var maxDetailDepth = 6
    func scan(provider: P, deadline: DispatchTime) -> DialogTreeSnapshot<P.Node> {
        var snapshot = DialogTreeSnapshot<P.Node>()
        do {
            let windows = try provider.windows(timeout: remaining(deadline))
            let limit = max(0, maxWindows)
            if windows.count > limit { snapshot.isComplete = false }
            var identifiers = Set<Int>()
            var visited = Set<P.Node>()
            for window in windows.prefix(limit) {
                do {
                    let id = try provider.windowID(window, timeout: remaining(deadline))
                    guard id > 0, identifiers.insert(id).inserted else {
                        snapshot.isComplete = false
                        continue
                    }
                    snapshot.observedWindowIDs.insert(id)
                    inspectWindow(
                        window, id: id, provider: provider, deadline: deadline,
                        snapshot: &snapshot, visited: &visited)
                } catch { snapshot.isComplete = false }
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds { snapshot.isComplete = false }
        } catch DialogProbeReadError.accessibilityDenied {
            snapshot.accessibilityDenied = true
            snapshot.isComplete = false
        } catch { snapshot.isComplete = false }
        return snapshot
    }

    private func remaining(_ deadline: DispatchTime) throws -> Float {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { throw DialogProbeReadError.unavailable }
        return min(0.04, Float(Double(deadline.uptimeNanoseconds - now) / 1_000_000_000))
    }

    private func isDialog(role: String, subrole: String?) -> Bool {
        role == "AXSheet" || role == "AXDialog" || subrole == "AXDialog" || subrole == "AXSystemDialog"
    }

    private func inspectWindow(
        _ window: P.Node, id: Int, provider: P, deadline: DispatchTime,
        snapshot: inout DialogTreeSnapshot<P.Node>, visited: inout Set<P.Node>
    ) {
        var pending: [(P.Node, Int)] = [(window, 0)]
        var inspected = 0
        while !pending.isEmpty && inspected < max(0, maxNodes) {
            let (node, depth) = pending.removeLast()
            inspected += 1
            guard visited.insert(node).inserted else {
                snapshot.isComplete = false
                continue
            }
            do {
                let role = try provider.role(node, timeout: remaining(deadline))
                if depth == 0 && role != "AXWindow" {
                    snapshot.isComplete = false
                    continue
                }
                if role == "AXWebArea" { continue }
                let subrole = try provider.subrole(node, timeout: remaining(deadline))
                if isDialog(role: role, subrole: subrole) {
                    let detail = details(node, id: id, provider: provider, deadline: deadline, visited: &visited)
                    for candidate in [detail.candidate] + detail.nested {
                        if snapshot.candidates.contains(where: { $0.element == candidate.element }) {
                            snapshot.isComplete = false
                        } else {
                            snapshot.candidates.append(candidate)
                        }
                    }
                    snapshot.isComplete = snapshot.isComplete && detail.complete
                    continue
                }
                let children = try provider.children(node, timeout: remaining(deadline))
                if depth >= max(0, maxDepth) {
                    if !children.isEmpty { snapshot.isComplete = false }
                } else {
                    let room = max(0, maxNodes - inspected - pending.count)
                    if children.count > room { snapshot.isComplete = false }
                    pending.append(contentsOf: children.prefix(room).reversed().map { ($0, depth + 1) })
                }
            } catch { snapshot.isComplete = false }
        }
        if !pending.isEmpty { snapshot.isComplete = false }
    }

    private func details(
        _ element: P.Node, id: Int, provider: P, deadline: DispatchTime, visited: inout Set<P.Node>
    ) -> (candidate: CapturedDialog<P.Node>, nested: [CapturedDialog<P.Node>], complete: Bool) {
        var pending: [(P.Node, Int)] = [(element, 0)]
        var inspected = 0
        var complete = true
        var nested: [CapturedDialog<P.Node>] = []
        var messages: [String] = []
        var buttons: [(element: P.Node, title: String)] = []
        while !pending.isEmpty && inspected < max(0, maxDetailNodes) {
            let (node, depth) = pending.removeLast()
            inspected += 1
            // The depth-zero root was just entered by discovery. All other
            // nodes share the same identity history across both traversals and
            // every window, so a reused noncandidate cannot authorize a press.
            if depth > 0 && !visited.insert(node).inserted {
                complete = false
                continue
            }
            do {
                let role = try provider.role(node, timeout: remaining(deadline))
                if role == "AXWebArea" { continue }
                let subrole = try provider.subrole(node, timeout: remaining(deadline))
                // A second native dialog inside the candidate is a separate
                // decision. Do not mix its controls into an outer sheet.
                if depth > 0 && isDialog(role: role, subrole: subrole) {
                    complete = false
                    // Preserve the positively identified candidate. Its details
                    // are intentionally unread: ambiguity already forbids any
                    // press, and its controls must not enter the outer snapshot.
                    nested.append(
                        CapturedDialog(
                            windowID: id, element: node,
                            dialog: .init(message: "", buttons: []), buttons: []))
                    continue
                }
                if let message = try DialogMessageText.read(
                    node, role: role, provider: provider, remainingTimeout: { try remaining(deadline) }),
                    !message.isEmpty
                {
                    messages.append(message)
                }
                if role == "AXButton",
                    let title = try provider.buttonTitle(node, timeout: remaining(deadline)), !title.isEmpty
                {
                    buttons.append((node, title))
                }
                let children = try provider.children(node, timeout: remaining(deadline))
                if depth >= max(0, maxDetailDepth) {
                    if !children.isEmpty { complete = false }
                } else {
                    let room = max(0, maxDetailNodes - inspected - pending.count)
                    if children.count > room { complete = false }
                    pending.append(contentsOf: children.prefix(room).reversed().map { ($0, depth + 1) })
                }
            } catch { complete = false }
        }
        if !pending.isEmpty { complete = false }
        let dialog = SafariBridge.BlockingDialog(
            message: messages.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            buttons: buttons.map(\.title))
        return (CapturedDialog(windowID: id, element: element, dialog: dialog, buttons: buttons), nested, complete)
    }
}
