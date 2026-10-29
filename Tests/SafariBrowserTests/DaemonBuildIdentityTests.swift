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
            // verify round 1: shapes `git describe` also prints, which used to
            // fall back to the shared default identity.
            ("v2.8.0-rc1", .init(semver: "2.8.0-rc1", commit: "v2.8.0-rc1", dirty: false, vendor: .git)),
            ("v2.8.0-rc1-3-gabc1234", .init(semver: "2.8.0-rc1", commit: "abc1234", dirty: false, vendor: .git)),
            ("v2.8.0-beta.2-1-gabc1234-dirty", .init(semver: "2.8.0-beta.2", commit: "abc1234", dirty: true, vendor: .git)),
            ("v2.7", .init(semver: "2.7", commit: "v2.7", dirty: false, vendor: .git)),
            ("v2.7.0-3-g1a2b", .init(semver: "2.7.0", commit: "1a2b", dirty: false, vendor: .git)),
            (String(repeating: "a", count: 64), .init(semver: "0.0.0", commit: String(repeating: "a", count: 64), dirty: false, vendor: .git)),
        ]
        for (build, expected) in rows {
            XCTAssertEqual(identity(build), expected, build)
        }
    }

    /// Unstamped builds (`swift build`, `swift test`) keep the old default
    /// identity field for field.
    func testUnknownKeepsTheOldDefaults() {
        XCTAssertEqual(identity("unknown"), .init(semver: "1.0.0", commit: "unknown", dirty: false, vendor: .source))
        XCTAssertEqual(identity(""), identity("unknown"))
    }

    /// verify round 1: any stamp other than `unknown` gets an identity of its
    /// own, never the shared default, and `-dirty` is read whatever the tag looks like.
    func testEveryStampOtherThanUnknownGetsItsOwnIdentity() {
        let stamps = ["v2.7.0", "v2.7.0-5-gabc1234", "abc1234", "v2.8.0-rc1", "v2.8.0-rc2",
                      "v2.8.0-rc1-3-gabc1234", "v2.8.0-rc1-dirty", "v2.8.0+build1", "v2.7", "v2.7-3-gabc1234",
                      "v2.7.0-3-g1a2b", String(repeating: "b", count: 64), "v2.7.0-dirty-dirty", "ABC1234"]
        let unknown = identity("unknown")
        var seen: [(DaemonProtocol.Version, String)] = []
        for stamp in stamps {
            let v = identity(stamp)
            XCTAssertNotEqual(v, unknown, stamp)
            XCTAssertEqual(v.vendor, .git, stamp)
            XCTAssertEqual(v.dirty, stamp.hasSuffix("-dirty"), stamp)
            if let earlier = seen.first(where: { $0.0 == v }) { XCTFail("'\(stamp)' and '\(earlier.1)' share an identity") }
            seen.append((v, stamp))
        }
    }

    /// #304 Expected: two builds with different identifiers mismatch.
    func testDifferentBuildsMismatchAndTheSameBuildMatches() {
        let pairs: [(String, String, Bool)] = [
            ("v2.7.0", "v2.7.0", true),
            ("v2.7.0-5-gabc1234", "v2.7.0-5-gabc1234", true),
            ("v2.8.0-rc1", "v2.8.0-rc1", true),
            ("v2.7.0", "v2.8.0", false),
            ("v2.7.0", "v2.7.0-1-gdef5678", false),
            ("v2.7.0-5-gabc1234", "v2.7.0-6-gdef5678", false),
            ("v2.8.0-rc1", "v2.8.0-rc2", false),
            ("v2.8.0-rc1-3-gabc1234", "v2.8.0-rc1-4-gdef5678", false),
            ("v2.7.0", "v2.7.0-dirty", false),
            ("v2.7.0-dirty", "v2.7.0-dirty", false),     // spec: dirty always mismatches
            ("v2.8.0-rc1-dirty", "v2.8.0-rc1-dirty", false),
            ("v2.7.0", "unknown", false),                  // a stamped daemon against an unstamped client
            ("unknown", "v2.8.0-rc1", false),              // an unstamped daemon against a stamped client
            ("unknown", "unknown", true),                  // unstamped builds still cannot be told apart
        ]
        for (server, client, match) in pairs {
            XCTAssertEqual(DaemonProtocol.versionsMatch(server: identity(server), client: identity(client)), match,
                           "\(server) vs \(client)")
        }
    }

    /// verify round 1: each non-empty variable overrides its own field only; the
    /// other fields still come from the stamp.
    func testEachVariableOverridesOnlyItsOwnField() {
        func resolve(_ env: [String: String]) -> DaemonProtocol.Version {
            DaemonProtocol.resolveCurrentVersion(env: env, buildVersion: "v2.7.0-5-gabc1234")
        }
        XCTAssertEqual(resolve(["SAFARI_BROWSER_BUILD_COMMIT": "feedface"]),
                       .init(semver: "2.7.0", commit: "feedface", dirty: false, vendor: .git))
        XCTAssertEqual(resolve(["SAFARI_BROWSER_BUILD_SEMVER": "9.9.9"]),
                       .init(semver: "9.9.9", commit: "abc1234", dirty: false, vendor: .git))
        XCTAssertEqual(resolve(["SAFARI_BROWSER_BUILD_VENDOR": "homebrew"]),
                       .init(semver: "2.7.0", commit: "abc1234", dirty: false, vendor: .homebrew))
        XCTAssertEqual(resolve(["SAFARI_BROWSER_BUILD_DIRTY": "1"]),
                       .init(semver: "2.7.0", commit: "abc1234", dirty: true, vendor: .git))
        // A set DIRTY other than "1" means not dirty, also over a dirty stamp.
        XCTAssertFalse(DaemonProtocol.resolveCurrentVersion(env: ["SAFARI_BROWSER_BUILD_DIRTY": "0"],
                                                            buildVersion: "v2.7.0-dirty").dirty)
        // An empty variable does not count as set.
        XCTAssertEqual(resolve(["SAFARI_BROWSER_BUILD_COMMIT": ""]), identity("v2.7.0-5-gabc1234"))
        // A misspelled vendor still falls back to `source`, as before #304.
        XCTAssertEqual(resolve(["SAFARI_BROWSER_BUILD_VENDOR": "Git"]).vendor, .source)
        // Over an unstamped build the variables give exactly what they gave before #304.
        XCTAssertEqual(DaemonProtocol.resolveCurrentVersion(env: ["SAFARI_BROWSER_BUILD_COMMIT": "feedface"], buildVersion: "unknown"),
                       .init(semver: "1.0.0", commit: "feedface", dirty: false, vendor: .source))
    }

    /// Wiring only: `currentVersion` uses `BuildVersion.value` by default. Under
    /// `swift test` that is `unknown` on both sides, so the stamped path itself
    /// is measured by hand on a stamped binary (#304 comment).
    func testCurrentVersionDefaultsToTheStampedBuildVersion() {
        XCTAssertEqual(DaemonProtocol.resolveCurrentVersion(env: [:]), identity(BuildVersion.value))
    }

    /// verify round 1: the mismatch message must not cut a tag in half.
    func testDescriptionShortensOnlyHashes() {
        XCTAssertEqual(identity("v2.8.0-rc1").description, "2.8.0-rc1+v2.8.0-rc1(git)")
        XCTAssertEqual(identity("v2.7.0-5-gabc1234def").description, "2.7.0+abc1234d(git)")
    }
}
