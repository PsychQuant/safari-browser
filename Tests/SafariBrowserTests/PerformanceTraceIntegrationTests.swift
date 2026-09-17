import Foundation
import XCTest
@testable import SafariBrowser

final class PerformanceTraceIntegrationTests: XCTestCase {
    func testRouterRecordsChosenBackendAndDoesNotReplayUnknownOutcome() async throws {
        let collector = PerformanceTrace.Collector()
        var statelessCalls = 0
        var daemonCalls = 0
        do {
            _ = try await PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
                try await SafariBridge.runViaRouter(source: "private-source", daemonOptIn: true,
                    daemonFn: { _ in daemonCalls += 1; throw DaemonClient.Error.requestOutcomeUnknown("private error") },
                    statelessFn: { _ in statelessCalls += 1; return "unexpected" })
            }
            XCTFail("unknown outcome must propagate")
        } catch let error as DaemonClient.Error {
            XCTAssertNil(error.fallbackReason)
        }
        XCTAssertEqual(daemonCalls, 1)
        XCTAssertEqual(statelessCalls, 0)
        let result = try XCTUnwrap(collector.finish(status: .error))
        XCTAssertEqual(result.spans.map(\.phase), [.appleScriptDaemon])
        XCTAssertEqual(result.spans.first?.outcome, .error)
    }

    func testStatelessRouterPreservesResultAndRecordsPath() async throws {
        let collector = PerformanceTrace.Collector()
        let result = try await PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
            try await SafariBridge.runViaRouter(source: "private-source", daemonOptIn: false,
                daemonFn: { _ in XCTFail("not selected"); return "bad" }, statelessFn: { _ in "original" })
        }
        XCTAssertEqual(result, "original")
        XCTAssertEqual(collector.finish(status: .ok)?.spans.map(\.phase), [.appleScriptDirect])
    }

    func testActualProcessHasSpawnAndWaitWithoutArgumentContents() async throws {
        let collector = PerformanceTrace.Collector()
        let output = try await PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
            try await SafariBridge.runShell("/usr/bin/osascript", ["-e", "return 167"], timeout: 5)
        }
        XCTAssertEqual(output, "167")
        let result = try XCTUnwrap(collector.finish(status: .ok))
        XCTAssertEqual(result.spans.map(\.phase), [.processSpawn, .processWait])
        let line = String(decoding: try XCTUnwrap(PerformanceTrace.line(result)), as: UTF8.self)
        XCTAssertFalse(line.contains("return 167"))
        XCTAssertFalse(line.contains("/usr/bin"))
    }

    func testAXQueueCarriesOnlyRequestTimingContext() throws {
        let collector = PerformanceTrace.Collector()
        let worker = BoundedAXWorker()
        let observed = PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
            worker.run(budget: 0.5, fallback: false) { _ in PerformanceTrace.isActive }
        }
        XCTAssertTrue(observed)
        let result = try XCTUnwrap(collector.finish(status: .ok))
        XCTAssertEqual(result.spans.map(\.phase), [.axWait, .axInspect])
        XCTAssertEqual(result.spans.last?.parentID, result.spans.first?.id)
    }

    func testNativeTargetTraceUsesExistingMockRunner() async throws {
        let collector = PerformanceTrace.Collector()
        let target = try await PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in "167" }) {
                try await SafariBridge.resolveNativeTarget(from: .frontWindow, probeDialog: false)
            }
        }
        XCTAssertEqual(target.windowID, 167)
        XCTAssertEqual(collector.finish(status: .ok)?.spans.map(\.phase), [.nativeTarget, .appleScriptInProcess])
    }
    func testDaemonTransportFailureStillHasTimingWithoutReplay() async throws {
        let collector = PerformanceTrace.Collector()
        do {
            _ = try await PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
                try await DaemonClient.sendRequest(name: "trace-" + UUID().uuidString,
                    method: "ping", params: Data("{}".utf8), requestId: 167, timeout: 0.1)
            }
            XCTFail("unique absent service must not succeed")
        } catch { }
        let result = try XCTUnwrap(collector.finish(status: .error))
        XCTAssertEqual(result.spans.map(\.phase), [.daemonRequest])
        XCTAssertEqual(result.spans.first?.outcome, .error)
    }

}
