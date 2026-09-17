import Foundation
import XCTest
@testable import SafariBrowser

final class PerformanceDaemonTransportTimingTests: XCTestCase {
    func testMalformedAppleScriptSourceStillCarriesOptedInErrorTiming() async throws {
        let name = "trace-src-\(UUID().uuidString.prefix(8))"
        let server = DaemonServer.Instance()
        let cache = PreCompiledScripts.CompileCache()
        await server.register("applescript.execute") { data in
            try await DaemonDispatch.Handlers.appleScriptExecute(paramsData: data, cache: cache)
        }
        try await server.start(socketPath: DaemonClient.socketPath(name: name))
        defer { Task { await server.stop() } }
        for source in [nil, 167] as [Int?] {
            var envelope: [String: Any] = ["timing": true]
            if let source { envelope["source"] = source }
            let params = try JSONSerialization.data(withJSONObject: envelope)
            var originalMessage: String?
            do {
                _ = try await DaemonDispatch.Handlers.appleScriptExecute(paramsData: params, cache: cache)
                XCTFail("invalid source must throw")
            } catch { originalMessage = String(describing: error) }
            let collector = PerformanceTrace.Collector()
            do {
                _ = try await PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
                    try await DaemonClient.sendRequest(name: name, method: "applescript.execute", params: params, requestId: 1)
                }
                XCTFail("expected original decode error")
            } catch DaemonClient.Error.remoteError(let code, let message) {
                XCTAssertEqual(code, "handlerError")
                XCTAssertEqual(message, originalMessage)
            }
            let trace = try XCTUnwrap(collector.finish(status: .error))
            XCTAssertEqual(trace.spans.count, 2)
            XCTAssertTrue(trace.spans.allSatisfy { $0.outcome == .error })
        }
    }

    func testThrownExecHandlerTimingCrossesSocketAndStaysRequestLocal() async throws {
        let name = "trace-err-\(UUID().uuidString.prefix(8))"
        let server = DaemonServer.Instance()
        await server.register("exec.runScript") { data in
            try await DaemonDispatch.Handlers.execRunScript(paramsData: data)
        }
        try await server.start(socketPath: DaemonClient.socketPath(name: name))
        defer { Task { await server.stop() } }
        for (index, flag) in [true, false, 1, "true", true].enumerated() {
            let collector = PerformanceTrace.Collector()
            let params = try JSONSerialization.data(withJSONObject: ["timing": flag])
            do {
                _ = try await PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
                    try await DaemonClient.sendRequest(name: name, method: "exec.runScript",
                        params: params, requestId: index)
                }
                XCTFail("missing steps must retain the handler error")
            } catch DaemonClient.Error.remoteError(let code, let message) {
                XCTAssertEqual(code, "handlerError")
                XCTAssertEqual(message, "exec.runScript envelope: missing or invalid 'steps' array")
            }
            let trace = try XCTUnwrap(collector.finish(status: .error))
            let expected = index == 0 || index == 4 ? 2 : 1
            XCTAssertEqual(trace.spans.count, expected, "only literal true imports this request's server span")
            XCTAssertTrue(trace.spans.allSatisfy { $0.outcome == .error })
            if trace.spans.count == 2 {
                XCTAssertNil(trace.spans[0].parentID)
                XCTAssertEqual(trace.spans[1].parentID, trace.spans[0].id)
            }
        }
    }

    func testSuccessTimingCrossesSocketWithColdAndWarmCache() async throws {
        let name = "trace-ok-\(UUID().uuidString.prefix(8))"
        let server = DaemonServer.Instance()
        let cache = PreCompiledScripts.CompileCache()
        await server.register("applescript.execute") { data in
            try await DaemonDispatch.Handlers.appleScriptExecute(paramsData: data, cache: cache)
        }
        try await server.start(socketPath: DaemonClient.socketPath(name: name))
        defer { Task { await server.stop() } }
        for index in 0...1 {
            let collector = PerformanceTrace.Collector()
            let params = Data(#"{"source":"return 167","timing":true}"#.utf8)
            let data = try await PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
                try await DaemonClient.sendRequest(name: name, method: "applescript.execute",
                    params: params, requestId: index)
            }
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(response["output"] as? String, "167")
            let trace = try XCTUnwrap(collector.finish(status: .ok))
            XCTAssertEqual(trace.spans.filter { $0.phase == .daemonRequest }.count, 2)
            XCTAssertTrue(trace.spans.contains { $0.phase == (index == 0 ? .daemonCompile : .daemonCacheHit) })
            XCTAssertTrue(trace.spans.contains { $0.phase == .daemonExecute })
            XCTAssertTrue(trace.spans.dropFirst().allSatisfy { $0.parentID != nil })
        }
    }

    func testTimingWrapperPreservesThrownErrorIdentityAndDoesNotRetry() async {
        let original = NSError(domain: "private-error-sentinel", code: 167)
        var executions = 0
        do {
            _ = try await PerformanceTrace.withDaemonTiming(enabled: true) {
                executions += 1
                throw original
            }
            XCTFail("expected original error")
        } catch {
            XCTAssertTrue(error as NSError === original)
        }
        XCTAssertEqual(executions, 1)
    }
}
