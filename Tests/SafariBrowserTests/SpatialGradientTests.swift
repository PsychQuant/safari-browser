import XCTest
@testable import SafariBrowser

/// Tests for the spatial-interference gradient policy function
/// `SafariBridge.selectFocusAction`. This is the pure core of Group 9;
/// Space detection itself is SPI-backed and tested via integration.
///
/// Covers all four layers plus the Space-detection-unavailable fallback.
final class SpatialGradientTests: XCTestCase {

    // MARK: - Layer 1: already-focused no-op

    func testLayer1_frontWindowCurrentTab_noop() {
        let action = SafariBridge.selectFocusAction(
            targetWindow: 1,
            targetIsCurrent: true,
            frontWindowIndex: 1,
            currentSpace: 100,
            targetSpace: 100
        )
        XCTAssertEqual(action, .noop,
                       "Target is the front tab of the front window — nothing to do")
    }

    // MARK: - Layer 2: same-window background tab

    func testLayer2_frontWindowBackgroundTab_tabSwitch() {
        let action = SafariBridge.selectFocusAction(
            targetWindow: 1,
            targetIsCurrent: false,
            frontWindowIndex: 1
        )
        XCTAssertEqual(action, .sameWindowTabSwitch,
                       "Same window, background tab — switch tab in place (no warning needed)")
    }

    func testLayer2_spaceIdsIrrelevantWhenSameWindow() {
        // Even if Space IDs are supplied, same-window Layer 2 takes
        // precedence — we never raise a window when target is in the
        // current front window.
        let action = SafariBridge.selectFocusAction(
            targetWindow: 1,
            targetIsCurrent: false,
            frontWindowIndex: 1,
            currentSpace: 100,
            targetSpace: 999  // different Space, but target is in front window
        )
        XCTAssertEqual(action, .sameWindowTabSwitch)
    }

    // MARK: - Layer 3: cross-window same Space

    func testLayer3_differentWindowSameSpace_raise() {
        let action = SafariBridge.selectFocusAction(
            targetWindow: 2,
            targetIsCurrent: true,
            frontWindowIndex: 1,
            currentSpace: 100,
            targetSpace: 100
        )
        XCTAssertEqual(action, .sameSpaceRaise,
                       "Cross-window on the same Space — raise the target window")
    }

    func testLayer3_differentWindowBackgroundTabSameSpace_raiseAndSwitch() {
        // The policy returns .sameSpaceRaise for any target in a
        // different same-Space window; the executing caller is
        // responsible for doing tab-switch after the raise.
        let action = SafariBridge.selectFocusAction(
            targetWindow: 3,
            targetIsCurrent: false,
            frontWindowIndex: 1,
            currentSpace: 100,
            targetSpace: 100
        )
        XCTAssertEqual(action, .sameSpaceRaise)
    }

    // MARK: - Layer 4: cross-Space

    func testLayer4_differentWindowDifferentSpace_newTab() {
        let action = SafariBridge.selectFocusAction(
            targetWindow: 2,
            targetIsCurrent: true,
            frontWindowIndex: 1,
            currentSpace: 100,
            targetSpace: 200
        )
        XCTAssertEqual(action, .crossSpaceNewTab,
                       "Target lives on a different Space — open a new tab in current Space instead of cross-Space raise")
    }

    // MARK: - Space detection unavailable (fallback to Layer 3)

    func testSpaceDetectionUnavailable_currentSpaceNil_fallsBackToLayer3() {
        // Current Space detection failed (nil) — even if target Space
        // is known, policy must not invoke Layer 4. Conservative
        // default is Layer 3 raise (matches legacy behavior).
        let action = SafariBridge.selectFocusAction(
            targetWindow: 2,
            targetIsCurrent: true,
            frontWindowIndex: 1,
            currentSpace: nil,
            targetSpace: 200
        )
        XCTAssertEqual(action, .sameSpaceRaise)
    }

    func testSpaceDetectionUnavailable_targetSpaceNil_fallsBackToLayer3() {
        let action = SafariBridge.selectFocusAction(
            targetWindow: 2,
            targetIsCurrent: true,
            frontWindowIndex: 1,
            currentSpace: 100,
            targetSpace: nil
        )
        XCTAssertEqual(action, .sameSpaceRaise)
    }

    func testSpaceDetectionUnavailable_bothNil_fallsBackToLayer3() {
        let action = SafariBridge.selectFocusAction(
            targetWindow: 2,
            targetIsCurrent: true,
            frontWindowIndex: 1,
            currentSpace: nil,
            targetSpace: nil
        )
        XCTAssertEqual(action, .sameSpaceRaise)
    }

    // MARK: - Non-standard front window index

    func testFrontWindowIsNotIndexOne_layer1And2StillCorrect() {
        // Synthetic scenario: AppleScript's front window is window 3
        // (unusual but parameterized for test completeness).
        let noop = SafariBridge.selectFocusAction(
            targetWindow: 3,
            targetIsCurrent: true,
            frontWindowIndex: 3
        )
        XCTAssertEqual(noop, .noop)

        let tabSwitch = SafariBridge.selectFocusAction(
            targetWindow: 3,
            targetIsCurrent: false,
            frontWindowIndex: 3
        )
        XCTAssertEqual(tabSwitch, .sameWindowTabSwitch)

        let raise = SafariBridge.selectFocusAction(
            targetWindow: 1,
            targetIsCurrent: true,
            frontWindowIndex: 3
        )
        XCTAssertEqual(raise, .sameSpaceRaise)
    }

    // MARK: - Gradient applies to any focus-existing invocation (non-interference spec scenario)

    func testGradientIsPureAndStatelessAcrossCalls() {
        // Regression guard: repeated calls with identical inputs must
        // produce identical outputs — no hidden state / caching in the
        // policy function.
        for _ in 0..<5 {
            XCTAssertEqual(
                SafariBridge.selectFocusAction(
                    targetWindow: 2, targetIsCurrent: false,
                    currentSpace: 100, targetSpace: 200
                ),
                .crossSpaceNewTab
            )
        }
    }
}
