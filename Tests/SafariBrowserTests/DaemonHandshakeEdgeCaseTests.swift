import XCTest
import Foundation
@testable import SafariBrowser

/// Section 5 of `daemon-security-hardening` — handshake edge cases.
/// The protocol version SHALL refuse to match when either side reports
/// a dirty build, OR when the build vendor (git / tarball / homebrew /
/// source) differs. Old single-string format from prior versions
/// SHALL be treated as a non-handshake (mismatch) so prior daemons
/// get restarted on first contact.
final class DaemonHandshakeEdgeCaseTests: XCTestCase {

    // MARK: - Version struct round-trip

    func testEncodeDecodeRoundTrip_preservesAllFields() {
        let v = DaemonProtocol.Version(
            semver: "1.2.3",
            commit: "deadbeef",
            dirty: false,
            vendor: .git
        )
        let data = DaemonProtocol.encodeHandshake(version: v)
        let decoded = DaemonProtocol.decodeHandshakeVersion(data)
        XCTAssertEqual(decoded, v)
    }

    func testDecodeHandshake_oldSingleStringFormat_returnsNil() {
        // Forward-compat: older daemons emitted `{"protocol":{...,"version":"1.0.0"}}`
        // with version as a bare string. The new decoder rejects this as
        // un-parseable, which the client surfaces as protocolError →
        // fallback. The spec scenario "old single-string version format
        // → mismatch" requires this be treated as a non-handshake.
        let oldFormat = Data(#"{"protocol":{"name":"persistent-daemon","version":"1.0.0"}}"#.utf8)
        XCTAssertNil(DaemonProtocol.decodeHandshakeVersion(oldFormat),
                     "old string-only format must NOT decode as new Version struct")
    }

    func testDecodeHandshake_garbage_returnsNil() {
        XCTAssertNil(DaemonProtocol.decodeHandshakeVersion(Data("not json".utf8)))
        XCTAssertNil(DaemonProtocol.decodeHandshakeVersion(Data(#"{"foo":"bar"}"#.utf8)))
    }

    // MARK: - versionsMatch (5.2)

    func testVersionsMatch_cleanIdenticalCommits_match() {
        let v = DaemonProtocol.Version(semver: "1.0.0", commit: "abc1234", dirty: false, vendor: .git)
        XCTAssertTrue(DaemonProtocol.versionsMatch(server: v, client: v),
                      "two clean equal versions must match")
    }

    func testVersionsMatch_serverDirty_mismatch() {
        let server = DaemonProtocol.Version(semver: "1.0.0", commit: "abc1234", dirty: true, vendor: .git)
        let client = DaemonProtocol.Version(semver: "1.0.0", commit: "abc1234", dirty: false, vendor: .git)
        XCTAssertFalse(DaemonProtocol.versionsMatch(server: server, client: client),
                       "server.dirty=true MUST cause mismatch even when commits agree")
    }

    func testVersionsMatch_clientDirty_mismatch() {
        let server = DaemonProtocol.Version(semver: "1.0.0", commit: "abc1234", dirty: false, vendor: .git)
        let client = DaemonProtocol.Version(semver: "1.0.0", commit: "abc1234", dirty: true, vendor: .git)
        XCTAssertFalse(DaemonProtocol.versionsMatch(server: server, client: client),
                       "client.dirty=true MUST cause mismatch even when commits agree")
    }

    func testVersionsMatch_bothDirty_mismatch() {
        let v = DaemonProtocol.Version(semver: "1.0.0", commit: "abc1234", dirty: true, vendor: .git)
        XCTAssertFalse(DaemonProtocol.versionsMatch(server: v, client: v),
                       "two dirty builds must NOT match — WIP daemon must be restarted")
    }

    func testVersionsMatch_differentVendor_mismatch() {
        // A homebrew-built daemon and a tarball-built CLI may resolve to
        // the same `semver`+`commit` triple but were assembled by
        // different toolchains; SDK / Swift version drift is a real risk
        // that the spec requires we surface as mismatch.
        let server = DaemonProtocol.Version(semver: "1.0.0", commit: "abc1234", dirty: false, vendor: .homebrew)
        let client = DaemonProtocol.Version(semver: "1.0.0", commit: "abc1234", dirty: false, vendor: .tarball)
        XCTAssertFalse(DaemonProtocol.versionsMatch(server: server, client: client),
                       "vendor mismatch MUST cause mismatch even when commits agree")
    }

    func testVersionsMatch_differentCommit_mismatch() {
        let server = DaemonProtocol.Version(semver: "1.0.0", commit: "abc1234", dirty: false, vendor: .git)
        let client = DaemonProtocol.Version(semver: "1.0.0", commit: "deadbeef", dirty: false, vendor: .git)
        XCTAssertFalse(DaemonProtocol.versionsMatch(server: server, client: client))
    }

    func testVersionsMatch_differentSemver_mismatch() {
        let server = DaemonProtocol.Version(semver: "1.0.0", commit: "abc1234", dirty: false, vendor: .git)
        let client = DaemonProtocol.Version(semver: "2.0.0", commit: "abc1234", dirty: false, vendor: .git)
        XCTAssertFalse(DaemonProtocol.versionsMatch(server: server, client: client))
    }

    // MARK: - resolveCurrentVersion env-driven (5.1)

    func testResolveCurrentVersion_defaultsWhenEnvUnset() {
        let v = DaemonProtocol.resolveCurrentVersion(env: [:])
        // Defaults: vendor = source (locally-built), dirty = false.
        // Semver / commit fall to known defaults so handshake still
        // produces a parseable struct in CI / dev shells.
        XCTAssertEqual(v.vendor, .source)
        XCTAssertFalse(v.dirty)
        XCTAssertFalse(v.semver.isEmpty)
        XCTAssertFalse(v.commit.isEmpty)
    }

    func testResolveCurrentVersion_envOverrides() {
        let env = [
            "SAFARI_BROWSER_BUILD_SEMVER": "9.9.9",
            "SAFARI_BROWSER_BUILD_COMMIT": "feedface",
            "SAFARI_BROWSER_BUILD_DIRTY": "1",
            "SAFARI_BROWSER_BUILD_VENDOR": "homebrew",
        ]
        let v = DaemonProtocol.resolveCurrentVersion(env: env)
        XCTAssertEqual(v.semver, "9.9.9")
        XCTAssertEqual(v.commit, "feedface")
        XCTAssertTrue(v.dirty)
        XCTAssertEqual(v.vendor, .homebrew)
    }

    func testResolveCurrentVersion_dirtyOnlyWhenLiteralOne() {
        // Strict match — `"true"` / `"yes"` / `"on"` do NOT trigger.
        for nonEnabling in ["true", "yes", "on", "0", ""] {
            let env = ["SAFARI_BROWSER_BUILD_DIRTY": nonEnabling]
            let v = DaemonProtocol.resolveCurrentVersion(env: env)
            XCTAssertFalse(v.dirty, "value '\(nonEnabling)' must NOT enable dirty flag")
        }
    }

    func testResolveCurrentVersion_unknownVendorFallsToSource() {
        let env = ["SAFARI_BROWSER_BUILD_VENDOR": "homebrewx"]
        let v = DaemonProtocol.resolveCurrentVersion(env: env)
        XCTAssertEqual(v.vendor, .source, "unknown vendor must fall back to source")
    }
}
