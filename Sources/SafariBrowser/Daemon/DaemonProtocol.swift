import Foundation

/// Wire-format constants shared by `DaemonServer` and `DaemonClient`.
///
/// Section 5 of `daemon-security-hardening` evolves the version
/// representation from a bare semver string to a structured
/// `(semver, commit, dirty, vendor)` quadruple. The handshake
/// emitted as the first line on every new connection now carries
/// all four fields so the comparison can refuse to match when:
///
/// - **Either side reports `dirty: true`** (uncommitted changes on the
///   build that produced the binary). This prevents a WIP daemon from
///   serving a fresh CLI even when both nominally share the same
///   commit hash — the on-disk state behind that hash differs.
/// - **The build vendor differs** (git / tarball / homebrew / source).
///   Two distributions of "the same" version may have been assembled
///   by different toolchains; SDK or Swift-version drift is a real
///   risk that the spec requires we surface as mismatch.
///
/// The old single-string format from prior releases (`{"version":"1.0.0"}`)
/// no longer decodes; it surfaces as nil from `decodeHandshakeVersion`,
/// which the client interprets as a protocol error → fallback to
/// stateless. Per spec scenario "old single-string version format →
/// mismatch (forward-compat: old daemons get restarted)".
enum DaemonProtocol {

    /// Origin of the build the binary was produced from. The four
    /// vendor types are the realistic distribution channels: locally
    /// built from a git checkout (the dev case), shipped as a tarball
    /// release, installed via Homebrew, or built from raw source
    /// drop with no metadata. Adding a fifth case here is a wire-format
    /// change and requires a `daemon.shutdown` rolling restart.
    enum Vendor: String, Codable, Sendable, CaseIterable {
        case git, tarball, homebrew, source
    }

    /// Build-identity quadruple. Stored as JSON in the handshake.
    struct Version: Equatable, Codable, Sendable {
        let semver: String
        let commit: String
        let dirty: Bool
        let vendor: Vendor

        /// Human-readable rendering used in error messages and stderr
        /// fallback warnings. Format mirrors `git describe --dirty`
        /// output: `1.0.0+abcdef12-dirty(homebrew)`.
        var description: String {
            let shortCommit = String(commit.prefix(8))
            let dirtyTag = dirty ? "-dirty" : ""
            return "\(semver)+\(shortCommit)\(dirtyTag)(\(vendor.rawValue))"
        }
    }

    /// Resolve the current build's `Version` from an environment dict.
    /// Tests inject specific combinations; production callers use the
    /// process environment via the `currentVersion` static below.
    ///
    /// Build-time metadata SHOULD be injected at link time (e.g. via
    /// a generated `BuildInfo.swift` from the build script), but for
    /// v1 we read from environment variables so the build system
    /// stays untouched. The defaults make every locally-run binary
    /// identify as `vendor=source, dirty=false` — packaging scripts
    /// can override per-distribution.
    ///
    /// Recognized env keys:
    /// - `SAFARI_BROWSER_BUILD_SEMVER`  — defaults to `"1.0.0"`
    /// - `SAFARI_BROWSER_BUILD_COMMIT`  — defaults to `"unknown"`
    /// - `SAFARI_BROWSER_BUILD_DIRTY`   — `"1"` enables; everything else is false
    /// - `SAFARI_BROWSER_BUILD_VENDOR`  — must be one of the `Vendor` cases;
    ///   any other value (including misspellings) falls back to `.source`
    static func resolveCurrentVersion(env: [String: String]) -> Version {
        let semver = env["SAFARI_BROWSER_BUILD_SEMVER"]?.nonEmpty ?? "1.0.0"
        let commit = env["SAFARI_BROWSER_BUILD_COMMIT"]?.nonEmpty ?? "unknown"
        let dirty = env["SAFARI_BROWSER_BUILD_DIRTY"] == "1"
        let vendor: Vendor
        if let raw = env["SAFARI_BROWSER_BUILD_VENDOR"], let v = Vendor(rawValue: raw) {
            vendor = v
        } else {
            vendor = .source
        }
        return Version(semver: semver, commit: commit, dirty: dirty, vendor: vendor)
    }

    /// Cached current version captured at process start from the real
    /// environment. The struct is value-semantics so callers comparing
    /// against `currentVersion` always get the same triple.
    static let currentVersion: Version = resolveCurrentVersion(
        env: ProcessInfo.processInfo.environment
    )

    /// Spec rule: matched iff (a) semver and commit equal, AND (b)
    /// neither side dirty, AND (c) vendor equal. Any single failure
    /// surfaces as mismatch. The dirty rule is asymmetric in spirit
    /// but symmetric in implementation — the rule about WIP daemons
    /// applies regardless of which side carries the local mods.
    static func versionsMatch(server: Version, client: Version) -> Bool {
        if server.dirty || client.dirty { return false }
        if server.vendor != client.vendor { return false }
        return server.semver == client.semver && server.commit == client.commit
    }

    /// Handshake envelope the server writes as the first line after
    /// accepting a connection. The client reads one line and decodes it
    /// via `decodeHandshakeVersion`.
    static func encodeHandshake(version: Version = currentVersion) -> Data {
        let envelope: [String: Any] = [
            "protocol": [
                "name": "persistent-daemon",
                "version": [
                    "semver": version.semver,
                    "commit": version.commit,
                    "dirty": version.dirty,
                    "vendor": version.vendor.rawValue,
                ] as [String: Any],
            ] as [String: Any],
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope, options: []))
            ?? Data("{}".utf8)
    }

    /// Parse a handshake line. Returns the structured `Version` on
    /// success, nil if the line is not a v2-shaped handshake (legacy
    /// string-only format, malformed JSON, missing fields, or unknown
    /// vendor all return nil so the client treats the daemon as
    /// incompatible and falls back).
    static func decodeHandshakeVersion(_ line: Data) -> Version? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: line, options: []) as? [String: Any],
            let proto = obj["protocol"] as? [String: Any],
            let versionDict = proto["version"] as? [String: Any],
            let semver = versionDict["semver"] as? String,
            let commit = versionDict["commit"] as? String,
            let dirty = versionDict["dirty"] as? Bool,
            let vendorRaw = versionDict["vendor"] as? String,
            let vendor = Vendor(rawValue: vendorRaw)
        else {
            return nil
        }
        return Version(semver: semver, commit: commit, dirty: dirty, vendor: vendor)
    }
}

private extension String {
    /// Returns nil when the receiver is empty so `?? "default"` chains
    /// in `resolveCurrentVersion` treat empty env values as unset.
    var nonEmpty: String? { isEmpty ? nil : self }
}
