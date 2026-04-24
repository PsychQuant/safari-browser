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

    // MARK: - TargetDocument.urlMatch
    //
    // Per the `url-matching-pipeline` change, `.urlMatch(UrlMatcher)` is
    // no longer resolved by `resolveDocumentReference` — it goes through
    // the native-path resolver (`resolveNativeTarget` → `pickNativeTarget`)
    // for uniform fail-closed semantics across all matcher variants.
    // `resolveDocumentReference` now preconditionFailures on `.urlMatch`,
    // so there is nothing to assert here. URL matching behavior is
    // covered by `UrlMatcherTests` and `WindowIndexResolverTests`.

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

    // MARK: - Backward compatibility (#17/#18/#21)

    func testFrontWindowProducesLegacyEquivalentReference() {
        // Phase 10 / task 10.3: in single-window Safari, `document 1` is the
        // direct equivalent of the legacy `current tab of front window`. This
        // test locks that invariant so any future refactor that accidentally
        // changes the default document reference (e.g., switching to
        // `front document` or `current tab of front window`) fails loudly.
        let reference = SafariBridge.resolveDocumentReference(.frontWindow)
        XCTAssertEqual(reference, "document 1",
                       "The default target must resolve to `document 1` to keep existing scripts working.")
        // And must not accidentally revert to window-scoped syntax (which
        // would reintroduce the #21 modal-block hang).
        XCTAssertFalse(reference.contains("front window"),
                       "Default target must not contain `front window` — that path is blocked by modal sheets (#21).")
        XCTAssertFalse(reference.contains("current tab"),
                       "Default target must not contain `current tab` — that's a tab-level reference that defeats the #21 fix.")
    }

    func testTargetDocumentIsSendable() {
        // TargetDocument must be Sendable so commands can hand it to
        // `SafariBridge.doJavaScript` in a Swift 6 concurrency context
        // without warnings. If the enum grows a non-Sendable payload in
        // the future, this test forces an explicit decision.
        let _: any Sendable = SafariBridge.TargetDocument.frontWindow
        let _: any Sendable = SafariBridge.TargetDocument.windowIndex(1)
        let _: any Sendable = SafariBridge.TargetDocument.urlMatch(.contains("x"))
        let _: any Sendable = SafariBridge.TargetDocument.documentIndex(1)
    }

    // URL pattern escaping tests are obsolete: `.urlMatch` no longer
    // interpolates user URL input into AppleScript (it uses `tab N of
    // window M` after native-path enumeration). Empty/Unicode/quote
    // pattern handling is now the `UrlMatcher` type's concern and is
    // covered by `UrlMatcherTests`.
}
