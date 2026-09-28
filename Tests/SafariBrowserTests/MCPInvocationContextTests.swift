import Foundation
import XCTest
@testable import SafariBrowser

final class MCPInvocationContextTests: XCTestCase, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var output = ""
        func increment() { lock.withLock { value += 1 } }
        func append(_ text: String) { lock.withLock { output += text } }
        var count: Int { lock.withLock { value } }
        var text: String { lock.withLock { output } }
    }
    private actor Latch {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            let pending = waiters; waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    func testEachInvocationGetsNewProbeCacheWarningBudgetAndTraceIdentity() throws {
        let state = State()
        var traces: [PerformanceTrace.Summary] = []
        for _ in 0..<2 {
            let scope = MCPInvocationContext(probe: { _ in state.increment(); return .unprobed },
                stderr: { state.append($0) }, environment: ["SAFARI_BROWSER_TRACE_TIMING": "1"])
            MCPInvocationContext.$current.withValue(scope) {
                XCTAssertTrue(BlockingDialogGate.shared === scope.gate)
                if BlockingDialogGate.shared === scope.gate {
                    _ = BlockingDialogGate.shared.check(.id(172))
                    _ = BlockingDialogGate.shared.check(.id(172))
                }
            }
            if let collector = scope.timing {
                let span = collector.begin(.command)
                if let span { collector.end(span, outcome: .ok) }
                traces.append(try XCTUnwrap(collector.finish(status: .ok)))
            } else { XCTFail("Enabled trace must have a fresh collector") }
        }
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(state.text.components(separatedBy: "could not inspect").count - 1, 2)
        XCTAssertEqual(traces.count, 2)
        if traces.count == 2 { XCTAssertNotEqual(traces[0].requestID, traces[1].requestID) }
        XCTAssertNil(MCPInvocationContext.current)
        XCTAssertNil(MCPInvocationContext(environment: [:]).timing)
    }

    func testDaemonScopeStillTakesPrecedenceAndUnwindsToInvocation() {
        let scope = MCPInvocationContext(environment: [:])
        let daemon = DaemonRequestContext(environment: [:])
        let original = BlockingDialogGate.shared
        MCPInvocationContext.$current.withValue(scope) {
            XCTAssertTrue(BlockingDialogGate.shared === scope.gate)
            DaemonRequestContext.$current.withValue(daemon) {
                XCTAssertTrue(BlockingDialogGate.shared === daemon.gate)
            }
            XCTAssertTrue(BlockingDialogGate.shared === scope.gate)
        }
        XCTAssertTrue(BlockingDialogGate.shared === original)
    }

    func testPersistentCleanupAwaitsAuxiliaryWriterOnSuccessAndError() async throws {
        struct Expected: Error {}
        for fail in [false, true] {
            let entered = Latch(), release = Latch(), bodyDone = Latch()
            let finished = State(), output = State()
            let writer = Task.detached {
                await entered.release()
                await release.wait() // deliberately ignores cancellation until released
                output.append("last write")
            }
            await entered.wait()
            let scope = MCPInvocationContext(environment: [:])
            let command = Task {
                await MCPInvocationContext.$current.withValue(scope) {
                    do {
                        let value = try await MCPInvocationContext.finishingAuxiliary(writer) {
                            await bodyDone.release()
                            if fail { throw Expected() }
                            return 23
                        }
                        XCTAssertEqual(value, 23)
                        XCTAssertFalse(fail)
                    } catch { XCTAssertTrue(error is Expected); XCTAssertTrue(fail) }
                    finished.increment()
                }
            }
            await bodyDone.wait()
            for _ in 0..<100 where !writer.isCancelled { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(writer.isCancelled)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(finished.count, 0, "Request must not finish while a known writer is still active")
            await release.release()
            await command.value
            XCTAssertEqual(output.text, "last write")
            XCTAssertEqual(finished.count, 1)
            await writer.value
        }
    }

    func testOrdinaryCLICleanupKeepsItsCancelOnlyBehavior() async {
        let release = Latch()
        let writer = Task.detached { await release.wait() }
        await MCPInvocationContext.finishAuxiliary(writer)
        XCTAssertTrue(writer.isCancelled)
        await release.release()
        await writer.value
    }
}
