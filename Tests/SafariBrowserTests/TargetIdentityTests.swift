import XCTest

@testable import SafariBrowser

/// #79: identity-anchored target resolution.
///
/// AppleScript's `window N` is a z-order index — it dangles the moment the
/// user clicks another Safari window, sending later round-trips of a
/// multi-round-trip command to whatever tab now sits at that position
/// (cross-tab JS injection, silent wrong results). These tests pin the fix:
/// window-id anchoring (`tab T of window id W`), the in-script URL guard,
/// and the bounded re-resolve retry decision logic.
final class TargetIdentityTests: XCTestCase {

    private let gs = "\u{1D}"
    private let rs = "\u{1E}"

    // MARK: - S1: enumeration carries the stable window id

    func testParseWindowEnumeration7FieldCarriesWindowID() {
        // 7-field record: window GS tab GS isCurrent GS url GS title GS winName GS winID RS
        let raw = "1\(gs)1\(gs)1\(gs)https://a.com\(gs)Alpha\(gs)個人 — Alpha\(gs)22510\(rs)"
            + "1\(gs)2\(gs)0\(gs)https://b.com\(gs)Beta\(gs)個人 — Alpha\(gs)22510\(rs)"
            + "2\(gs)1\(gs)1\(gs)https://c.com\(gs)Gamma\(gs)work — Gamma\(gs)30691\(rs)"
        let windows = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].windowID, 22510)
        XCTAssertEqual(windows[1].windowID, 30691)
        // Existing fields keep working alongside the new one.
        XCTAssertEqual(windows[0].profile, "個人")
        XCTAssertEqual(windows[0].tabs.count, 2)
    }

    func testParseWindowEnumerationLegacy6FieldWindowIDNil() {
        // Pre-#79 6-field records (no window id) must still parse —
        // windowID degrades to nil and resolution falls back to the
        // positional form.
        let raw = "1\(gs)1\(gs)1\(gs)https://a.com\(gs)Alpha\(gs)個人 — Alpha\(rs)"
        let windows = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows[0].windowID)
        XCTAssertEqual(windows[0].profile, "個人")
    }

    func testParseWindowEnumerationMalformedWindowIDNil() {
        // A non-numeric id field must not crash the parser or corrupt
        // the record — windowID degrades to nil.
        let raw = "1\(gs)1\(gs)1\(gs)https://a.com\(gs)Alpha\(gs)win\(gs)garbage\(rs)"
        let windows = SafariBridge.parseWindowEnumeration(raw)
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows[0].windowID)
        XCTAssertEqual(windows[0].tabs[0].url, "https://a.com")
    }
}
