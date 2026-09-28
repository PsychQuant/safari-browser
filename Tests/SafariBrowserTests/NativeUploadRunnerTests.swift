import Foundation
import XCTest
@testable import SafariBrowser

final class NativeUploadRunnerTests: XCTestCase {
    func testOwnWorkerTraceIsImportedWithoutChangingFailure() async throws {
        let collector = PerformanceTrace.Collector()
        let body = #"""
        printf '[safari-browser timing] {"schemaVersion":1,"requestID":"12345678-1234-1234-1234-123456789abc","processID":%s,"status":"error","totalNanoseconds":12,"spans":[{"id":1,"phase":"ax.inspect","durationNanoseconds":10,"outcome":"ok"}],"droppedSpans":0}\n' "$$" >&2
        printf 'Error: execution error: SB_UPLOAD_INPUT_NOT_FOUND (-2700)\n' >&2
        exit 1
        """#
        do {
            _ = try await PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
                try await SafariBridge.runShell("/bin/sh", ["-c", body], timeout: 3, importOwnTiming: true)
            }
            XCTFail("must retain failure")
        } catch SafariBrowserError.subprocessFailed(_, let message) {
            XCTAssertEqual(message, "Error: execution error: SB_UPLOAD_INPUT_NOT_FOUND (-2700)")
        }
        let result = try XCTUnwrap(collector.finish(status: .error))
        XCTAssertEqual(result.spans.filter { $0.phase == .axInspect }.count, 1)
    }
    func testUntrustedTraceLinesRemainDiagnosticText() throws {
        let collector = PerformanceTrace.Collector()
        let summary = PerformanceTrace.Summary(schemaVersion: 1, requestID: UUID().uuidString,
            processID: 42, status: .ok, totalNanoseconds: 1, spans: [], droppedSpans: 0)
        let line = String(decoding: try XCTUnwrap(PerformanceTrace.line(summary)), as: UTF8.self)
        for raw in [line, PerformanceTrace.prefix + "not-json\n", line.replacingOccurrences(of: "schemaVersion\":1", with: "schemaVersion\":9")] {
            let remaining = PerformanceTrace.$context.withValue(.init(collector: collector, parentID: nil)) {
                PerformanceTrace.consumingOwnSummaryLines(from: raw, processID: 99)
            }
            XCTAssertEqual(remaining, raw)
        }
        XCTAssertEqual(collector.finish(status: .ok)?.spans.count, 0)
    }

}
