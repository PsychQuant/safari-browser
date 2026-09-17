import Foundation
import XCTest
@testable import SafariBrowser

final class PerformanceErrorOutputTests: XCTestCase {
    private func summary() throws -> PerformanceTrace.Summary {
        let collector = PerformanceTrace.Collector()
        let span = try XCTUnwrap(collector.begin(.command))
        collector.end(span, outcome: .error)
        return try XCTUnwrap(collector.finish(status: .error))
    }

    func testOnlyOwnValidSummaryIsSeparatedFromErrorText() throws {
        let summary = try summary()
        let line = String(decoding: try XCTUnwrap(PerformanceTrace.line(summary)), as: UTF8.self)
        let original = "warning before\n" + line + "original error\n"
        XCTAssertEqual(PerformanceTrace.removingOwnSummaryLines(from: original,
            processID: ProcessInfo.processInfo.processIdentifier), "warning before\noriginal error\n")
        XCTAssertEqual(PerformanceTrace.removingOwnSummaryLines(from: original, processID: 0), original)
    }

    func testMalformedAndOversizedLookalikesRemainDiagnostics() throws {
        let original = try summary()
        let data = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for mutation in 0..<4 {
            var changed = object
            switch mutation {
            case 0: changed["schemaVersion"] = 99
            case 1: changed["requestID"] = "not-a-uuid"
            case 2:
                var spans = try XCTUnwrap(changed["spans"] as? [[String: Any]])
                spans[0]["parentID"] = 64
                changed["spans"] = spans
            default: changed["extra"] = String(repeating: "x", count: 65536)
            }
            let line = PerformanceTrace.prefix + String(decoding: try JSONSerialization.data(withJSONObject: changed), as: UTF8.self) + "\n"
            XCTAssertEqual(PerformanceTrace.removingOwnSummaryLines(from: line,
                processID: ProcessInfo.processInfo.processIdentifier), line)
        }
        let text = "ordinary\r\n" + PerformanceTrace.prefix + "not JSON\nlast diagnostic"
        XCTAssertEqual(PerformanceTrace.removingOwnSummaryLines(from: text,
            processID: ProcessInfo.processInfo.processIdentifier), text)
    }
}
