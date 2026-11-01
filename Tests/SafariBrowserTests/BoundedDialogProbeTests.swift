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
    }

    private enum Operation: String, CaseIterable, Sendable {
        case windows, windowID, role, subrole, children, text, buttonTitle, valueSettable
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
        nodes: [Int: Node] = dialogTree, maxDepth: Int = 5, maxNodes: Int = 128
    ) -> BoundedDialogProbe {
        BoundedDialogProbe(maxDepth: maxDepth, maxNodes: maxNodes) {
            _ = calls.factory()
            return Provider(nodes: nodes, roots: roots, calls: calls)
        }
    }

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

    // MARK: #328 — window chrome is never a JavaScript dialog

    private static let chromeContainers: [(name: String, node: Node)] = [
        ("toolbar", Node(role: "AXToolbar")),
        // Pins the order: chrome is decided before the dialog test.
        ("toolbar reporting a dialog subrole", Node(role: "AXToolbar", subrole: "AXDialog")),
        ("tab bar", Node(role: "AXOpaqueProviderGroup", subrole: "AXOpaqueProviderList")),
        ("tab button", Node(role: "AXRadioButton", subrole: "AXTabButton")),
    ]
    private static let dialogLikeNodes: [Node] = [
        Node(subrole: "AXDialog"), Node(role: "AXSheet"), Node(role: "AXDialog"), Node(subrole: "AXSystemDialog"),
    ]

    /// The reported false positive: the address field's controls and the page
    /// title, read as a dialog. Whatever exposed a dialog role there was window
    /// chrome; Safari puts JavaScript dialogs in the tab content.
    func testDialogLikeNodesInsideToolbarOrTabBarAreNotBlockingDialogs() {
        for (name, container) in Self.chromeContainers {
            for candidate in Self.dialogLikeNodes {
                var chrome = container
                chrome.children = [3]
                var dialogLike = candidate
                dialogLike.children = [4, 5]
                let nodes = [1: Node(role: "AXWindow", children: [2], windowID: 42),
                             2: chrome, 3: dialogLike,
                             4: Node(role: "AXStaticText", text: "Safari Browser Test Page"),
                             5: Node(role: "AXButton", title: "重新載入此網頁")]
                XCTAssertEqual(makeProbe(nodes: nodes).check(windowKey: .id(42)), .clear,
                               "\(candidate.role)/\(candidate.subrole ?? "-") inside the \(name)")
            }
        }
    }

    func testContentDialogAfterChromeIsFoundWithItsOwnText() {
        let nodes: [Int: Node] = [
            1: Node(role: "AXWindow", children: [10, 20, 2], windowID: 42),
            10: Node(role: "AXOpaqueProviderGroup", subrole: "AXOpaqueProviderList", children: [11]),
            11: Node(role: "AXRadioButton", subrole: "AXTabButton", children: [12]),
            12: Node(subrole: "AXDialog", children: [13]),
            13: Node(role: "AXStaticText", text: "Safari Browser Test Page"),
            20: Node(role: "AXToolbar", children: [21]),
            21: Node(subrole: "AXDialog", children: [22]),
            22: Node(role: "AXButton", title: "重新載入此網頁"),
            2: Node(role: "AXSplitGroup", children: [3]),
            3: Node(role: "AXTabGroup", children: [4]),
            4: Node(subrole: "AXDialog", children: [5, 6]),
            5: Node(role: "AXStaticText", text: "這是訊息"),
            6: Node(role: "AXButton", title: "確定"),
        ]
        XCTAssertEqual(makeProbe(nodes: nodes).check(windowKey: .id(42)),
                       .present(.init(message: "這是訊息", buttons: ["確定"])))
    }

    func testWindowLevelSheetBesideChromeIsStillFound() {
        let nodes: [Int: Node] = [
            1: Node(role: "AXWindow", children: [20, 30], windowID: 42),
            20: Node(role: "AXToolbar", children: [21]),
            21: Node(role: "AXButton", title: "重新載入此網頁"),
            30: Node(role: "AXSheet", children: [31, 32]),
            31: Node(role: "AXStaticText", text: "Save changes?"),
            32: Node(role: "AXButton", title: "Don't Save"),
        ]
        XCTAssertEqual(makeProbe(nodes: nodes).check(windowKey: .id(42)),
                       .present(.init(message: "Save changes?", buttons: ["Don't Save"])))
    }

    func testSkippedChromeDoesNotTurnATruncatedWalkIntoClear() {
        let nodes: [Int: Node] = [
            1: Node(role: "AXWindow", children: [20, 2], windowID: 42),
            20: Node(role: "AXToolbar", children: [21]),
            21: Node(role: "AXButton"),
            2: Node(children: [3]), 3: Node(children: [4]), 4: Node(children: [5]), 5: Node(),
        ]
        XCTAssertEqual(makeProbe(nodes: nodes, maxDepth: 2).check(windowKey: .id(42)), .unprobed)
    }

    /// A window with many tabs used to exhaust the node budget in the tab bar
    /// and report "could not inspect completely". The tab bar is not inspected,
    /// so the parts that can hold a dialog are read in full. The fixture's
    /// content path is shallow on purpose: on a real window the page's scroll
    /// area at depth 5 still makes the walk incomplete (#187).
    func testLargeTabBarNoLongerExhaustsTheNodeBudget() {
        var nodes: [Int: Node] = [
            1: Node(role: "AXWindow", children: [2, 8, 9], windowID: 42),
            2: Node(role: "AXSplitGroup", children: [3]),
            3: Node(role: "AXTabGroup", children: [4]),
            4: Node(),
            8: Node(role: "AXOpaqueProviderGroup", subrole: "AXOpaqueProviderList", children: Array(100..<240)),
            9: Node(role: "AXToolbar", children: [10]),
            10: Node(role: "AXButton"),
        ]
        for id in 100..<240 { nodes[id] = Node(role: "AXRadioButton", subrole: "AXTabButton") }
        XCTAssertEqual(makeProbe(nodes: nodes).check(windowKey: .id(42)), .clear)
    }

    func testPresentDialogCarriesARoleOnlyPathForDebugging() {
        guard case .present(let dialog) = makeProbe().check(windowKey: .id(42)) else {
            return XCTFail("the depth-three dialog must be found")
        }
        XCTAssertEqual(dialog.path, ["AXWindow", "AXGroup", "AXGroup", "AXGroup/AXDialog"])
        XCTAssertFalse(dialog.path.joined().contains("這是訊息"), "the path holds roles, never text")
    }

    func testPathIsDiagnosticAndNotPartOfDialogIdentity() {
        typealias Dialog = SafariBridge.BlockingDialog
        XCTAssertEqual(Dialog(message: "m", buttons: ["OK"], path: ["AXWindow", "AXSheet"]),
                       Dialog(message: "m", buttons: ["OK"]))
        XCTAssertNotEqual(Dialog(message: "m", buttons: ["OK"]), Dialog(message: "n", buttons: ["OK"]))
        XCTAssertNotEqual(Dialog(message: "m", buttons: ["OK"]), Dialog(message: "m", buttons: ["Cancel"]))
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
            let probe = makeProbe(calls: calls, nodes: nodes)
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
}
