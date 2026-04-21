import XCTest
import Foundation
@testable import SafariBrowser

/// #31: unit tests for the pure helpers backing `save-image`.
/// JSON response parsing, data URL decoding, scheme extraction, and
/// cross-origin detection are all pure functions — testing them here
/// avoids the need for a live Safari for anything beyond the integration
/// smoke tests in tasks 4.3-4.5.
final class SaveImageTests: XCTestCase {

    // MARK: - parseElementResourceResponse: success cases

    func testParseSuccessURL() throws {
        let json = """
        {"kind":"url","src":"https://cdn.example.com/hero.jpg"}
        """
        let result = try SafariBridge.parseElementResourceResponse(json, selector: "#hero")
        XCTAssertEqual(result, .url("https://cdn.example.com/hero.jpg"))
    }

    func testParseSuccessInlineSVG() throws {
        let json = """
        {"kind":"inline_svg","data":"<svg viewBox=\\"0 0 10 10\\"><circle r=\\"5\\"/></svg>"}
        """
        let result = try SafariBridge.parseElementResourceResponse(json, selector: "#logo")
        guard case .inlineSVG(let html) = result else {
            XCTFail("Expected inlineSVG, got \(result)")
            return
        }
        XCTAssertTrue(html.contains("<svg"))
        XCTAssertTrue(html.contains("circle"))
    }

    func testParseSuccessURLWithDataURLSrc() throws {
        let json = """
        {"kind":"url","src":"data:image/png;base64,iVBORw0KGgo="}
        """
        let result = try SafariBridge.parseElementResourceResponse(json, selector: "img")
        XCTAssertEqual(result, .url("data:image/png;base64,iVBORw0KGgo="))
    }

    // MARK: - parseElementResourceResponse: error cases

    func testParseNotFoundError() {
        let json = #"{"error":"not_found"}"#
        XCTAssertThrowsError(
            try SafariBridge.parseElementResourceResponse(json, selector: "#missing")
        ) { error in
            guard case SafariBrowserError.elementNotFound(let sel) = error else {
                XCTFail("Expected elementNotFound, got \(error)")
                return
            }
            XCTAssertEqual(sel, "#missing")
        }
    }

    func testParseAmbiguousError() {
        let json = """
        {"error":"ambiguous","matches":[
          {"x":50,"y":100,"w":300,"h":200,"attrs":"img.product","text":"Shoe"},
          {"x":50,"y":320,"w":300,"h":200,"attrs":"img.product","text":"Hat"}
        ]}
        """
        XCTAssertThrowsError(
            try SafariBridge.parseElementResourceResponse(json, selector: "img.product")
        ) { error in
            guard case SafariBrowserError.elementAmbiguous(let sel, let matches) = error else {
                XCTFail("Expected elementAmbiguous, got \(error)")
                return
            }
            XCTAssertEqual(sel, "img.product")
            XCTAssertEqual(matches.count, 2)
            XCTAssertEqual(matches[0].attributes, "img.product")
            XCTAssertEqual(matches[0].textSnippet, "Shoe")
            XCTAssertEqual(matches[1].textSnippet, "Hat")
        }
    }

    func testParseIndexOutOfRangeError() {
        let json = #"{"error":"index_out_of_range","index":5,"matchCount":2}"#
        XCTAssertThrowsError(
            try SafariBridge.parseElementResourceResponse(json, selector: ".card")
        ) { error in
            guard case SafariBrowserError.elementIndexOutOfRange(let sel, let idx, let count) = error else {
                XCTFail("Expected elementIndexOutOfRange, got \(error)")
                return
            }
            XCTAssertEqual(sel, ".card")
            XCTAssertEqual(idx, 5)
            XCTAssertEqual(count, 2)
        }
    }

    func testParseSelectorInvalidError() {
        let json = #"{"error":"selector_invalid","reason":"SyntaxError: unclosed bracket"}"#
        XCTAssertThrowsError(
            try SafariBridge.parseElementResourceResponse(json, selector: "div[bad")
        ) { error in
            guard case SafariBrowserError.elementSelectorInvalid(let sel, let reason) = error else {
                XCTFail("Expected elementSelectorInvalid, got \(error)")
                return
            }
            XCTAssertEqual(sel, "div[bad")
            XCTAssertTrue(reason.contains("unclosed"))
        }
    }

    func testParseHasNoSrcError() {
        let json = #"{"error":"has_no_src","tagName":"img"}"#
        XCTAssertThrowsError(
            try SafariBridge.parseElementResourceResponse(json, selector: "#empty")
        ) { error in
            guard case SafariBrowserError.elementHasNoSrc(let sel, let tag) = error else {
                XCTFail("Expected elementHasNoSrc, got \(error)")
                return
            }
            XCTAssertEqual(sel, "#empty")
            XCTAssertEqual(tag, "img")
        }
    }

    func testParseUnsupportedElementError() {
        let json = #"{"error":"unsupported_element","tagName":"canvas"}"#
        XCTAssertThrowsError(
            try SafariBridge.parseElementResourceResponse(json, selector: "#chart")
        ) { error in
            guard case SafariBrowserError.unsupportedElement(let sel, let tag) = error else {
                XCTFail("Expected unsupportedElement, got \(error)")
                return
            }
            XCTAssertEqual(sel, "#chart")
            XCTAssertEqual(tag, "canvas")
        }
    }

    // MARK: - parseElementResourceResponse: defensive

    func testParseMalformedJSONThrows() {
        XCTAssertThrowsError(
            try SafariBridge.parseElementResourceResponse("not json", selector: "#x")
        ) { error in
            guard case SafariBrowserError.elementSelectorInvalid = error else {
                XCTFail("Expected elementSelectorInvalid, got \(error)")
                return
            }
        }
    }

    func testParseEmptyObjectThrows() {
        XCTAssertThrowsError(
            try SafariBridge.parseElementResourceResponse("{}", selector: "#x")
        ) { error in
            guard case SafariBrowserError.elementSelectorInvalid = error else {
                XCTFail("Expected elementSelectorInvalid, got \(error)")
                return
            }
        }
    }

    func testParseUnknownKindThrows() {
        let json = #"{"kind":"future_kind","data":"..."}"#
        XCTAssertThrowsError(
            try SafariBridge.parseElementResourceResponse(json, selector: "#x")
        ) { error in
            guard case SafariBrowserError.elementSelectorInvalid(_, let reason) = error else {
                XCTFail("Expected elementSelectorInvalid, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("future_kind"))
        }
    }

    // MARK: - extractSchemeFrom

    func testSchemeExtractionHTTPS() {
        XCTAssertEqual(SaveImageCommand.extractSchemeFrom("https://example.com/x.jpg"), "https")
    }

    func testSchemeExtractionHTTP() {
        XCTAssertEqual(SaveImageCommand.extractSchemeFrom("http://example.com/x.jpg"), "http")
    }

    func testSchemeExtractionData() {
        XCTAssertEqual(SaveImageCommand.extractSchemeFrom("data:image/png;base64,iVBOR"), "data")
    }

    func testSchemeExtractionBlob() {
        XCTAssertEqual(SaveImageCommand.extractSchemeFrom("blob:https://example.com/abc"), "blob")
    }

    func testSchemeExtractionCaseInsensitive() {
        XCTAssertEqual(SaveImageCommand.extractSchemeFrom("HTTPS://example.com/x.jpg"), "https")
    }

    func testSchemeExtractionEmpty() {
        XCTAssertEqual(SaveImageCommand.extractSchemeFrom(""), "")
    }

    func testSchemeExtractionNoColon() {
        XCTAssertEqual(SaveImageCommand.extractSchemeFrom("/just-a-path/no-scheme"), "")
    }

    // MARK: - decodeDataURL

    func testDecodeDataURLBase64() throws {
        // "Hello" base64 is "SGVsbG8="
        let url = "data:text/plain;base64,SGVsbG8="
        let decoded = try SaveImageCommand.decodeDataURL(url)
        XCTAssertEqual(String(data: decoded, encoding: .utf8), "Hello")
    }

    func testDecodeDataURLBase64PNG() throws {
        // Minimal 10x10 red PNG — exercises real image bytes
        let url = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAFUlEQVR42mP8z8BQz0AEYBxVSF+FABJssz/VJ1Y+AAAAAElFTkSuQmCC"
        let decoded = try SaveImageCommand.decodeDataURL(url)
        // PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A
        XCTAssertEqual(decoded[0], 0x89)
        XCTAssertEqual(decoded[1], 0x50)
        XCTAssertEqual(decoded[2], 0x4E)
        XCTAssertEqual(decoded[3], 0x47)
    }

    func testDecodeDataURLPercentEncoded() throws {
        // data:text/plain,Hello%20World (no ;base64)
        let url = "data:text/plain,Hello%20World"
        let decoded = try SaveImageCommand.decodeDataURL(url)
        XCTAssertEqual(String(data: decoded, encoding: .utf8), "Hello World")
    }

    func testDecodeDataURLMalformedNoComma() {
        let url = "data:image/png;base64"
        XCTAssertThrowsError(try SaveImageCommand.decodeDataURL(url)) { error in
            guard case SafariBrowserError.downloadFailed(_, _, let reason) = error else {
                XCTFail("Expected downloadFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("no comma"))
        }
    }

    func testDecodeDataURLInvalidBase64() {
        let url = "data:image/png;base64,!!!not-base64!!!"
        XCTAssertThrowsError(try SaveImageCommand.decodeDataURL(url)) { error in
            guard case SafariBrowserError.downloadFailed = error else {
                XCTFail("Expected downloadFailed, got \(error)")
                return
            }
        }
    }

    func testDecodeDataURLNotADataURL() {
        let url = "https://example.com/x.jpg"
        XCTAssertThrowsError(try SaveImageCommand.decodeDataURL(url)) { error in
            guard case SafariBrowserError.downloadFailed(_, _, let reason) = error else {
                XCTFail("Expected downloadFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("not a data URL"))
        }
    }

    // MARK: - isCrossOrigin

    func testCrossOriginSameOrigin() {
        XCTAssertFalse(SaveImageCommand.isCrossOrigin(
            from: "https://example.com/page",
            to: URL(string: "https://example.com/image.jpg")!
        ))
    }

    func testCrossOriginSameOriginDifferentPath() {
        // Path difference doesn't matter — origin is scheme+host+port
        XCTAssertFalse(SaveImageCommand.isCrossOrigin(
            from: "https://example.com/a/b/c",
            to: URL(string: "https://example.com/x/y/z")!
        ))
    }

    func testCrossOriginDifferentScheme() {
        XCTAssertTrue(SaveImageCommand.isCrossOrigin(
            from: "https://example.com/",
            to: URL(string: "http://example.com/image.jpg")!
        ))
    }

    func testCrossOriginDifferentHost() {
        XCTAssertTrue(SaveImageCommand.isCrossOrigin(
            from: "https://example.com/",
            to: URL(string: "https://cdn.example.com/image.jpg")!
        ))
    }

    func testCrossOriginDifferentPort() {
        XCTAssertTrue(SaveImageCommand.isCrossOrigin(
            from: "https://example.com:8443/",
            to: URL(string: "https://example.com:9443/image.jpg")!
        ))
    }

    func testCrossOriginHostCaseInsensitive() {
        // DNS hostnames are case-insensitive — same origin
        XCTAssertFalse(SaveImageCommand.isCrossOrigin(
            from: "https://EXAMPLE.com/",
            to: URL(string: "https://example.COM/image.jpg")!
        ))
    }

    func testCrossOriginNilURL() {
        XCTAssertTrue(SaveImageCommand.isCrossOrigin(
            from: "https://example.com/",
            to: nil
        ))
    }

    // MARK: - ResourceTrack validation

    func testResourceTrackParses() {
        XCTAssertEqual(SafariBridge.ResourceTrack(rawValue: "currentSrc"), .currentSrc)
        XCTAssertEqual(SafariBridge.ResourceTrack(rawValue: "src"), .src)
        XCTAssertEqual(SafariBridge.ResourceTrack(rawValue: "poster"), .poster)
    }

    func testResourceTrackRejectsInvalid() {
        XCTAssertNil(SafariBridge.ResourceTrack(rawValue: "srcset"))
        XCTAssertNil(SafariBridge.ResourceTrack(rawValue: ""))
    }
}
