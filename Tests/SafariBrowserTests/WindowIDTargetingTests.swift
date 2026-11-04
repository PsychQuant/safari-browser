import XCTest
import ArgumentParser
@testable import SafariBrowser

/// #352: `--window-id W` names a Safari window by its stable AppleScript id (`id of window`), which does not change
/// when windows are reordered. `--window N` stays positional. These tests pin the flag's validation, its resolution
/// to `TargetDocument`, the AppleScript references it produces, and its fail-closed behaviour.
final class WindowIDTargetingTests: XCTestCase {

    private func parse(_ args: [String]) throws -> TargetOptions {
        try TargetOptions.parse(args)
    }

    // MARK: 1.1 validation

    func testWindowIDIsMutuallyExclusiveWithEveryOtherTargetFlag() {
        for other in [["--window", "1"], ["--url", "x"], ["--url-exact", "https://x/"], ["--url-endswith", "#x"],
                      ["--url-regex", "x"], ["--tab", "1"], ["--document", "1"]] {
            XCTAssertThrowsError(try parse(["--window-id", "4711"] + other), "\(other)") { error in
                let text = "\(error)"
                XCTAssertTrue(text.contains("--window-id"), text)
            }
        }
    }

    func testTabInWindowPairsWithWindowOrWindowID() throws {
        XCTAssertNoThrow(try parse(["--window-id", "4711", "--tab-in-window", "2"]))
        XCTAssertNoThrow(try parse(["--window", "1", "--tab-in-window", "2"]))
        XCTAssertThrowsError(try parse(["--tab-in-window", "2"]))
    }

    func testWindowIDBelowOneIsRejected() {
        XCTAssertThrowsError(try parse(["--window-id", "0"]))
        XCTAssertThrowsError(try parse(["--window-id", "-3"]))
    }

    // MARK: 1.2 resolution and hasExplicitTarget

    func testWindowIDCountsAsAnExplicitTarget() throws {
        XCTAssertTrue(try parse(["--window-id", "4711"]).hasExplicitTarget)
    }

    func testWindowIDResolvesToTheWindowByID() throws {
        XCTAssertEqual(try parse(["--window-id", "4711"]).resolve(), .windowID(4711))
    }

    func testWindowIDWithATabResolvesToThatTabOfTheWindowByID() throws {
        let target = try parse(["--window-id", "4711", "--tab-in-window", "2"]).resolve()
        XCTAssertEqual(target, .resolvedTab(windowID: 4711, tabInWindow: 2, rematch: nil, profile: nil))
    }

    /// With `--profile` the tab target stays `.windowID` so the profile check runs: the profile
    /// branch of `resolveToConcreteTarget` passes a `.resolvedTab` through unchecked.
    func testWindowIDWithATabAndAProfileStaysUncheckedUntilTheProfileBranch() throws {
        let target = try parse(["--window-id", "4711", "--tab-in-window", "2", "--profile", "Work"]).resolve()
        XCTAssertEqual(target, .windowID(4711, tabInWindow: 2))
    }

    func testTheTabOfAWindowByIDRendersAsThatTab() {
        XCTAssertEqual(SafariBridge.resolveDocumentReference(.windowID(4711, tabInWindow: 2)), "tab 2 of window id 4711")
    }

    // MARK: 2.1 document reference

    func testTheWindowByIDRendersAsItsDocumentByID() {
        XCTAssertEqual(SafariBridge.resolveDocumentReference(.windowID(4711)), "document of window id 4711")
    }

    // MARK: 2.3 native resolver

    private func window(_ index: Int, id: Int?, profile: String? = "Own", tabs: Int = 2, current: Int = 1) -> SafariBridge.WindowInfo {
        SafariBridge.WindowInfo(
            windowIndex: index,
            currentTabIndex: current,
            tabs: (1...max(tabs, 1)).prefix(tabs).map {
                SafariBridge.TabInWindow(tabIndex: $0, url: "https://w\(index).example/\($0)", title: "t", isCurrent: $0 == current)
            },
            profile: profile,
            windowID: id)
    }

    func testTheNativeResolverFindsTheWindowByID() throws {
        let resolved = try SafariBridge.pickNativeTarget(.windowID(4711), in: [window(1, id: 1000), window(2, id: 4711, current: 2)])
        XCTAssertEqual(resolved.windowIndex, 2)
        XCTAssertEqual(resolved.windowID, 4711)
    }

    func testTheNativeResolverFailsClosedForAMissingID() {
        XCTAssertThrowsError(try SafariBridge.pickNativeTarget(.windowID(9999), in: [window(1, id: 1000)])) { error in
            guard case SafariBrowserError.documentNotFound = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: 2.4 profile membership

    func testAWindowIDOutsideTheRequestedProfileFails() {
        let windows = [window(1, id: 1000, profile: "Own"), window(2, id: 4711, profile: "Other")]
        XCTAssertThrowsError(try SafariBridge.pickNativeTarget(.windowID(4711), in: windows, profile: "Own")) { error in
            guard case SafariBrowserError.documentNotFound(_, let available) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(available.joined().contains("w2.example"), "\(available)")
        }
        XCTAssertNoThrow(try SafariBridge.pickNativeTarget(.windowID(1000), in: windows, profile: "Own"))
    }

    func testAResolvedTabByIDIsCheckedAgainstTheProfileToo() {
        let windows = [window(1, id: 1000, profile: "Own"), window(2, id: 4711, profile: "Other")]
        XCTAssertThrowsError(try SafariBridge.checkWindowID(4711, profile: "Own", in: windows))
        XCTAssertNoThrow(try SafariBridge.checkWindowID(1000, profile: "Own", in: windows))
        XCTAssertThrowsError(try SafariBridge.checkWindowID(5, profile: nil, in: windows), "a missing id fails without a profile too")
    }
}
