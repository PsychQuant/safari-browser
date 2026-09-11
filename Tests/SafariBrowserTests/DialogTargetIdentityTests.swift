import XCTest
import Foundation
@testable import SafariBrowser

final class DialogTargetIdentityTests: XCTestCase {
    func testEnumeratedPositionalTargetsRetainWindowIdentity() throws {
        let windows = [SafariBridge.WindowInfo(windowIndex: 7, currentTabIndex: 1,
                                               tabs: [], windowID: 42)]
        for target: SafariBridge.TargetDocument in [.frontWindow, .windowIndex(1)] {
            let result = try SafariBridge.pickNativeTarget(target, in: windows)
            XCTAssertEqual(result.windowID, 42)
            XCTAssertEqual(result.windowIndex, 7)
        }
    }

    func testNativePositionalTargetUsesStableIDAndEmitsWarning() async throws {
        let context = DaemonRequestContext(probe: { key in
            key == .id(42) ? .present(SafariBridge.BlockingDialog(message: "owned", buttons: ["OK"])) : .unprobed
        })
        let result = try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ _ in "42" }) {
                try await SafariBridge.resolveNativeTarget(from: .windowIndex(2))
            }
        }
        XCTAssertEqual(result.windowID, 42)
        XCTAssertEqual(context.diagnostics.count, 1)
        XCTAssertTrue(context.diagnostics.first?.contains("owned") ?? false)
    }
    func testJavaScriptRefusalUsesResolvedIDRatherThanPositionalAlias() async {
        let calls = ExecSubprocessOutputTests.Output()
        let context = DaemonRequestContext(probe: { key in
            key == .id(42) ? .present(SafariBridge.BlockingDialog(message: "owned", buttons: [])) : .clear
        })
        do {
            _ = try await DaemonRequestContext.$current.withValue(context) {
                try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                    calls.append(source)
                    return "42"
                }) { try await SafariBridge.doJavaScript("1+1", target: .frontWindow) }
            }
            XCTFail("the resolved window is blocked")
        } catch SafariBrowserError.javaScriptDialogBlocking { }
        catch { XCTFail("\(error)") }
        XCTAssertFalse(calls.text.contains("do JavaScript"))
    }

    func testMissingIdentityCannotBorrowAnotherWindowVerdict() async throws {
        let context = DaemonRequestContext(probe: { key in
            key == .id(42) ? .present(SafariBridge.BlockingDialog(message: "other", buttons: [])) : .unprobed
        })
        let result = try await DaemonRequestContext.$current.withValue(context) {
            context.gate.check(.id(42))
            return try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                source.contains("get id of window") ? "invalid-id" : "safe"
            }) { try await SafariBridge.doJavaScript("1+1", target: .windowIndex(2)) }
        }
        XCTAssertEqual(result, "safe")
    }

    func testTargetedTabListingKeepsTheProbedWindowID() async throws {
        let calls = ExecSubprocessOutputTests.Output()
        let context = DaemonRequestContext(probe: { _ in .clear })
        let tabs = try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                calls.append(source)
                return source.contains("get id of window") ? "42" : "0"
            }) { try await SafariBridge.listTabs(window: 2) }
        }
        XCTAssertTrue(tabs.isEmpty)
        XCTAssertTrue(calls.text.contains("count of tabs of window id 42"))
    }

}
