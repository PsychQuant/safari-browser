import Foundation
import XCTest
@testable import SafariBrowser

final class ScopedDialogInspectionTests: XCTestCase {
    typealias Provider = DialogTreeScannerTests.Provider
    typealias Node = DialogTreeScannerTests.Node

    private func twoWindows() -> Provider {
        var p = DialogTreeScannerTests.dialog
        p.roots = [8, 1]
        p.nodes[8] = Node(role: "AXWindow", children: [9], id: 99)
        p.nodes[9] = Node(role: "AXGroup")
        return p
    }

    private func scan(_ p: Provider, id: Int? = 42,
                      scanner: DialogTreeScanner<Provider> = .init(), budget: TimeInterval = 0.7) -> DialogTreeSnapshot<Int> {
        scanner.scan(provider: p, deadline: .now() + budget, targetWindowID: id)
    }

    func testUnrelatedUnreadableWindowDoesNotBlockExplicitTarget() {
        var p = twoWindows()
        p.unreadableNodes = [8, 9]
        XCTAssertEqual(scan(p, id: nil).scanResult, .inspectionIncomplete)
        let scoped = scan(p)
        XCTAssertEqual(scoped.scanResult, .one(.init(message: "Source Body", buttons: ["Cancel", "Continue"])))
        XCTAssertEqual(scoped.observedWindowIDs, [42])
        var elements: [Int] = []
        let outcome = DialogPressExecutor.perform(snapshot: scoped, deadline: .now() + 1,
            session: .init { [:] }, expectedWindowID: 42, decide: { _ in 1 },
            press: { element, _ in elements.append(element); return .pressed })
        XCTAssertEqual(outcome, .pressed)
        XCTAssertEqual(elements, [7])
    }

    func testUnrelatedSlowTreeCannotConsumeTargetBudget() {
        var p = twoWindows()
        p.slowNodes = [8]
        XCTAssertEqual(scan(p, id: nil, budget: 0.03).scanResult, .inspectionIncomplete)
        XCTAssertEqual(scan(p, budget: 0.03).candidates.first?.windowID, 42)
        XCTAssertTrue(scan(p, budget: 0.03).isComplete)
    }

    func testOtherWindowAXDialogRemainsAmbiguousGloballyButNotInExplicitScope() {
        var p = twoWindows()
        p.nodes[8]!.subrole = "AXDialog"
        XCTAssertEqual(scan(p, id: nil).candidates.count, 2)
        XCTAssertEqual(scan(p).candidates.map(\.windowID), [42])
        XCTAssertTrue(scan(p).isComplete)
        // The suspect root is not heuristically declared harmless. Explicitly
        // selecting it reports its own candidate, never window 42's buttons.
        XCTAssertEqual(scan(p, id: 99).scanResult, .one(.init(message: "", buttons: [])))
    }

    func testWindowOrderNeverChangesStableSelection() {
        var p = twoWindows()
        for roots in [[8, 1], [1, 8]] {
            p.roots = roots
            XCTAssertEqual(scan(p).candidates.map(\.windowID), [42])
        }
    }

    func testBoundedProbeCarriesOnlyCompleteUniqueIdentityAcrossWorkerBoundary() {
        var p = twoWindows()
        p.unreadableNodes = [8]
        let provider = p
        let probe = GlobalDialogProbe { provider }
        XCTAssertEqual(probe.observe().scanResult, .inspectionIncomplete)
        XCTAssertNil(probe.observe().singleDialogWindowID)
        let scoped = probe.observe(windowID: 42)
        XCTAssertEqual(scoped.singleDialogWindowID, 42)
        XCTAssertEqual(scoped.scanResult, .one(.init(message: "Source Body", buttons: ["Cancel", "Continue"])))
        XCTAssertNil(probe.observe(windowID: 99).singleDialogWindowID)
        XCTAssertEqual(probe.scan(budget: 0, windowID: 42), .inspectionIncomplete)
    }

    func testMissingInvalidDuplicateAndUnreadableIdentitiesFailClosed() {
        let p = twoWindows()
        for id in [0, -1, 8, 777] { XCTAssertEqual(scan(p, id: id).scanResult, .inspectionIncomplete) }
        var duplicate = p
        duplicate.nodes[8]!.id = 42
        XCTAssertEqual(scan(duplicate).scanResult, .inspectionIncomplete)
        var unknown = p
        unknown.nodes[8]!.id = 0
        XCTAssertEqual(scan(unknown).scanResult, .inspectionIncomplete)
        unknown.fail = "id"
        XCTAssertEqual(scan(unknown).scanResult, .inspectionIncomplete)
        XCTAssertEqual(scan(p, scanner: .init(maxWindows: 1)).scanResult, .inspectionIncomplete)
    }

    func testIncompleteTargetAndBudgetLimitsNeverDecideOrPress() {
        var unreadable = twoWindows()
        unreadable.unreadableNodes = [5]
        let p = twoWindows()
        for snapshot in [scan(unreadable), scan(p, scanner: .init(maxNodes: 1)),
                         scan(p, scanner: .init(maxDepth: 0)), scan(p, scanner: .init(maxDetailNodes: 1)),
                         scan(p, scanner: .init(maxDetailDepth: 0)), scan(p, budget: -1)] {
            XCTAssertEqual(snapshot.scanResult, .inspectionIncomplete)
            let result = DialogPressExecutor.perform(snapshot: snapshot, deadline: .now() + 1,
                session: .init { [:] }, expectedWindowID: 42,
                decide: { _ in XCTFail("incomplete target must not decide"); return 0 },
                press: { _, _ in XCTFail("incomplete target must not press"); return .pressed })
            XCTAssertEqual(result, .inspectionIncomplete)
        }
    }

    func testTwoDialogsWithinTargetRemainAmbiguous() {
        var p = twoWindows()
        p.nodes[1]!.children.append(10)
        p.nodes[10] = Node(role: "AXSheet")
        XCTAssertEqual(scan(p).scanResult, .many(messages: ["Source Body", ""]))
        p = twoWindows()
        p.nodes[4]!.subrole = "AXDialog"
        XCTAssertEqual(scan(p).scanResult, .many(messages: ["Source", ""]))
    }

    func testWebContentCannotSupplyNativeConfirmationButtons() {
        var p = twoWindows()
        p.nodes[2]!.role = "AXWebArea"
        XCTAssertEqual(scan(p).scanResult, .none)
        XCTAssertTrue(scan(p).candidates.isEmpty)
    }

    func testAnotherWindowWithIdenticalTextCannotReceivePress() {
        let original = scan(twoWindows())
        var replacement = DialogTreeScannerTests.dialog
        replacement.nodes[1]!.id = 99
        let current = scan(replacement, id: nil)
        let result = DialogPressExecutor.perform(snapshot: current, deadline: .now() + 1,
            session: .init { [:] }, expectedWindowID: original.candidates.first!.windowID,
            decide: { _ in XCTFail("wrong window must not decide"); return 0 },
            press: { _, _ in XCTFail("wrong window must not press"); return .pressed })
        XCTAssertEqual(result, .refused(current: .init(message: "Source Body", buttons: ["Cancel", "Continue"])))
    }

    /// A provider is confined to one scanner invocation, as are native AX nodes.
    private final class ChangingIdentity: DialogProbeProvider, @unchecked Sendable {
        let base = DialogTreeScannerTests.dialog
        var idReads = 0
        func windows(timeout: Float) throws -> [Int] { try base.windows(timeout: timeout) }
        func windowID(_ node: Int, timeout: Float) throws -> Int {
            idReads += 1
            return idReads == 1 ? 42 : 99
        }
        func role(_ node: Int, timeout: Float) throws -> String { try base.role(node, timeout: timeout) }
        func subrole(_ node: Int, timeout: Float) throws -> String? { try base.subrole(node, timeout: timeout) }
        func children(_ node: Int, timeout: Float) throws -> [Int] { try base.children(node, timeout: timeout) }
        func valueIsSettable(_ node: Int, timeout: Float) throws -> Bool? { try base.valueIsSettable(node, timeout: timeout) }
        func text(_ node: Int, timeout: Float) throws -> String? { try base.text(node, timeout: timeout) }
        func buttonTitle(_ node: Int, timeout: Float) throws -> String? { try base.buttonTitle(node, timeout: timeout) }
    }

    func testTargetIdentityChangeDuringTraversalCannotAuthorizePress() {
        let snapshot = DialogTreeScanner<ChangingIdentity>().scan(
            provider: ChangingIdentity(), deadline: .now() + 1, targetWindowID: 42)
        XCTAssertEqual(snapshot.scanResult, .inspectionIncomplete)
        XCTAssertEqual(DialogPressExecutor.perform(snapshot: snapshot, deadline: .now() + 1,
            session: .init { [:] }, expectedWindowID: 42,
            decide: { _ in XCTFail("identity changed"); return 0 },
            press: { _, _ in XCTFail("identity changed"); return .pressed }), .inspectionIncomplete)
    }
}
