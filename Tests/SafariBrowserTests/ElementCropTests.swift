import XCTest
import CoreGraphics
@testable import SafariBrowser

/// #30: unit tests for the pure response-parsing logic in
/// `SafariBridge.parseElementBoundsResponse`. The parser is separated
/// from the live-Safari JS eval so the JSON→error mapping and rect
/// math can be exercised without spinning up Safari.
final class ElementCropTests: XCTestCase {

    // MARK: - success path

    func testParseSuccess() throws {
        let json = """
        {"ok":{"x":50,"y":100,"w":200,"h":150,"iw":1920,"ih":1080,
               "matchCount":1,"attributes":"div#target","textSnippet":"Target"}}
        """
        let result = try SafariBridge.parseElementBoundsResponse(json, selector: "#target")
        XCTAssertEqual(result.rectInViewport, CGRect(x: 50, y: 100, width: 200, height: 150))
        XCTAssertEqual(result.viewportSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(result.matchCount, 1)
        XCTAssertEqual(result.attributes, "div#target")
        XCTAssertEqual(result.textSnippet, "Target")
    }

    func testParseSuccessWithNullTextSnippet() throws {
        let json = """
        {"ok":{"x":0,"y":0,"w":10,"h":10,"iw":1920,"ih":1080,
               "matchCount":1,"attributes":"img","textSnippet":null}}
        """
        let result = try SafariBridge.parseElementBoundsResponse(json, selector: "img")
        XCTAssertNil(result.textSnippet)
    }

    // Sub-pixel coordinates from getBoundingClientRect must survive
    // parsing — cropPNG's integral-rounding downstream handles them.
    func testParseSuccessWithFractionalCoords() throws {
        let json = """
        {"ok":{"x":50.5,"y":100.25,"w":200.75,"h":150.5,"iw":1920,"ih":1080,
               "matchCount":1,"attributes":"div","textSnippet":null}}
        """
        let result = try SafariBridge.parseElementBoundsResponse(json, selector: "div")
        XCTAssertEqual(result.rectInViewport.origin.x, 50.5, accuracy: 1e-9)
        XCTAssertEqual(result.rectInViewport.origin.y, 100.25, accuracy: 1e-9)
        XCTAssertEqual(result.rectInViewport.size.width, 200.75, accuracy: 1e-9)
        XCTAssertEqual(result.rectInViewport.size.height, 150.5, accuracy: 1e-9)
    }

    // MARK: - error path mapping

    func testParseNotFoundError() {
        let json = """
        {"error":"not_found"}
        """
        XCTAssertThrowsError(
            try SafariBridge.parseElementBoundsResponse(json, selector: "#missing")
        ) { error in
            guard case SafariBrowserError.elementNotFound(let sel) = error else {
                XCTFail("Expected elementNotFound, got \(error)")
                return
            }
            XCTAssertEqual(sel, "#missing")
        }
    }

    func testParseAmbiguousErrorWithRichMatches() {
        let json = """
        {"error":"ambiguous","matches":[
          {"x":50,"y":100,"w":300,"h":200,"attrs":"div.card.featured","text":"Launch Sale"},
          {"x":50,"y":320,"w":300,"h":200,"attrs":"div.card","text":"Summer Deal"},
          {"x":50,"y":540,"w":300,"h":200,"attrs":"div.card","text":null}
        ]}
        """
        XCTAssertThrowsError(
            try SafariBridge.parseElementBoundsResponse(json, selector: ".card")
        ) { error in
            guard case SafariBrowserError.elementAmbiguous(let sel, let matches) = error else {
                XCTFail("Expected elementAmbiguous, got \(error)")
                return
            }
            XCTAssertEqual(sel, ".card")
            XCTAssertEqual(matches.count, 3)
            XCTAssertEqual(matches[0].rect, CGRect(x: 50, y: 100, width: 300, height: 200))
            XCTAssertEqual(matches[0].attributes, "div.card.featured")
            XCTAssertEqual(matches[0].textSnippet, "Launch Sale")
            XCTAssertEqual(matches[2].textSnippet, nil,
                           "null text snippet should parse as Swift nil")
        }
    }

    func testParseIndexOutOfRangeError() {
        let json = """
        {"error":"index_out_of_range","index":5,"matchCount":3}
        """
        XCTAssertThrowsError(
            try SafariBridge.parseElementBoundsResponse(json, selector: ".card")
        ) { error in
            guard case SafariBrowserError.elementIndexOutOfRange(let sel, let idx, let count) = error else {
                XCTFail("Expected elementIndexOutOfRange, got \(error)")
                return
            }
            XCTAssertEqual(sel, ".card")
            XCTAssertEqual(idx, 5)
            XCTAssertEqual(count, 3)
        }
    }

    func testParseZeroSizeError() {
        let json = """
        {"error":"zero_size"}
        """
        XCTAssertThrowsError(
            try SafariBridge.parseElementBoundsResponse(json, selector: "#hidden")
        ) { error in
            guard case SafariBrowserError.elementZeroSize(let sel) = error else {
                XCTFail("Expected elementZeroSize, got \(error)")
                return
            }
            XCTAssertEqual(sel, "#hidden")
        }
    }

    func testParseOutsideViewportError() {
        let json = """
        {"error":"outside_viewport","x":0,"y":5000,"w":100,"h":100,"iw":1920,"ih":1080}
        """
        XCTAssertThrowsError(
            try SafariBridge.parseElementBoundsResponse(json, selector: "#below")
        ) { error in
            guard case SafariBrowserError.elementOutsideViewport(let sel, let rect, let vp) = error else {
                XCTFail("Expected elementOutsideViewport, got \(error)")
                return
            }
            XCTAssertEqual(sel, "#below")
            XCTAssertEqual(rect, CGRect(x: 0, y: 5000, width: 100, height: 100))
            XCTAssertEqual(vp, CGSize(width: 1920, height: 1080))
        }
    }

    func testParseSelectorInvalidError() {
        let json = """
        {"error":"selector_invalid","reason":"The string did not match the expected pattern."}
        """
        XCTAssertThrowsError(
            try SafariBridge.parseElementBoundsResponse(json, selector: "div[unclosed")
        ) { error in
            guard case SafariBrowserError.elementSelectorInvalid(let sel, let reason) = error else {
                XCTFail("Expected elementSelectorInvalid, got \(error)")
                return
            }
            XCTAssertEqual(sel, "div[unclosed")
            XCTAssertTrue(reason.contains("did not match"),
                          "Expected JS error reason verbatim, got: \(reason)")
        }
    }

    // MARK: - malformed response defense

    func testParseMalformedJSONThrows() {
        let json = "not json at all"
        XCTAssertThrowsError(
            try SafariBridge.parseElementBoundsResponse(json, selector: "#x")
        ) { error in
            guard case SafariBrowserError.elementSelectorInvalid = error else {
                XCTFail("Expected elementSelectorInvalid for malformed JSON, got \(error)")
                return
            }
        }
    }

    func testParseEmptyObjectThrows() {
        let json = "{}"
        XCTAssertThrowsError(
            try SafariBridge.parseElementBoundsResponse(json, selector: "#x")
        ) { error in
            guard case SafariBrowserError.elementSelectorInvalid = error else {
                XCTFail("Expected elementSelectorInvalid for empty response, got \(error)")
                return
            }
        }
    }

    func testParseUnknownErrorKindThrows() {
        let json = """
        {"error":"future_error_kind","detail":"..."}
        """
        XCTAssertThrowsError(
            try SafariBridge.parseElementBoundsResponse(json, selector: "#x")
        ) { error in
            guard case SafariBrowserError.elementSelectorInvalid(_, let reason) = error else {
                XCTFail("Expected elementSelectorInvalid for unknown kind, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("future_error_kind"),
                          "Expected unknown error kind in reason, got: \(reason)")
        }
    }

    // MARK: - viewport → window rect translation math

    // This is the core math the caller (ScreenshotCommand) will do.
    // Validating here keeps the integration code simple.
    func testViewportRectToWindowRectTranslation() {
        // Element at viewport (50, 100) — AXWebArea starts at window (0, 130).
        // Expected element in window: (50, 230) — same size.
        let viewportRect = CGRect(x: 50, y: 100, width: 200, height: 150)
        let webAreaOriginInWindow = CGPoint(x: 0, y: 130)
        let windowRect = CGRect(
            x: viewportRect.origin.x + webAreaOriginInWindow.x,
            y: viewportRect.origin.y + webAreaOriginInWindow.y,
            width: viewportRect.size.width,
            height: viewportRect.size.height
        )
        XCTAssertEqual(windowRect, CGRect(x: 50, y: 230, width: 200, height: 150))
    }

    func testWindowRectTranslationWithNonZeroWebAreaX() {
        // Sidebar layout: AXWebArea shifted right (e.g., 250pt sidebar).
        let viewportRect = CGRect(x: 50, y: 100, width: 200, height: 150)
        let webAreaOriginInWindow = CGPoint(x: 250, y: 130)
        let windowRect = CGRect(
            x: viewportRect.origin.x + webAreaOriginInWindow.x,
            y: viewportRect.origin.y + webAreaOriginInWindow.y,
            width: viewportRect.size.width,
            height: viewportRect.size.height
        )
        XCTAssertEqual(windowRect, CGRect(x: 300, y: 230, width: 200, height: 150))
    }
}
