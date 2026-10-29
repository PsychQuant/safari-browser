import Foundation

/// Everything `self-update` needs to know about where releases come from (#314).
/// The asset names are a contract with `scripts/release.sh`; a test reads the
/// script and fails when the two drift apart.
enum SelfUpdateConstants {
    static let repository = "PsychQuant/safari-browser"
    static let binaryAssetName = "safari-browser"
    static var checksumAssetName: String { "\(binaryAssetName).sha256" }
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static func downloadPrefix(tag: String) -> String {
        "https://github.com/\(repository)/releases/download/\(tag)/"
    }
    static let maxBinaryBytes = 64 * 1024 * 1024
    static let maxChecksumBytes = 1024
    static let lookupTimeout: TimeInterval = 15
    static let probeTimeout: TimeInterval = 10
    static let requiredEntitlement = "com.apple.security.automation.apple-events"
    static let stagingPrefix = ".safari-browser.self-update."
}

/// The closed set of answers `self-update --check --json` can give. The raw
/// values are the JSON contract consumed by the plugin hook (#155).
enum SelfUpdateStatus: String, CaseIterable, Codable, Equatable {
    case upToDate = "up-to-date"
    case updateAvailable = "update-available"
    case ahead
    case notComparable = "not-comparable"
    case lookupFailed = "lookup-failed"
}

enum SelfUpdateVersion {
    /// `vX.Y.Z`, optionally `-N-g<hash>`, optionally `-dirty` — what
    /// `git describe --tags --match 'v[0-9]*' --always --dirty` prints for a
    /// build at or after a tag. Anything else (a bare hash, `unknown`) has no
    /// release to compare with.
    private static let installedPattern = try! NSRegularExpression(
        pattern: #"^v([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9]+-g[0-9a-f]+)?(-dirty)?$"#)
    static let tagPattern = try! NSRegularExpression(pattern: #"^v([0-9]+)\.([0-9]+)\.([0-9]+)$"#)

    static func components(_ text: String, pattern: NSRegularExpression) -> (base: [Int], hasSuffix: Bool)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        var base: [Int] = []
        for group in 1...3 {
            guard let r = Range(match.range(at: group), in: text), let value = Int(text[r]) else { return nil }
            base.append(value)
        }
        let suffix = match.numberOfRanges > 4
            && (match.range(at: 4).location != NSNotFound || match.range(at: 5).location != NSNotFound)
        return (base, suffix)
    }

    static func classify(installed: String, latestTag: String) -> SelfUpdateStatus {
        guard let current = components(installed, pattern: installedPattern),
              let latest = components(latestTag, pattern: tagPattern) else { return .notComparable }
        if latest.base.lexicographicallyPrecedes(current.base) { return .ahead }
        if current.base.lexicographicallyPrecedes(latest.base) { return .updateAvailable }
        return current.hasSuffix ? .ahead : .upToDate
    }
}
