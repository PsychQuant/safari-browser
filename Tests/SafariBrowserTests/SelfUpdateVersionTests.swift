import XCTest

@testable import SafariBrowser

/// #314: which installed builds `self-update` may replace. A development build
/// on (or past) the latest tag must never be "updated" back to that release.
final class SelfUpdateVersionTests: XCTestCase {

    func testClassificationTable() {
        let rows: [(String, String, SelfUpdateStatus)] = [
            ("v2.7.0", "v2.8.0", .updateAvailable),
            ("v2.8.0", "v2.8.0", .upToDate),
            ("v2.8.0-dirty", "v2.8.0", .ahead),
            ("v2.7.0-5-g1a2b3c4", "v2.8.0", .updateAvailable),
            ("v2.9.0", "v2.8.0", .ahead),
            ("1a2b3c4", "v2.8.0", .notComparable),
            ("unknown", "v2.8.0", .notComparable),
        ]
        for (installed, latest, expected) in rows {
            XCTAssertEqual(SelfUpdateVersion.classify(installed: installed, latestTag: latest), expected,
                           "\(installed) vs \(latest)")
        }
    }

    func testDevelopmentBuildOnTheLatestTagIsAhead() {
        XCTAssertEqual(SelfUpdateVersion.classify(installed: "v2.8.0-3-gabc1234", latestTag: "v2.8.0"), .ahead)
        XCTAssertEqual(SelfUpdateVersion.classify(installed: "v2.8.0-3-gabc1234-dirty", latestTag: "v2.8.0"), .ahead)
    }

    func testComponentsCompareNumericallyNotAsText() {
        XCTAssertEqual(SelfUpdateVersion.classify(installed: "v2.9.0", latestTag: "v2.10.0"), .updateAvailable)
        XCTAssertEqual(SelfUpdateVersion.classify(installed: "v10.0.0", latestTag: "v9.9.9"), .ahead)
    }

    func testShapesThatLookCloseAreNotComparable() {
        for installed in ["2.7.0", "v2.7", "v2.7.0-rc1", "v2.7.0-5-gXYZ", "v2.7.0 ", "", "v2.7.0-dirty-dirty"] {
            XCTAssertEqual(SelfUpdateVersion.classify(installed: installed, latestTag: "v2.8.0"), .notComparable,
                           "'\(installed)'")
        }
    }

    func testStatusRawValuesAreTheJSONContract() {
        XCTAssertEqual(SelfUpdateStatus.allCases.map(\.rawValue),
                       ["up-to-date", "update-available", "ahead", "not-comparable", "lookup-failed"])
    }
}
