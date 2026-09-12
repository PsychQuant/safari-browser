import Foundation
import XCTest

@testable import SafariBrowser

final class DialogTreeScannerTests: XCTestCase {
    struct Node: Sendable {
        var role = "AXGroup"
        var subrole: String?
        var children: [Int] = []
        var id = 0
        var text: String?
        var title: String?
        var editable: Bool? = false
    }
    struct Provider: DialogProbeProvider {
        var roots: [Int] = [1]
        var nodes: [Int: DialogTreeScannerTests.Node] = [1: .init(role: "AXWindow", id: 42)]
        var fail: String?
        var deny = false
        var delayedOperation: String?
        var delay: TimeInterval = 0
        func check(_ op: String) throws {
            if delayedOperation == op { Thread.sleep(forTimeInterval: delay) }
            if fail == op { throw DialogProbeReadError.unavailable }
        }
        func windows(timeout: Float) throws -> [Int] {
            if deny { throw DialogProbeReadError.accessibilityDenied }
            try check("windows")
            return roots
        }
        func windowID(_ node: Int, timeout: Float) throws -> Int {
            try check("id")
            return nodes[node]!.id
        }
        func role(_ node: Int, timeout: Float) throws -> String {
            try check("role")
            return nodes[node]!.role
        }
        func subrole(_ node: Int, timeout: Float) throws -> String? {
            try check("subrole")
            return nodes[node]!.subrole
        }
        func children(_ node: Int, timeout: Float) throws -> [Int] {
            try check("children")
            return nodes[node]!.children
        }
        func valueIsSettable(_ node: Int, timeout: Float) throws -> Bool? {
            try check("editable")
            return nodes[node]!.editable
        }
        func text(_ node: Int, timeout: Float) throws -> String? {
            try check("text")
            return nodes[node]!.text
        }
        func buttonTitle(_ node: Int, timeout: Float) throws -> String? {
            try check("title")
            return nodes[node]!.title
        }
    }
    static var dialog: Provider {
        Provider(nodes: [
            1: Node(role: "AXWindow", children: [2], id: 42),
            2: Node(subrole: "AXDialog", children: [3, 4, 6, 7]),
            3: Node(role: "AXStaticText", text: "Source"),
            4: Node(role: "AXScrollArea", children: [5]),
            5: Node(role: "AXTextArea", text: "Body"),
            6: Node(role: "AXButton", title: "Cancel"),
            7: Node(role: "AXButton", title: "Continue"),
        ])
    }
    func scan(_ provider: Provider, _ scanner: DialogTreeScanner<Provider> = .init()) -> DialogTreeSnapshot<Int> {
        scanner.scan(provider: provider, deadline: .now() + 0.7)
    }
    func testFifteenClearWindowsAreCompletelyInspected() {
        let p = Provider(
            roots: Array(1...15),
            nodes: Dictionary(uniqueKeysWithValues: (1...15).map { ($0, Node(role: "AXWindow", id: $0)) }))
        let start = Date()
        let result = scan(p)
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
    func testDialogTextAndButtonElementsShareOneOrderedSnapshot() {
        let result = scan(Self.dialog)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.candidates.count, 1)
        guard let found = result.candidates.first else { return }
        XCTAssertEqual(found.windowID, 42)
        XCTAssertEqual(found.dialog, .init(message: "Source Body", buttons: ["Cancel", "Continue"]))
        XCTAssertEqual(found.buttons.map(\.element), [6, 7])
        XCTAssertEqual(found.buttons.map(\.title), found.dialog.buttons)
    }
    func testEveryFailedReadPreventsACompleteSingleCandidate() {
        for op in ["windows", "id", "role", "subrole", "children", "editable", "text", "title"] {
            var p = Self.dialog
            p.fail = op
            XCTAssertFalse(scan(p).isComplete, op)
        }
    }
    func testWindowAndTraversalLimitsNeverProveAbsence() {
        var p = Provider()
        p.roots = [1, 8]
        p.nodes[8] = Node(role: "AXWindow", id: 99)
        XCTAssertFalse(scan(p, .init(maxWindows: 1)).isComplete)
        XCTAssertFalse(scan(Self.dialog, .init(maxNodes: 1)).isComplete)
        XCTAssertFalse(scan(Self.dialog, .init(maxDepth: 0)).isComplete)
        XCTAssertFalse(scan(Self.dialog, .init(maxDetailNodes: 1)).isComplete)
        XCTAssertFalse(scan(Self.dialog, .init(maxDetailDepth: 0)).isComplete)
    }
    func testInvalidDuplicateOrNonWindowRootsAreIncomplete() {
        for id in [0, -1] { XCTAssertFalse(scan(Provider(nodes: [1: Node(role: "AXWindow", id: id)])).isComplete) }
        XCTAssertFalse(scan(Provider(roots: [1, 1])).isComplete)
        XCTAssertFalse(scan(Provider(nodes: [1: Node(role: "AXApplication", id: 42)])).isComplete)
    }
    func testNativeDialogInSecondWindowAndMultipleCandidates() {
        var p = Self.dialog
        p.roots = [8, 1]
        p.nodes[8] = Node(role: "AXWindow", children: [9], id: 99)
        p.nodes[9] = Node(subrole: "AXDialog")
        let result = scan(p)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.candidates.map(\.windowID), [99, 42])
    }
    func testWebAreaDialogsAreExcludedFromDiscoveryAndDetails() {
        var p = Provider(nodes: [
            1: Node(role: "AXWindow", children: [2], id: 42), 2: Node(role: "AXWebArea", children: [3]),
            3: Node(subrole: "AXDialog"),
        ])
        XCTAssertTrue(scan(p).isComplete)
        XCTAssertTrue(scan(p).candidates.isEmpty)
        p = Self.dialog
        p.nodes[2]!.children.append(8)
        p.nodes[8] = Node(role: "AXWebArea", children: [9])
        p.nodes[9] = Node(role: "AXStaticText", text: "Page text")
        let result = scan(p)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.candidates.first?.dialog.message, "Source Body")
    }
    func testAbsentOptionalTextAndUnnamedButtonsDoNotShiftNamedButtonElements() {
        var p = Self.dialog
        p.nodes[3]!.text = nil
        p.nodes[2]!.children.insert(8, at: 3)
        p.nodes[8] = Node(role: "AXButton", title: "")
        let result = scan(p)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.candidates.first?.dialog.message, "Body")
        XCTAssertEqual(result.candidates.first?.dialog.buttons, ["Cancel", "Continue"])
        XCTAssertEqual(result.candidates.first?.buttons.map(\.element), [6, 7])
    }

    func testNestedNativeDialogIsRetainedAsAnAmbiguousCandidate() {
        var p = Self.dialog
        p.nodes[4]!.subrole = "AXDialog"
        let result = scan(p)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.scanResult, .many(messages: ["Source", ""]))
        XCTAssertEqual(result.candidates.first?.buttons.map(\.element), [6, 7])
        let press = DialogPressExecutor.perform(
            snapshot: result, deadline: .now() + 0.7, session: .init { [:] },
            decide: { _ in
                XCTFail("ambiguous candidates must not decide")
                return 0
            },
            press: { _, _ in
                XCTFail("ambiguous candidates must not press")
                return .pressed
            })
        XCTAssertEqual(press, .ambiguous(messages: ["Source", ""]))
    }

    func testRootModalSubroleIsDetectedInsteadOfReportedClear() {
        for subrole in ["AXDialog", "AXSystemDialog"] {
            let p = Provider(nodes: [
                1: Node(role: "AXWindow", subrole: subrole, children: [3], id: 42),
                3: Node(role: "AXStaticText", text: "App modal"),
            ])
            XCTAssertEqual(scan(p).scanResult, .one(.init(message: "App modal", buttons: [])))
        }
    }

    func testRepeatedNodesAndCyclesRemainUnknownWithoutInventingExtraCandidates() {
        var p = Self.dialog
        p.nodes[1]!.children.append(2)
        let repeated = scan(p)
        XCTAssertFalse(repeated.isComplete)
        XCTAssertEqual(repeated.candidates.count, 1)
        p = Self.dialog
        p.nodes[2]!.children.append(2)
        let cycle = scan(p)
        XCTAssertFalse(cycle.isComplete)
        XCTAssertEqual(cycle.candidates.count, 1)
    }

    func testExpiredDeadlineAndUnknownMessageMetadataAreIncomplete() {
        XCTAssertFalse(DialogTreeScanner<Provider>().scan(provider: Self.dialog, deadline: .now() - 1).isComplete)
        var p = Self.dialog
        p.nodes[5]!.editable = nil
        XCTAssertFalse(scan(p).isComplete)
    }
}
