import Foundation

/// Every way `self-update` can stop. Each names the step that failed; the
/// installed binary is unchanged whenever one of these is thrown (#314).
enum SelfUpdateError: Error, Equatable, CustomStringConvertible {
    case lookup(String)
    case malformedRelease(String)
    case tagShape(String)
    case notPublished(String)
    case assetMissing(String)
    case assetDuplicated(String)
    case assetURL(String)
    case assetTooLarge(name: String, size: Int, limit: Int)
    case download(String)
    case checksumFormat
    case checksumMismatch(expected: String, actual: String)
    case installedNotDeveloperID(String)
    case candidateNotDeveloperID(String)
    case candidateMissingRuntime
    case candidateRequirement(String)
    case versionProbe(String)
    case versionMismatch(expected: String, actual: String)
    case notComparable(String)
    case locate(String)
    case notWritable(String)
    case staging(String)
    case backup(String)
    case install(String)
    case busy(String)
    case installedChanged(String)

    /// The README section with the manual steps; a test checks that it exists.
    static let manualStepsSection = "Install a release binary"
    static let manualSteps = "install it by hand as README.md describes under \"\(manualStepsSection)\""

    var description: String {
        switch self {
        case .lookup(let m): return "release lookup failed: \(m)"
        case .malformedRelease(let m): return "the release answer is not what was expected: \(m)"
        case .tagShape(let t): return "the latest release tag '\(t)' is not of the form vX.Y.Z"
        case .notPublished(let m): return "the latest release is \(m), not a published release"
        case .assetMissing(let n): return "the latest release has no asset named \(n)"
        case .assetDuplicated(let n): return "the latest release has more than one asset named \(n)"
        case .assetURL(let m): return m
        case .assetTooLarge(let n, let s, let l): return "\(n) is \(s) bytes, over the \(l)-byte limit"
        case .download(let m): return "download failed: \(m)"
        case .checksumFormat: return "\(SelfUpdateConstants.checksumAssetName) is not 64 lowercase hex characters"
        case .checksumMismatch(let e, let a): return "checksum mismatch: published \(e), downloaded \(a)"
        case .installedNotDeveloperID(let m):
            return "the installed binary is not a Developer ID build (\(m)), so there is no identity to check a new one against; \(Self.manualSteps)"
        case .candidateNotDeveloperID(let m): return "the downloaded binary is not a Developer ID build: \(m)"
        case .candidateMissingRuntime: return "the downloaded binary is not signed with the hardened runtime"
        case .candidateRequirement(let m):
            return "the downloaded binary does not satisfy the installed binary's designated requirement (\(m))"
        case .versionProbe(let m): return "could not read the downloaded binary's --version: \(m)"
        case .versionMismatch(let e, let a): return "the downloaded binary reports '\(a)', expected '\(e)'"
        case .notComparable(let v):
            return "the installed version '\(v)' cannot be compared with a release; \(Self.manualSteps)"
        case .locate(let m): return "could not locate the installed binary: \(m)"
        case .notWritable(let d): return "\(d) is not writable; self-update does not use sudo"
        case .staging(let m): return "could not stage the download: \(m)"
        case .backup(let m): return "could not keep a backup of the installed binary: \(m)"
        case .install(let m): return "could not replace the installed binary: \(m)"
        case .busy(let m): return "\(m); wait for it to finish"
        case .installedChanged(let p):
            return "\(p) is no longer the binary this process was started from (another update replaced it); run self-update again"
        }
    }
}

/// The parts of a `releases/latest` answer `self-update` acts on, accepted only
/// when every field has the shape `scripts/release.sh` publishes.
struct SelfUpdateRelease: Equatable {
    let tag: String
    let binaryURL: URL
    let binarySize: Int
    let checksumURL: URL
    let checksumSize: Int

    static func parse(_ data: Data) throws -> SelfUpdateRelease {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SelfUpdateError.malformedRelease("not a JSON object")
        }
        guard let tag = object["tag_name"] as? String else {
            throw SelfUpdateError.malformedRelease("no tag_name")
        }
        guard SelfUpdateVersion.components(tag, pattern: SelfUpdateVersion.tagPattern) != nil else {
            throw SelfUpdateError.tagShape(String(tag.prefix(64)))
        }
        for (key, kind) in [("draft", "a draft"), ("prerelease", "a prerelease")] {
            guard let flag = strictBool(object[key]) else {
                throw SelfUpdateError.malformedRelease("\(key) is missing or not a JSON boolean")
            }
            if flag { throw SelfUpdateError.notPublished(kind) }
        }
        guard let assets = object["assets"] as? [[String: Any]] else {
            throw SelfUpdateError.malformedRelease("no assets list")
        }
        let prefix = SelfUpdateConstants.downloadPrefix(tag: tag)
        func pick(_ name: String, limit: Int) throws -> (URL, Int) {
            let matches = assets.filter { ($0["name"] as? String) == name }
            guard !matches.isEmpty else { throw SelfUpdateError.assetMissing(name) }
            guard matches.count == 1 else { throw SelfUpdateError.assetDuplicated(name) }
            guard let text = matches[0]["browser_download_url"] as? String, let size = strictInt(matches[0]["size"]) else {
                throw SelfUpdateError.malformedRelease("asset \(name) has no download URL or size")
            }
            guard text == prefix + name, let url = URL(string: text) else {
                throw SelfUpdateError.assetURL("the download URL of \(name) is not \(prefix)\(name)")
            }
            guard size >= 0, size <= limit else {
                throw SelfUpdateError.assetTooLarge(name: name, size: size, limit: limit)
            }
            return (url, size)
        }
        let binary = try pick(SelfUpdateConstants.binaryAssetName, limit: SelfUpdateConstants.maxBinaryBytes)
        let checksum = try pick(SelfUpdateConstants.checksumAssetName, limit: SelfUpdateConstants.maxChecksumBytes)
        return SelfUpdateRelease(tag: tag, binaryURL: binary.0, binarySize: binary.1,
                                 checksumURL: checksum.0, checksumSize: checksum.1)
    }

    /// A JSON `true`/`false` only — NSNumber bridging would also let `0`/`1` through.
    static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A JSON integer only — not a boolean, not a fraction.
    static func strictInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return number.intValue
    }
}
