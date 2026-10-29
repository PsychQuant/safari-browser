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
    ///
    /// When none of them is set (the normal case: nothing in the build sets
    /// them), the identity comes from the stamped `BuildVersion` (#304), so two
    /// different builds no longer shake hands as equal. Before #304 every
    /// process reported `1.0.0+unknown(source)` and an old daemon silently
    /// served a new CLI. `unknown` (an unstamped `swift build` / `swift test`)
    /// keeps that old default identity.
    static func resolveCurrentVersion(env: [String: String], buildVersion: String = BuildVersion.value) -> Version {
        let keys = ["SAFARI_BROWSER_BUILD_SEMVER", "SAFARI_BROWSER_BUILD_COMMIT",
                    "SAFARI_BROWSER_BUILD_DIRTY", "SAFARI_BROWSER_BUILD_VENDOR"]
        if !keys.contains(where: { env[$0]?.nonEmpty != nil }), let stamped = identity(fromBuildVersion: buildVersion) {
            return stamped
        }
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

    /// `git describe --tags --match 'v[0-9]*' --always --dirty` output → identity:
    /// `vX.Y.Z` → (X.Y.Z, vX.Y.Z); `vX.Y.Z-N-g<hash>` → (X.Y.Z, hash);
    /// a bare hash → (0.0.0, hash); a trailing `-dirty` sets `dirty`. Anything
    /// else, `unknown` included, is nil (the caller keeps the old default).
    static func identity(fromBuildVersion text: String) -> Version? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = buildVersionPattern.firstMatch(in: text, range: range) else { return nil }
        func group(_ i: Int) -> String? {
            Range(match.range(at: i), in: text).map { String(text[$0]) }
        }
        let dirty = group(4) != nil
        if let tag = group(1) {
            return Version(semver: String(tag.dropFirst()), commit: group(2) ?? tag, dirty: dirty, vendor: .git)
        }
        guard let hash = group(3) else { return nil }
        return Version(semver: "0.0.0", commit: hash, dirty: dirty, vendor: .git)
    }

    /// Groups: 1 tag `vX.Y.Z`, 2 hash after a tag, 3 bare hash, 4 `-dirty`.
    private static let buildVersionPattern = try! NSRegularExpression(
        pattern: #"^(?:(v[0-9]+\.[0-9]+\.[0-9]+)(?:-[0-9]+-g([0-9a-f]{7,40}))?|([0-9a-f]{7,40}))(-dirty)?$"#)

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

    /// Transport metadata from a single interpretation of the v2 handshake.
    /// An absent limit denotes a legacy peer, not a guessed default.
    struct Handshake: Decodable, Sendable {
        let version: Version
        let maxRequestLineBytes: Int?

        private enum CodingKeys: String, CodingKey { case version, maxRequestLineBytes }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            version = try fields.decode(Version.self, forKey: .version)
            if fields.contains(.maxRequestLineBytes) {
                // Decimal text avoids JSON number decoders rounding a fractional
                // advertisement into an integer (including values beyond 2^53).
                let text = try fields.decode(String.self, forKey: .maxRequestLineBytes)
                guard let first = text.utf8.first, (49...57).contains(first),
                      text.utf8.allSatisfy({ (48...57).contains($0) }),
                      let limit = Int(text) else {
                    throw DecodingError.dataCorruptedError(forKey: .maxRequestLineBytes,
                        in: fields, debugDescription: "Request line limit must be canonical positive decimal text in Int range")
                }
                maxRequestLineBytes = limit
            } else {
                maxRequestLineBytes = nil
            }
        }
    }

    private struct HandshakeEnvelope: Decodable {
        let metadata: Handshake
        private enum CodingKeys: String, CodingKey { case metadata = "protocol" }
    }

    static func decodeHandshake(_ line: Data) -> Handshake? {
        try? JSONDecoder().decode(HandshakeEnvelope.self, from: line).metadata
    }

    /// Existing v2 envelope with an optional transport limit. Real server
    /// instances supply their reader limit; nil preserves legacy fixtures.
    static func encodeHandshake(version: Version = currentVersion, maxRequestLineBytes: Int? = nil) -> Data {
        var proto: [String: Any] = [
            "name": "persistent-daemon",
            "version": [
                "semver": version.semver,
                "commit": version.commit,
                "dirty": version.dirty,
                "vendor": version.vendor.rawValue,
            ] as [String: Any],
        ]
        if let maxRequestLineBytes {
            precondition(maxRequestLineBytes > 0)
            proto["maxRequestLineBytes"] = String(maxRequestLineBytes)
        }
        return (try? JSONSerialization.data(withJSONObject: ["protocol": proto], options: []))
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
