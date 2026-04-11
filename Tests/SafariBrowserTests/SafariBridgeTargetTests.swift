import XCTest
@testable import SafariBrowser

final class SafariBridgeTargetTests: XCTestCase {

    // MARK: - TargetDocument.frontWindow

    func testFrontWindowResolvesToDocument1() {
        let reference = SafariBridge.resolveDocumentReference(.frontWindow)
        XCTAssertEqual(reference, "document 1")
    }

    // MARK: - TargetDocument.windowIndex

    func testWindowIndexResolvesToDocumentOfWindow() {
        XCTAssertEqual(
            SafariBridge.resolveDocumentReference(.windowIndex(1)),
            "document of window 1"
        )
        XCTAssertEqual(
            SafariBridge.resolveDocumentReference(.windowIndex(2)),
            "document of window 2"
        )
        XCTAssertEqual(
            SafariBridge.resolveDocumentReference(.windowIndex(42)),
            "document of window 42"
        )
    }

    // MARK: - TargetDocument.urlContains

    func testUrlContainsResolvesWithQuotedPattern() {
        let reference = SafariBridge.resolveDocumentReference(.urlContains("plaud"))
        XCTAssertEqual(reference, #"first document whose URL contains "plaud""#)
    }

    func testUrlContainsEscapesDoubleQuotes() {
        // If the pattern contains a double quote, it must be AppleScript-escaped
        // (\" inside an AppleScript string literal) to avoid breaking the tell block.
        let reference = SafariBridge.resolveDocumentReference(.urlContains(#"example"dquote"#))
        XCTAssertEqual(reference, #"first document whose URL contains "example\"dquote""#)
    }

    func testUrlContainsEscapesBackslashes() {
        let reference = SafariBridge.resolveDocumentReference(.urlContains(#"path\subdir"#))
        XCTAssertEqual(reference, #"first document whose URL contains "path\\subdir""#)
    }

    // MARK: - TargetDocument.documentIndex

    func testDocumentIndexResolvesToBareIndex() {
        XCTAssertEqual(
            SafariBridge.resolveDocumentReference(.documentIndex(1)),
            "document 1"
        )
        XCTAssertEqual(
            SafariBridge.resolveDocumentReference(.documentIndex(3)),
            "document 3"
        )
    }

    // MARK: - Front window default equals document 1 (backward compatibility)

    func testFrontWindowAndDocumentIndex1ProduceSameReference() {
        // Core backward-compat invariant: in single-window Safari, `.frontWindow`
        // and `.documentIndex(1)` must both resolve to `document 1`, so existing
        // scripts without any target flag behave identically to the legacy
        // "current tab of front window" semantics.
        XCTAssertEqual(
            SafariBridge.resolveDocumentReference(.frontWindow),
            SafariBridge.resolveDocumentReference(.documentIndex(1))
        )
    }
}
