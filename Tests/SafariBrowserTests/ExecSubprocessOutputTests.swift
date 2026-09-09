import XCTest
import Foundation
@testable import SafariBrowser

final class ExecSubprocessOutputTests: XCTestCase {
    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = ""
        func append(_ value: String) { lock.lock(); defer { lock.unlock() }; storage += value }
        var text: String { lock.lock(); defer { lock.unlock() }; return storage }
    }

    func testSuccessfulStepForwardsStderrSeparately() async throws {
        let warnings = Output()
        let result = try await CommandDispatch.runSubprocess(
            executable: "/bin/sh", arguments: ["-c", "printf value; printf warning >&2"],
            stderrWriter: { warnings.append($0) })
        XCTAssertEqual(result, "value")
        XCTAssertEqual(warnings.text, "warning")
    }

    func testBothPipesLargerThanCapacityCompleteWithoutLosingBytes() async throws {
        let warnings = Output()
        // The alarm kills only this fixture if production stops draining either
        // pipe, turning the original deadlock into a bounded failing test.
        let script = "import os,signal; signal.alarm(3); os.write(2,b'e'*262144); os.write(1,b'o'*262144)"
        let result = try await CommandDispatch.runSubprocess(
            executable: "/usr/bin/python3", arguments: ["-c", script],
            stderrWriter: { warnings.append($0) })
        XCTAssertEqual(result, String(repeating: "o", count: 262144))
        XCTAssertEqual(warnings.text, String(repeating: "e", count: 262144))
    }

    func testFailedStepStillForwardsStderrAndPreservesError() async {
        let warnings = Output()
        do {
            _ = try await CommandDispatch.runSubprocess(
                executable: "/bin/sh", arguments: ["-c", "printf problem >&2; exit 7"],
                stderrWriter: { warnings.append($0) })
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("problem"))
        }
        XCTAssertEqual(warnings.text, "problem")
    }
}
