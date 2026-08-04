import XCTest
@testable import SafariBrowser

/// #82: navigation-vs-failure discrimination in the `js` protocol.
///
/// The interesting cases need a live Safari (a page that navigates itself), so
/// these cover the decision logic that runs *before* any Safari round-trip —
/// specifically the two short-circuits that must never reach out to Safari at
/// all, because reaching out is what turns a wrong guess into a wrong answer.
final class JSNavigationSettleTests: XCTestCase {

    /// No baseline URL means no evidence of navigation. Returning a URL here
    /// would let any failure be relabelled a successful navigation.
    func testNavigatedAwayURL_withoutBaselineReportsNoNavigation() async throws {
        let result = try await JSCommand.navigatedAwayURL(
            from: nil,
            target: .resolvedTab(windowID: 1, tabInWindow: 1, rematch: nil, profile: nil),
            firstMatch: false,
            profile: nil
        )
        XCTAssertNil(result, "an unknown starting URL must not be treated as navigation")
    }

    /// Only `targetTabChanged` is ambiguous between "navigated" and "failed".
    /// Every other error means what it says and must survive untouched — a
    /// syntax error swallowed as "navigated" would report success for code
    /// that never ran.
    func testSettleNavigation_rethrowsNonTabChangedErrors() async {
        let syntaxError = SafariBrowserError.appleScriptFailed("JavaScript syntax error: …")
        do {
            try await JSCommand.settleNavigationOrRethrow(
                syntaxError,
                preNavURL: "https://example.com/",
                target: .resolvedTab(windowID: 1, tabInWindow: 1, rematch: nil, profile: nil),
                firstMatch: false,
                profile: nil
            )
            XCTFail("a syntax error must not be settled as a navigation")
        } catch let error as SafariBrowserError {
            guard case .appleScriptFailed(let message) = error else {
                return XCTFail("expected the original appleScriptFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("syntax error"), "the original error must survive verbatim")
        } catch {
            XCTFail("expected SafariBrowserError, got \(error)")
        }
    }

    /// `targetTabChanged` with no baseline URL cannot be confirmed as
    /// navigation, so the original error stands. This is the fail-closed
    /// direction: an unconfirmed guess reports the error, never success.
    func testSettleNavigation_rethrowsTabChangedWhenNavigationUnconfirmed() async {
        let tabChanged = SafariBrowserError.targetTabChanged(expected: "example", actualURL: nil)
        do {
            try await JSCommand.settleNavigationOrRethrow(
                tabChanged,
                preNavURL: nil,   // nothing to compare against
                target: .resolvedTab(windowID: 1, tabInWindow: 1, rematch: nil, profile: nil),
                firstMatch: false,
                profile: nil
            )
            XCTFail("an unconfirmed tab change must not be reported as success")
        } catch let error as SafariBrowserError {
            guard case .targetTabChanged = error else {
                return XCTFail("expected the original targetTabChanged, got \(error)")
            }
        } catch {
            XCTFail("expected SafariBrowserError, got \(error)")
        }
    }

    /// The note must name where the page went and read as a success — a caller
    /// scanning stderr for trouble should not find any here.
    func testNavigationNote_namesDestinationAndReadsAsSuccess() {
        let url = "https://example.com/after"
        let note = JSCommand.navigationNote(for: url)
        XCTAssertTrue(note.contains(url), "the note must say where the page ended up: \(note)")
        XCTAssertTrue(note.contains("ran successfully"), "the note must not read as a failure: \(note)")
        XCTAssertFalse(note.lowercased().contains("error"), "success must not be worded as an error: \(note)")
        XCTAssertTrue(note.hasSuffix("\n"), "stderr notes are newline-terminated")
    }
}
