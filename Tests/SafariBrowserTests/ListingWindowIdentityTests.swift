import Foundation
import XCTest
@testable import SafariBrowser

final class ListingWindowIdentityTests: XCTestCase, @unchecked Sendable {
    func testFlattenRetainsStableWindowIdentityWithoutChangingIndices() {
        let windows = [
            SafariBridge.WindowInfo(windowIndex: 7, currentTabIndex: 1,
                tabs: [.init(tabIndex: 1, url: "one", title: "one", isCurrent: true),
                       .init(tabIndex: 2, url: "two", title: "two", isCurrent: false)], windowID: 71),
            SafariBridge.WindowInfo(windowIndex: 3, currentTabIndex: 1,
                tabs: [.init(tabIndex: 1, url: "three", title: "three", isCurrent: true)], windowID: 72)
        ]
        let rows = SafariBridge.flattenWindowsToDocuments(windows)
        XCTAssertEqual(rows.map(\.windowID), [71, 71, 72])
        XCTAssertEqual(rows.map(\.index), [1, 2, 3])
        XCTAssertEqual(rows.map(\.window), [7, 7, 3])
    }

    func testBareTabsPinsTheInitialWindowIdentityForEveryRead() async throws {
        let calls = ExecSubprocessOutputTests.Output()
        let rows = try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
            calls.append(source)
            if source.contains("get id of window 1") { return "71" }
            if source.contains("count of tabs") { return "2" }
            if source.contains("window id 71") { return source.contains("get name") ? "title" : "https://fixture/" }
            return "wrong-front-window"
        }) { try await SafariBridge.listTabs() }
        XCTAssertEqual(rows.map(\.windowID), [71, 71])
        XCTAssertEqual(rows.map(\.title), ["title", "title"])
        XCTAssertFalse(calls.text.contains("of front window"))
    }

    func testExplicitTabsCarriesResolvedIDAndLegacyRowsRemainUnknown() async throws {
        let context = DaemonRequestContext(probe: { _ in .clear }, environment: [:])
        let rows = try await DaemonRequestContext.$current.withValue(context) {
            try await DaemonRequestContext.$appleScriptRunner.withValue({ source in
                source.contains("count of tabs") ? "1" : "value"
            }) {
                try await SafariBridge.listTabs(in: .init(windowIndex: 4, tabIndexInWindow: nil, windowID: 91))
            }
        }
        XCTAssertEqual(rows.first?.windowID, 91)
        XCTAssertNil(SafariBridge.TabInfo(index: 1, title: "legacy", url: "legacy").windowID)
    }
}
