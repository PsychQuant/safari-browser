import XCTest
import ArgumentParser
@testable import SafariBrowser

/// #45 — `tab focus` parse-level + resolution coverage. The live tab-switch
/// behavior (AppleScript `set current tab` actually fronting the resolved tab,
/// state preserved) is exercised by `Tests/e2e-tab-focus.sh` against real
/// Safari; here we verify the subcommand is registered, accepts the full
/// `TargetOptions`, and that the pure resolver it relies on maps a
/// background-tab target to the switch index the command feeds `switchToTab`.
final class TabFocusTests: XCTestCase {

    func testTabFocusParsesUrlTarget() throws {
        let cmd = try TabFocusCommand.parse(["--url", "plaud"])
        XCTAssertEqual(cmd.target.url, "plaud")
    }

    func testTabFocusParsesWindowAndTabInWindow() throws {
        let cmd = try TabFocusCommand.parse(["--window", "2", "--tab-in-window", "3"])
        XCTAssertEqual(cmd.target.window, 2)
        XCTAssertEqual(cmd.target.tabInWindow, 3)
    }

    func testTabFocusParsesProfile() throws {
        let cmd = try TabFocusCommand.parse(["--url", "mail", "--profile", "工作"])
        XCTAssertEqual(cmd.target.resolveProfile(), "工作")
    }

    func testTabFocusRegisteredUnderTab() {
        // `tab` must expose `focus` as a subcommand — the #45 CLI surface.
        let names = TabCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        XCTAssertTrue(names.contains("focus"), "tab must expose a 'focus' subcommand; got \(names)")
    }

    func testTabFocusResolutionMapsBackgroundTabToSwitchIndex() throws {
        // The pure resolver `tab focus` relies on: a background-tab target must
        // resolve to a (window, tabIndexInWindow) so the command issues a switch.
        let windows = [
            SafariBridge.WindowInfo(
                windowIndex: 1, currentTabIndex: 1,
                tabs: [
                    SafariBridge.TabInWindow(tabIndex: 1, url: "https://a", title: "", isCurrent: true),
                    SafariBridge.TabInWindow(tabIndex: 2, url: "https://target", title: "", isCurrent: false),
                ]
            ),
        ]
        let resolved = try SafariBridge.pickNativeTarget(.urlMatch(.contains("target")), in: windows)
        XCTAssertEqual(resolved.windowIndex, 1)
        XCTAssertEqual(resolved.tabIndexInWindow, 2,
                       "background-tab target must carry the switch index")
    }

    func testTabFocusResolutionCurrentTabNeedsNoSwitch() throws {
        // When the target IS already the current tab, the resolver returns nil
        // tabIndexInWindow → `tab focus` is an idempotent no-op (no switch).
        let windows = [
            SafariBridge.WindowInfo(
                windowIndex: 1, currentTabIndex: 1,
                tabs: [
                    SafariBridge.TabInWindow(tabIndex: 1, url: "https://target", title: "", isCurrent: true),
                ]
            ),
        ]
        let resolved = try SafariBridge.pickNativeTarget(.urlMatch(.contains("target")), in: windows)
        XCTAssertEqual(resolved.windowIndex, 1)
        XCTAssertNil(resolved.tabIndexInWindow, "current-tab target must not request a switch")
    }
}
