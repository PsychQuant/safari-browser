import XCTest

@testable import SafariBrowser

/// #304: the daemon handshake carries the stamped build version, so a CLI and a
/// daemon built from different commits no longer shake hands as equal.
final class DaemonBuildIdentityTests: XCTestCase {

    private func identity(_ build: String) -> DaemonProtocol.Version {
        DaemonProtocol.resolveCurrentVersion(env: [:], buildVersion: build)
    }

    func testStampedBuildVersionsMapToIdentities() {
        let rows: [(String, DaemonProtocol.Version)] = [
            ("v2.7.0", .init(semver: "2.7.0", commit: "v2.7.0", dirty: false, vendor: .git)),
            ("v2.7.0-5-gabc1234", .init(semver: "2.7.0", commit: "abc1234", dirty: false, vendor: .git)),
            ("abc1234", .init(semver: "0.0.0", commit: "abc1234", dirty: false, vendor: .git)),
            ("v2.7.0-dirty", .init(semver: "2.7.0", commit: "v2.7.0", dirty: true, vendor: .git)),
            ("v2.7.0-5-gabc1234-dirty", .init(semver: "2.7.0", commit: "abc1234", dirty: true, vendor: .git)),
            ("abc1234-dirty", .init(semver: "0.0.0", commit: "abc1234", dirty: true, vendor: .git)),
        ]
        for (build, expected) in rows {
            XCTAssertEqual(identity(build), expected, build)
        }
    }

    /// Unstamped builds (`swift build`, `swift test`) keep today's defaults
    /// field for field, so nothing changes for them.
    func testUnknownKeepsTodaysDefaults() {
        XCTAssertEqual(identity("unknown"), DaemonProtocol.resolveCurrentVersion(env: [:], buildVersion: "unknown"))
        XCTAssertEqual(identity("unknown"), .init(semver: "1.0.0", commit: "unknown", dirty: false, vendor: .source))
    }

    func testStringsThatAreNotADescribeOutputAreUnknown() {
        for odd in ["", "v2.7", "2.7.0", "v2.7.0-rc1", "ABC1234", "v2.7.0-5-gXYZ", "v2.7.0 ", "abc", "v2.7.0-dirty-dirty"] {
            XCTAssertEqual(identity(odd), identity("unknown"), "'\(odd)'")
        }
    }

    /// #304 Expected: two builds with different identifiers mismatch.
    func testDifferentBuildsMismatchAndTheSameBuildMatches() {
        let pairs: [(String, String, Bool)] = [
            ("v2.7.0", "v2.7.0", true),
            ("v2.7.0-5-gabc1234", "v2.7.0-5-gabc1234", true),
            ("v2.7.0", "v2.8.0", false),
            ("v2.7.0", "v2.7.0-1-gdef5678", false),
            ("v2.7.0-5-gabc1234", "v2.7.0-6-gdef5678", false),
            ("v2.7.0", "v2.7.0-dirty", false),
            ("v2.7.0-dirty", "v2.7.0-dirty", false),     // spec: dirty always mismatches
            ("v2.7.0", "unknown", false),                  // a stamped CLI against an unstamped daemon
            ("unknown", "unknown", true),                  // unchanged for unstamped builds
        ]
        for (server, client, match) in pairs {
            XCTAssertEqual(DaemonProtocol.versionsMatch(server: identity(server), client: identity(client)), match,
                           "\(server) vs \(client)")
        }
    }

    /// Packaging can still set the identity; any non-empty variable wins.
    func testEnvironmentStillOverridesTheStampedVersion() {
        let env = ["SAFARI_BROWSER_BUILD_COMMIT": "feedface"]
        let v = DaemonProtocol.resolveCurrentVersion(env: env, buildVersion: "v2.7.0")
        XCTAssertEqual(v, .init(semver: "1.0.0", commit: "feedface", dirty: false, vendor: .source))
        for key in ["SAFARI_BROWSER_BUILD_SEMVER", "SAFARI_BROWSER_BUILD_DIRTY", "SAFARI_BROWSER_BUILD_VENDOR"] {
            let value = key.hasSuffix("DIRTY") ? "1" : (key.hasSuffix("VENDOR") ? "homebrew" : "9.9.9")
            XCTAssertNotEqual(DaemonProtocol.resolveCurrentVersion(env: [key: value], buildVersion: "v2.7.0").vendor, .git, key)
        }
        // An empty variable does not count as set.
        XCTAssertEqual(DaemonProtocol.resolveCurrentVersion(env: ["SAFARI_BROWSER_BUILD_COMMIT": ""], buildVersion: "v2.7.0").vendor, .git)
    }

    func testCurrentVersionComesFromTheStampedBuildVersion() {
        XCTAssertEqual(DaemonProtocol.resolveCurrentVersion(env: [:]), identity(BuildVersion.value))
    }
}
