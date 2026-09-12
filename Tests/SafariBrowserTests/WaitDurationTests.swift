import ArgumentParser
import XCTest
@testable import SafariBrowser

final class WaitDurationTests: XCTestCase, @unchecked Sendable {
    func testZeroAndOrdinaryDurationsConvertExactly() throws {
        XCTAssertEqual(try WaitCommand.nanoseconds(forMilliseconds: 0), 0)
        XCTAssertEqual(try WaitCommand.nanoseconds(forMilliseconds: 1), 1_000_000)
        XCTAssertEqual(try WaitCommand.nanoseconds(forMilliseconds: 2000), 2_000_000_000)
    }

    func testLargestRepresentableDurationIsAcceptedWithoutWaiting() throws {
        let limit = Int(UInt64.max / 1_000_000)
        XCTAssertEqual(try WaitCommand.nanoseconds(forMilliseconds: limit), UInt64.max - UInt64.max % 1_000_000)
    }

    func testNegativeAndOverflowValuesAreValidationErrors() {
        let limit = Int(UInt64.max / 1_000_000)
        for value in [Int.min, -1, limit + 1, Int.max] {
            XCTAssertThrowsError(try WaitCommand.nanoseconds(forMilliseconds: value)) { error in
                XCTAssertTrue(error is ValidationError)
                let message = String(describing: error)
                if value < 0 { XCTAssertEqual(message, "Milliseconds must be non-negative, got \(value)") }
                else { XCTAssertTrue(message.contains(String(limit)), message) }
            }
        }
    }

    func testPredicateArgumentsKeepExistingParsingPrecedence() throws {
        let url = try WaitCommand.parse(["--for-url", "example", String(Int.max)])
        XCTAssertEqual(url.forUrl, "example")
        XCTAssertEqual(url.milliseconds, Int.max)
        let js = try WaitCommand.parse(["--js", "true", "--", "-1"])
        XCTAssertEqual(js.js, "true")
        XCTAssertEqual(js.milliseconds, -1)
    }
    func testRunUsesCheckedConversionBeforeSleeping() async throws {
        let zero = try WaitCommand.parse(["0"])
        try await zero.run()
        let overflow = try WaitCommand.parse([String(UInt64.max / 1_000_000 + 1)])
        do {
            try await overflow.run()
            XCTFail("Overflow must be rejected before sleeping")
        } catch {
            XCTAssertTrue(error is ValidationError)
        }
    }

}
