import Foundation
import XCTest
@testable import SafariBrowser

final class BoundedDialogProbeTests: XCTestCase {
    private struct Node: Sendable {
        var role = "AXGroup"
        var subrole: String?
        var children: [Int] = []
        var windowID = 0
        var text: String?
        var title: String?
        var roleDelay: TimeInterval = 0
        var valueSettable: Bool? = false
        var roleFails = false
    }

    private enum Operation: String, CaseIterable, Sendable {
        case windows, windowID, role, subrole, children, text, buttonTitle, valueSettable, summary
    }

    private final class Calls: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var recorded: [(Operation, Float)] = []
        private var factories = 0
        private var valueReads: [Int] = []
        let blocked: Operation?
        let failed: Operation?

        init(blocked: Operation? = nil, failed: Operation? = nil) {
            self.blocked = blocked
            self.failed = failed
        }
        func factory() -> Int {
            lock.lock(); defer { lock.unlock() }
            factories += 1
            return factories
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return factories }
        func recordValueRead(_ node: Int) { lock.lock(); valueReads.append(node); lock.unlock() }
        var nodesRead: [Int] { lock.lock(); defer { lock.unlock() }; return valueReads }
        var operations: [Operation] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.0) }
        var timeouts: [Float] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.1) }
        func touch(_ operation: Operation, timeout: Float) throws {
            lock.lock(); recorded.append((operation, timeout)); lock.unlock()
            if blocked == operation {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            if failed == operation { throw DialogProbeReadError.unavailable }
        }
    }

    private struct Provider: DialogProbeProvider {
        let nodes: [Int: Node]
        let roots: [Int]
        let calls: Calls
        var denied = false
        /// Answers `summary` in one recorded call, like the AX provider.
        var batched = false
        func windows(timeout: Float) throws -> [Int] {
            try calls.touch(.windows, timeout: timeout)
            if denied { throw DialogProbeReadError.accessibilityDenied }
            return roots
        }
        func windowID(_ node: Int, timeout: Float) throws -> Int {
            try calls.touch(.windowID, timeout: timeout); return nodes[node]!.windowID
        }
        func role(_ node: Int, timeout: Float) throws -> String {
            try calls.touch(.role, timeout: timeout)
            if nodes[node]!.roleDelay > 0 { Thread.sleep(forTimeInterval: nodes[node]!.roleDelay) }
            if nodes[node]!.roleFails { throw DialogProbeReadError.unavailable }
            return nodes[node]!.role
        }
        func subrole(_ node: Int, timeout: Float) throws -> String? {
            try calls.touch(.subrole, timeout: timeout); return nodes[node]!.subrole
        }
        func children(_ node: Int, timeout: Float) throws -> [Int] {
            try calls.touch(.children, timeout: timeout); return nodes[node]!.children
        }
        func text(_ node: Int, timeout: Float) throws -> String? {
            calls.recordValueRead(node)
            try calls.touch(.text, timeout: timeout); return nodes[node]!.text
        }
        func valueIsSettable(_ node: Int, timeout: Float) throws -> Bool? {
            try calls.touch(.valueSettable, timeout: timeout); return nodes[node]!.valueSettable
        }
        func buttonTitle(_ node: Int, timeout: Float) throws -> String? {
            try calls.touch(.buttonTitle, timeout: timeout); return nodes[node]!.title
        }
        func summary(_ node: Int, remaining: () throws -> Float) throws -> DialogProbeNodeSummary<Int> {
            guard batched else { return try composedSummary(node, remaining: remaining) }
            try calls.touch(.summary, timeout: remaining())
            let n = nodes[node]!
            if n.roleFails { throw DialogProbeReadError.unavailable }
            return .init(role: n.role, subrole: n.subrole, children: n.children)
        }
    }

    private static let dialogTree: [Int: Node] = [
        1: Node(role: "AXWindow", children: [2], windowID: 42),
        2: Node(children: [3]),
        3: Node(children: [4]),
        4: Node(subrole: "AXDialog", children: [5, 6]),
        5: Node(role: "AXStaticText", text: "這是訊息"),
        6: Node(role: "AXButton", title: "確定"),
        7: Node(role: "AXWindow", windowID: 99),
    ]

    private func makeProbe(
        calls: Calls = Calls(), roots: [Int] = [1],
        nodes: [Int: Node] = dialogTree, maxDepth: Int = 5, maxNodes: Int = 128, batched: Bool = false
    ) -> BoundedDialogProbe {
        BoundedDialogProbe(maxDepth: maxDepth, maxNodes: maxNodes) {
            _ = calls.factory()
            return Provider(nodes: nodes, roots: roots, calls: calls, batched: batched)
        }
    }

    /// #187: the tree measured on macOS 27.2 Safari. The page sits in a scroll
    /// area at depth 5, beside a scroll bar that has children of its own.
    private static let measuredTree: [Int: Node] = [
        1: Node(role: "AXWindow", children: [2, 20, 30], windowID: 42),
        2: Node(role: "AXSplitGroup", children: [3, 4]),
        3: Node(role: "AXSplitter"),
        4: Node(role: "AXTabGroup", children: [5]),
        5: Node(children: [6]),
        6: Node(children: [7]),
        7: Node(role: "AXScrollArea", children: [8, 9]),
        8: Node(role: "AXWebArea", children: [10]),
        9: Node(role: "AXScrollBar", children: [11]),
        10: Node(role: "AXStaticText", text: "page"),
        11: Node(role: "AXValueIndicator"),
        20: Node(role: "AXToolbar", children: [21]),
        21: Node(role: "AXButton"),
        30: Node(role: "AXOpaqueProviderGroup", subrole: "AXOpaqueProviderList", children: [31]),
        31: Node(role: "AXRadioButton", subrole: "AXTabButton", children: [32, 33]),
        32: Node(role: "AXImage"),
        33: Node(role: "AXStaticText"),
    ]

    func testRecognizesDepthThreeDialogAndCollectsTextAndButtons() {
        let probe = makeProbe()
        XCTAssertEqual(probe.check(windowKey: .id(42)), .present(.init(message: "這是訊息", buttons: ["確定"])))
    }

    func testReadsSafariAlertBodyInsideScrollAreaWithoutPromptInputOrDuplicateGroupValue() {
        var nodes = Self.dialogTree
        nodes[4] = Node(subrole: "AXDialog", children: [5, 8, 6, 10], text: "actual body")
        nodes[5] = Node(role: "AXStaticText", text: "JavaScript")
        nodes[8] = Node(role: "AXScrollArea", children: [9])
        nodes[9] = Node(role: "AXTextArea", text: "actual body")
        nodes[10] = Node(role: "AXTextField", text: "private prompt answer")
        let calls = Calls()
        XCTAssertEqual(makeProbe(calls: calls, nodes: nodes).check(windowKey: .id(42)),
                       .present(.init(message: "JavaScript actual body", buttons: ["確定"])))
        XCTAssertEqual(calls.nodesRead, [5, 9], "prompt and mirrored group values must not be read")
    }

    func testTextAreaMustBeConfirmedReadOnlyBeforeItsValueIsCollected() {
        for editable: Bool? in [true, nil] {
            var nodes = Self.dialogTree
            nodes[4] = Node(subrole: "AXDialog", children: [5, 6, 8])
            nodes[8] = Node(role: "AXTextArea", text: "private multiline answer", valueSettable: editable)
            let calls = Calls()
            XCTAssertEqual(makeProbe(calls: calls, nodes: nodes).check(windowKey: .id(42)),
                           .present(.init(message: "這是訊息", buttons: ["確定"])))
            XCTAssertEqual(calls.nodesRead, [5], "excluded input must not receive a value read")
        }
    }

    func testFailedEditableAttributeSkipsValueWithoutHidingDialog() {
        var nodes = Self.dialogTree
        nodes[4] = Node(subrole: "AXDialog", children: [5, 6, 8])
        nodes[8] = Node(role: "AXTextArea", text: "unverified value")
        let calls = Calls(failed: .valueSettable)
        XCTAssertEqual(makeProbe(calls: calls, nodes: nodes).check(windowKey: .id(42)),
                       .present(.init(message: "這是訊息", buttons: ["確定"])))
        XCTAssertEqual(calls.nodesRead, [5])
    }

    func testWebAreaInsideDialogDoesNotContributeMessageValues() {
        var nodes = Self.dialogTree
        nodes[4] = Node(subrole: "AXDialog", children: [5, 6, 8])
        nodes[8] = Node(role: "AXWebArea", children: [9])
        nodes[9] = Node(role: "AXTextArea", text: "page content")
        let calls = Calls()
        XCTAssertEqual(makeProbe(calls: calls, nodes: nodes).check(windowKey: .id(42)),
                       .present(.init(message: "這是訊息", buttons: ["確定"])))
        XCTAssertEqual(calls.nodesRead, [5])
    }

    func testDialogPathIsNotStarvedByLargeSiblingTabStrip() {
        var nodes = Self.dialogTree
        nodes[1] = Node(role: "AXWindow", children: [2, 8], windowID: 42)
        nodes[8] = Node(role: "AXOpaqueProviderGroup", children: Array(100..<150))
        for id in 100..<150 { nodes[id] = Node(role: "AXRadioButton", roleDelay: 0.001) }
        let probe = makeProbe(nodes: nodes)
        guard case .present = probe.check(windowKey: .id(42)) else {
            return XCTFail("the modal path precedes a 50-tab strip and must be inspected before it")
        }
    }

    func testWebContentDialogDoesNotCountAsNativeBlockingDialog() {
        let nodes = [1: Node(role: "AXWindow", children: [2], windowID: 42),
                     2: Node(role: "AXWebArea", children: [3]),
                     3: Node(subrole: "AXDialog", children: [4]),
                     4: Node(role: "AXButton", title: "web button")]
        XCTAssertEqual(makeProbe(nodes: nodes).check(windowKey: .id(42)), .clear)
    }

    func testCallerRemainingBudgetIsPassedToTheWorker() {
        let calls = Calls(blocked: .windows)
        defer { calls.release.signal() }
        let result = makeProbe(calls: calls).check(windowKey: .id(42), budget: 0.01)
        XCTAssertEqual(result, .unprobed)
        XCTAssertTrue(calls.timeouts.allSatisfy { $0 > 0 && $0 <= 0.01 })
    }

    func testStableIDIgnoresWindowOrderAndUnrelatedWindows() {
        let probe = makeProbe(roots: [7, 1])
        XCTAssertEqual(probe.check(windowKey: .id(99)), .clear)
        guard case .present = probe.check(windowKey: .id(42)) else {
            return XCTFail("window ID 42 must select the dialog window despite reversed ordering")
        }
    }

    func testInvalidOrPositionalKeysNeverSelectAnotherWindow() {
        let calls = Calls()
        let probe = makeProbe(calls: calls)
        for key: BlockingDialogGate.WindowKey in [.front, .index(1), .id(0), .id(-1)] {
            XCTAssertEqual(probe.check(windowKey: key), .unprobed)
        }
        XCTAssertEqual(calls.count, 4, "invalid identity only permits application/window-list inspection")
        XCTAssertEqual(probe.check(windowKey: .id(404)), .unprobed)
    }

    func testMissingTargetIdentityStillDistinguishesNoWindowsAndDeniedPermission() {
        XCTAssertEqual(makeProbe(roots: []).check(windowKey: .front), .clear)
        let calls = Calls()
        let denied = BoundedDialogProbe { Provider(nodes: [:], roots: [], calls: calls, denied: true) }
        XCTAssertEqual(denied.check(windowKey: .index(1)), .accessibilityDenied)
    }

    func testDialogRoleWithoutSubroleIsRecognized() {
        let probe = makeProbe(nodes: [1: Node(role: "AXWindow", children: [2], windowID: 42),
                                     2: Node(role: "AXDialog")])
        guard case .present = probe.check(windowKey: .id(42)) else { return XCTFail("dialog role was missed") }
    }

    func testEmptyWindowListIsClearButReadFailureIsUnknown() {
        XCTAssertEqual(makeProbe(roots: []).check(windowKey: .front), .clear)
        XCTAssertEqual(makeProbe(roots: []).check(windowKey: .id(42)), .unprobed,
                       "an empty AX list did not inspect the already-resolved window")
        XCTAssertEqual(makeProbe(calls: Calls(failed: .windows)).check(windowKey: .id(42)), .unprobed)
    }

    func testDeniedPermissionIsReportedDistinctly() {
        let calls = Calls()
        let probe = BoundedDialogProbe {
            Provider(nodes: [:], roots: [], calls: calls, denied: true)
        }
        XCTAssertEqual(probe.check(windowKey: .id(42)), .accessibilityDenied)
    }

    func testFailedIdentificationAndTraversalReadsNeverBecomeClear() {
        for operation in [Operation.windowID, .role, .subrole, .children] {
            let probe = makeProbe(calls: Calls(failed: operation))
            XCTAssertEqual(probe.check(windowKey: .id(42)), .unprobed, operation.rawValue)
        }
    }

    func testLockedSessionApplicationPlaceholdersAreUnknown() {
        let nodes = [1: Node(role: "AXApplication", windowID: 0)]
        XCTAssertEqual(makeProbe(roots: [1, 1, 1, 1], nodes: nodes).check(windowKey: .id(42)), .unprobed)
    }

    func testDepthAndNodeTruncationAreUnknownRatherThanClear() {
        XCTAssertEqual(makeProbe(maxDepth: 2).check(windowKey: .id(42)), .unprobed)
        XCTAssertEqual(makeProbe(maxNodes: 2).check(windowKey: .id(42)), .unprobed)
    }

    func testUnreadableDialogDetailsDoNotHideKnownDialog() {
        for operation in [Operation.text, .buttonTitle] {
            let probe = makeProbe(calls: Calls(failed: operation))
            guard case .present = probe.check(windowKey: .id(42)) else {
                XCTFail("failed \(operation) must preserve the confirmed dialog"); continue
            }
        }
    }

    func testEveryBlockingProviderPhaseHasABoundedCallerWaitAndNoQueue() {
        for operation in Operation.allCases {
            let calls = Calls(blocked: operation)
            var nodes = Self.dialogTree
            if operation == .valueSettable {
                nodes[5] = Node(role: "AXTextArea", text: "這是訊息")
            }
            // The batched provider is the one that makes the one-round-trip read.
            let probe = makeProbe(calls: calls, nodes: nodes, batched: operation == .summary)
            let started = Date()
            XCTAssertEqual(probe.check(windowKey: .id(42)), .unprobed, operation.rawValue)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.3, "scheduler tolerance for \(operation)")
            XCTAssertEqual(calls.entered.wait(timeout: .now() + 0.3), .success)
            let busyStarted = Date()
            XCTAssertEqual(probe.check(windowKey: .id(42)), .unprobed)
            XCTAssertLessThan(Date().timeIntervalSince(busyStarted), 0.03)
            XCTAssertEqual(calls.count, 1, "busy probe must not create or queue another provider")
            calls.release.signal()
        }
    }

    func testLateResultCannotBeReusedByNextRequest() {
        let blocked = Calls(blocked: .windows)
        let clear = Calls()
        let probe = BoundedDialogProbe {
            let invocation = blocked.factory()
            return Provider(
                nodes: Self.dialogTree, roots: invocation == 1 ? [1] : [7],
                calls: invocation == 1 ? blocked : clear)
        }
        XCTAssertEqual(probe.check(windowKey: .id(42)), .unprobed)
        blocked.release.signal()
        let deadline = Date().addingTimeInterval(0.5)
        var state = BlockingDialogState.unprobed
        repeat {
            Thread.sleep(forTimeInterval: 0.002)
            state = probe.check(windowKey: .id(99))
        } while state == .unprobed && Date() < deadline
        XCTAssertEqual(state, .clear, "late dialog result must not leak into the next call")
        XCTAssertEqual(blocked.count, 2)
    }

    func testEachProviderCallReceivesRemainingBudget() {
        let calls = Calls()
        var nodes = Self.dialogTree
        nodes[5] = Node(role: "AXTextArea", text: "body")
        _ = makeProbe(calls: calls, nodes: nodes).check(windowKey: .id(42))
        XCTAssertTrue(calls.operations.contains(.valueSettable))
        let timeouts = calls.timeouts
        XCTAssertGreaterThan(timeouts.count, 8)
        XCTAssertTrue(timeouts.allSatisfy { $0 > 0 && $0 <= 0.1 })
        XCTAssertTrue(zip(timeouts, timeouts.dropFirst()).allSatisfy { $0 >= $1 })
    }

    // MARK: - #187 page viewport and one round trip per node

    func testPageViewportAtTheDepthLimitIsALeafNotATruncation() {
        // Every ordinary window reported `unprobed`: the scroll area holding
        // the page sits exactly at maxDepth and still has children.
        XCTAssertEqual(makeProbe(nodes: Self.measuredTree).check(windowKey: .id(42)), .clear)
        XCTAssertEqual(makeProbe(nodes: Self.measuredTree, batched: true).check(windowKey: .id(42)), .clear)
    }

    func testViewportIsRecognisedWhateverTheOrderOfItsChildren() {
        var nodes = Self.measuredTree
        nodes[7] = Node(role: "AXScrollArea", children: [9, 8])
        XCTAssertEqual(makeProbe(nodes: nodes).check(windowKey: .id(42)), .clear)
    }

    func testNativeDialogBesideThePageViewportIsStillFound() {
        var nodes = Self.measuredTree
        nodes[4] = Node(role: "AXTabGroup", children: [5, 50])
        nodes[50] = Node(subrole: "AXDialog", children: [51, 52])
        nodes[51] = Node(role: "AXStaticText", text: "Leave page?")
        nodes[52] = Node(role: "AXButton", title: "OK")
        for batched in [false, true] {
            XCTAssertEqual(makeProbe(nodes: nodes, batched: batched).check(windowKey: .id(42)),
                           .present(.init(message: "Leave page?", buttons: ["OK"])))
        }
    }

    func testScrollAreaThatDoesNotHostThePageStillCountsAsTruncated() {
        // Only the page viewport is a leaf. Any other node at the depth limit
        // with children remains an honest truncation.
        var nodes = Self.measuredTree
        nodes[8] = Node(role: "AXGroup", children: [10])
        XCTAssertEqual(makeProbe(nodes: nodes).check(windowKey: .id(42)), .unprobed)
    }

    func testUnreadableViewportChildIsIncompleteNotClear() {
        var nodes = Self.measuredTree
        nodes[8] = Node(role: "AXWebArea", children: [10], roleFails: true)
        XCTAssertEqual(makeProbe(nodes: nodes).check(windowKey: .id(42)), .unprobed)
    }

    func testTraversalReadsEachNodeInOneRoundTrip() {
        // Three single-attribute reads per node left the first probe of a
        // process a few milliseconds inside its 95 ms budget on a real window.
        let calls = Calls()
        XCTAssertEqual(makeProbe(calls: calls, nodes: Self.measuredTree, batched: true).check(windowKey: .id(42)), .clear)
        let ops = calls.operations
        XCTAssertEqual(ops.filter { $0 == .summary }.count, 13, "one summary per visited node: \(ops)")
        XCTAssertFalse(ops.contains(.subrole) || ops.contains(.children), "no per-attribute reads while traversing: \(ops)")
        XCTAssertEqual(ops.filter { $0 == .role }.count, 1, "only the viewport check reads a child role: \(ops)")
    }
}
