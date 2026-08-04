import XCTest
@testable import SafariBrowser

final class SafariBridgeTargetTests: XCTestCase {

    // MARK: - TargetDocument.frontWindow

    func testFrontWindowNamesTheWindowRatherThanIndexingTheCollection() {
        // #97: was `document 1`. Safari's documents collection omits tab-less
        // windows and follows window order, so with a tab-less window in front,
        // `document 1` is a different window's document — and every
        // default-target command would operate on a page nobody asked for,
        // silently. Naming the window makes that case raise instead.
        XCTAssertEqual(
            SafariBridge.resolveDocumentReference(.frontWindow),
            "document of front window")
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

    func testFrontWindowAndDocumentIndex1AreDeliberatelyDifferent() {
        // These were the same reference until #97, and that equivalence was the
        // bug: `--document 1` means "the first entry of the documents
        // collection", while the default target means "whatever window is in
        // front". They coincide only while every window has tabs. A tab-less
        // front window is exactly when they diverge, and exactly when the old
        // shared reference sent the command to the wrong page.
        XCTAssertNotEqual(
            SafariBridge.resolveDocumentReference(.frontWindow),
            SafariBridge.resolveDocumentReference(.documentIndex(1)),
            "the default target must not be an alias for --document 1")
    }

    // MARK: - Backward compatibility (#17/#18/#21)

    func testFrontWindowStillAvoidsTheTabLevelReference() {
        // #21 moved the default target off `current tab of front window`. That
        // still holds — #97 changed which *document* reference is used, not the
        // decision to stay above tab level, and a tab-level reference would
        // also reintroduce the -1728 raised by a tab-less window.
        let reference = SafariBridge.resolveDocumentReference(.frontWindow)
        XCTAssertFalse(reference.contains("current tab"),
                       "the default target must stay above tab level (#21)")

        // The companion assertion — "must not contain `front window`" — was
        // removed in #97 rather than adapted, because it encoded a belief that
        // measurement contradicted. It was there on the theory that naming the
        // front window would be blocked by a modal sheet. Measured on Safari 26
        // under both dialog shapes this tool can produce (a JavaScript alert
        // and a native file picker): `document of front window` reads fine
        // under both, as do `document 1`, `count of tabs of front window`, and
        // even the `current tab of front window` that #21 originally found
        // blocked. Only `do JavaScript` blocks, and that is #89's territory.
        // See Tests/e2e-reference-form-edges.sh to re-measure.
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
