import XCTest
@testable import SafariBrowser

/// Tests the --tab alias deprecation warning introduced by
/// tab-targeting-v2. The deprecation is implemented as a pure
/// `TargetOptions.deprecationMessage(tab:)` helper so tests can verify
/// message content without capturing stderr.
final class TabDeprecationTests: XCTestCase {

    func testDeprecationMessageNilWhenTabNotSupplied() {
        XCTAssertNil(TargetOptions.deprecationMessage(tab: nil))
    }

    func testDeprecationMessageNonNilWhenTabSupplied() {
        XCTAssertNotNil(TargetOptions.deprecationMessage(tab: 1))
        XCTAssertNotNil(TargetOptions.deprecationMessage(tab: 42))
    }

    func testDeprecationMessageMentionsV3Removal() {
        guard let msg = TargetOptions.deprecationMessage(tab: 2) else {
            return XCTFail("Expected message for --tab 2")
        }
        XCTAssertTrue(msg.contains("v3.0"),
                      "Warning must advertise removal version")
        XCTAssertTrue(msg.contains("deprecated"),
                      "Warning must use the word 'deprecated'")
    }

    func testDeprecationMessageSuggestsReplacements() {
        guard let msg = TargetOptions.deprecationMessage(tab: 2) else {
            return XCTFail("Expected message for --tab 2")
        }
        XCTAssertTrue(msg.contains("--document"),
                      "Warning must suggest --document as replacement")
        XCTAssertTrue(msg.contains("--tab-in-window"),
                      "Warning must suggest --tab-in-window as replacement")
    }

    func testDeprecationMessageEndsWithNewline() {
        guard let msg = TargetOptions.deprecationMessage(tab: 2) else {
            return XCTFail("Expected message for --tab 2")
        }
        XCTAssertTrue(msg.hasSuffix("\n"),
                      "Warning must end with newline so stderr output doesn't concat onto next line")
    }
}
