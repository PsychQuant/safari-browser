import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonLogOutcomeFormatTests: XCTestCase {
    private let token = UUID(uuidString: "00000000-0000-0000-0000-000000000205")!
    private let time = Date(timeIntervalSince1970: 1_700_000_000)

    private func object(_ line: String) throws -> [String: Any] {
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(value["ts"] as? String, "2023-11-14T22:13:20.000Z")
        XCTAssertEqual(value["requestToken"] as? String, token.uuidString)
        XCTAssertEqual(value["peerReceipt"] as? String, "unconfirmed")
        return value
    }

    func testPreparedPayloadPreservesOldFieldsAndLabelsTheirMeaning() throws {
        let row = try object(DaemonLog.formatEntry(timestamp: time, requestToken: token,
            method: "owned", requestId: 7, durationMs: 12, paramsLog: "{}", resultLog: "true", errorLog: nil))
        XCTAssertEqual(Set(row.keys), ["ts", "event", "requestToken", "peerReceipt", "method", "requestId", "durationMs", "params", "result", "error"])
        XCTAssertEqual(row["event"] as? String, "request_response_prepared")
        XCTAssertEqual(row["method"] as? String, "owned")
        XCTAssertEqual(row["requestId"] as? Int, 7)
        XCTAssertEqual(row["durationMs"] as? Int, 12)
        XCTAssertEqual((row["params"] as? [String: Any])?.count, 0)
        XCTAssertEqual(row["result"] as? Bool, true)
        XCTAssertTrue(row["error"] is NSNull)
    }

    func testCandidateSchemaUsesOnlyFixedMetadata() throws {
        let outcomes: [(DaemonLog.ResponseOutcome, String)] = [(.result, "result"), (.parseError, "parse_error"),
            (.methodNotFound, "method_not_found"), (.handlerError, "handler_error"), (.cancelled, "cancelled")]
        let selections: [(DaemonLog.CandidateSelection, String)] = [(.selected, "selected"), (.notSelected, "not_selected"), (.notOffered, "not_offered")]
        XCTAssertEqual(outcomes.count, DaemonLog.ResponseOutcome.allCases.count)
        XCTAssertEqual(selections.count, DaemonLog.CandidateSelection.allCases.count)
        for (outcome, outcomeText) in outcomes {
            for (selection, selectionText) in selections {
                let row = try object(DaemonLog.formatResponseCandidate(timestamp: time, requestToken: token,
                    outcome: outcome, selection: selection))
                XCTAssertEqual(Set(row.keys), ["ts", "event", "requestToken", "peerReceipt", "outcome", "selection"])
                XCTAssertEqual(row["event"] as? String, "request_response_candidate")
                XCTAssertEqual(row["outcome"] as? String, outcomeText)
                XCTAssertEqual(row["selection"] as? String, selectionText)
            }
        }
    }

    func testHandoffSchemaDoesNotClaimPeerDelivery() throws {
        let cases: [(DaemonLog.ShutdownHandoff, String)] = [(.rejected, "rejected"), (.hookReturned, "hook_returned"), (.instanceStopped, "instance_stopped")]
        XCTAssertEqual(cases.count, DaemonLog.ShutdownHandoff.allCases.count)
        for (outcome, text) in cases {
            let row = try object(DaemonLog.formatShutdownHandoff(timestamp: time, requestToken: token, outcome: outcome))
            XCTAssertEqual(Set(row.keys), ["ts", "event", "requestToken", "peerReceipt", "outcome"])
            XCTAssertEqual(row["event"] as? String, "request_shutdown_handoff")
            XCTAssertEqual(row["outcome"] as? String, text)
        }
    }
}
