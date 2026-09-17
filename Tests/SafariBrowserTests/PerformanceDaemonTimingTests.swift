import Foundation
import XCTest
@testable import SafariBrowser

final class PerformanceDaemonTimingTests: XCTestCase {
    private func execute(_ source: String, timing: Any?, cache: PreCompiledScripts.CompileCache) async throws -> [String: Any] {
        var params: [String: Any] = ["source": source]
        if let timing { params["timing"] = timing }
        let data = try JSONSerialization.data(withJSONObject: params)
        let response = try await DaemonDispatch.Handlers.appleScriptExecute(paramsData: data, cache: cache)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    func testColdAndWarmCacheHaveOwnBoundedTiming() async throws {
        let cache = PreCompiledScripts.CompileCache()
        let cold = try await execute("return 167", timing: true, cache: cache)
        let warm = try await execute("return 167", timing: true, cache: cache)
        XCTAssertEqual(cold["output"] as? String, "167")
        XCTAssertEqual(warm["output"] as? String, "167")
        let coldTrace = try XCTUnwrap(cold["timing"] as? [String: Any])
        let warmTrace = try XCTUnwrap(warm["timing"] as? [String: Any])
        XCTAssertNotEqual(coldTrace["requestID"] as? String, warmTrace["requestID"] as? String)
        let coldPhases = try XCTUnwrap(coldTrace["spans"] as? [[String: Any]]).compactMap { $0["phase"] as? String }
        let warmPhases = try XCTUnwrap(warmTrace["spans"] as? [[String: Any]]).compactMap { $0["phase"] as? String }
        XCTAssertTrue(coldPhases.contains("daemon.compile"))
        XCTAssertTrue(warmPhases.contains("daemon.cache_hit"))
        XCTAssertFalse(warmPhases.contains("daemon.compile"))
        XCTAssertTrue(warmPhases.contains("daemon.execute"))
    }

    func testOnlyLiteralTrueOptsInAndDoesNotInheritOtherRequest() async throws {
        let parent = PerformanceTrace.Collector()
        let cache = PreCompiledScripts.CompileCache()
        for flag: Any? in [nil, false, 1, "true"] {
            let response = try await PerformanceTrace.$context.withValue(.init(collector: parent, parentID: nil)) {
                try await execute("return 168", timing: flag, cache: cache)
            }
            XCTAssertEqual(response["output"] as? String, "168")
            XCTAssertNil(response["timing"])
        }
        XCTAssertEqual(parent.finish(status: .ok)?.spans.count, 0)
    }

    func testCompileFailureKeepsOriginalErrorAndSanitizesTiming() async throws {
        let response = try await execute("return ( -- PRIVATE_SCRIPT_SENTINEL", timing: true, cache: .init())
        XCTAssertEqual(response["status"] as? String, "error")
        XCTAssertEqual(response["errorKind"] as? String, "compileFailed")
        let trace = try XCTUnwrap(response["timing"] as? [String: Any])
        XCTAssertEqual(trace["status"] as? String, "error")
        let data = try JSONSerialization.data(withJSONObject: trace)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE_SCRIPT_SENTINEL"))
    }

    func testExecEnvelopeCarriesTimingOnlyInActiveContext() throws {
        let command = try ExecCommand.parse([])
        XCTAssertNil(command.daemonEnvelope(steps: []) ["timing"])
        let collector = PerformanceTrace.Collector()
        PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
            XCTAssertEqual(command.daemonEnvelope(steps: []) ["timing"] as? Bool, true)
        }
        _ = collector.finish(status: .ok)
        PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
            XCTAssertNil(command.daemonEnvelope(steps: []) ["timing"])
        }
    }
    func testConcurrentDaemonRequestsNeverShareContext() async throws {
        let cache = PreCompiledScripts.CompileCache()
        let host = PerformanceTrace.Collector()
        let responses = try await PerformanceTrace.$context.withValue(.init(collector: host, parentID: nil)) {
            try await withThrowingTaskGroup(of: Data.self) { group in
                for number in 0..<6 {
                    let params = try JSONSerialization.data(withJSONObject: ["source": "return \(number)", "timing": number.isMultiple(of: 2)])
                    group.addTask { try await DaemonDispatch.Handlers.appleScriptExecute(paramsData: params, cache: cache) }
                }
                var output: [Data] = []
                for try await data in group { output.append(data) }
                return output
            }
        }
        var ids = Set<String>()
        for data in responses {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let number = try XCTUnwrap(Int(try XCTUnwrap(object["output"] as? String)))
            if number.isMultiple(of: 2) {
                let trace = try XCTUnwrap(object["timing"] as? [String: Any])
                ids.insert(try XCTUnwrap(trace["requestID"] as? String))
            } else { XCTAssertNil(object["timing"]) }
        }
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(host.finish(status: .ok)?.spans.count, 0)
    }

    func testMalformedExecTimingDoesNotChangeExecutionResult() throws {
        let collector = PerformanceTrace.Collector()
        let payload = try JSONSerialization.data(withJSONObject: [
            "results": "[]", "timing": ["schemaVersion": 99, "source": "private source"]
        ])
        let value = try PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
            try ExecCommand.daemonResults(from: payload)
        }
        XCTAssertEqual(value, "[]")
        XCTAssertEqual(collector.finish(status: .ok)?.spans.count, 0)
    }

}
