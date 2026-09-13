import Foundation
import XCTest
@testable import SafariBrowser

final class CurrentWindowDialogProbeTests: XCTestCase {
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }
    struct Provider: CurrentWindowDialogProvider {
        var base = DialogTreeScannerTests.Provider()
        var first = 1
        var second = 1
        var allowsClear = true
        var secondAllowsClear = true
        var contextFailure: DialogProbeReadError?
        var contextDelay: TimeInterval = 0
        let reads = Reads()
        func currentWindow(deadline: DispatchTime) throws -> CurrentDialogWindow<Int> {
            if contextDelay > 0 { Thread.sleep(forTimeInterval: contextDelay) }
            if let contextFailure { throw contextFailure }
            let initial = reads.next() == 1
            return .init(element: initial ? first : second, allowsClear: initial ? allowsClear : secondAllowsClear)
        }
        func windows(timeout: Float) throws -> [Int] { XCTFail("must not enumerate other windows"); return [] }
        func windowID(_ n: Int, timeout: Float) throws -> Int { try base.windowID(n, timeout: timeout) }
        func role(_ n: Int, timeout: Float) throws -> String { try base.role(n, timeout: timeout) }
        func subrole(_ n: Int, timeout: Float) throws -> String? { try base.subrole(n, timeout: timeout) }
        func children(_ n: Int, timeout: Float) throws -> [Int] { try base.children(n, timeout: timeout) }
        func valueIsSettable(_ n: Int, timeout: Float) throws -> Bool? { try base.valueIsSettable(n, timeout: timeout) }
        func text(_ n: Int, timeout: Float) throws -> String? { try base.text(n, timeout: timeout) }
        func buttonTitle(_ n: Int, timeout: Float) throws -> String? { try base.buttonTitle(n, timeout: timeout) }
    }
    static var available: GUISession { .init { [:] } }
    func observe(_ provider: Provider, budget: Double = 0.8) -> WindowDialogStatus {
        CurrentWindowDialogProbe { provider }.observe(budget: budget, session: Self.available)
    }
    func testCurrentWindowClearAndPresent() {
        XCTAssertEqual(observe(.init()).state, .clear)
        let dialog = observe(.init(base: DialogTreeScannerTests.dialog))
        XCTAssertEqual(dialog.state, .present)
        XCTAssertEqual(dialog.windowID, 42)
        XCTAssertEqual(dialog.messages, ["Source Body"])
    }
    func testOtherWindowDialogCannotContaminateCurrentClear() {
        var p = Provider(base: DialogTreeScannerTests.dialog, first: 9, second: 9)
        p.base.nodes[9] = .init(role: "AXWindow", id: 99)
        let result = observe(p)
        XCTAssertEqual(result.state, .clear)
        XCTAssertEqual(result.windowID, 99)
        XCTAssertTrue(result.messages.isEmpty)
    }
    func testIdentityChangeInvalidatesEvenPositiveObservation() {
        var p = Provider(base: DialogTreeScannerTests.dialog, second: 9)
        p.base.nodes[9] = .init(role: "AXWindow", id: 99)
        XCTAssertEqual(observe(p).state, .unknown)
    }
    func testInactiveOrHiddenAbsenceIsUnknownButObservedDialogIsPresent() {
        for (first, second) in [(false, true), (true, false), (false, false)] {
            XCTAssertEqual(observe(.init(allowsClear: first, secondAllowsClear: second)).state, .unknown)
            XCTAssertEqual(observe(.init(base: DialogTreeScannerTests.dialog, allowsClear: first, secondAllowsClear: second)).state, .present)
        }
    }
    func testReadFailuresAndIncompleteTreesCannotReturnFalse() {
        for op in ["id", "role", "subrole", "children", "editable", "text", "title"] {
            var p = Provider(base: DialogTreeScannerTests.dialog)
            p.base.fail = op
            XCTAssertEqual(observe(p).state, .unknown, op)
        }
        XCTAssertEqual(observe(.init(contextFailure: .accessibilityDenied)).reason, "denied")
        XCTAssertEqual(observe(.init(contextFailure: .unavailable)).state, .unknown)
        var p = Provider()
        p.base.nodes[1]?.children = [1]
        XCTAssertEqual(observe(p).state, .unknown)
    }
    func testWorkerContentionAndSlowIdentityReadsAreBounded() {
        let worker = BoundedAXWorker()
        let probe = CurrentWindowDialogProbe(worker: worker) { Provider() }
        worker.withExclusive(fallback: ()) {
            XCTAssertEqual(probe.observe(session: Self.available).state, .unknown)
        }
        let slow = CurrentWindowDialogProbe { Provider(contextDelay: 0.2) }
        let start = Date()
        XCTAssertEqual(slow.observe(budget: 0.02, session: Self.available).state, .unknown)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.15)
        XCTAssertEqual(slow.observe(session: Self.available).state, .unknown)
    }
    func testUnavailableSessionNeverReadsAX() {
        let probe = CurrentWindowDialogProbe { () -> Provider in XCTFail("session gate must precede AX"); return Provider() }
        XCTAssertEqual(probe.observe(session: .init { nil }).reason, "unavailable")
        XCTAssertEqual(probe.observe(session: .init { ["CGSSessionScreenIsLocked": true] }).reason, "locked")
    }
}
