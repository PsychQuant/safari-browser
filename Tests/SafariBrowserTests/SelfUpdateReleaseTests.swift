import XCTest

@testable import SafariBrowser

/// #314: what a `releases/latest` answer has to look like before anything is
/// downloaded from it.
final class SelfUpdateReleaseTests: XCTestCase {

    static let prefix = "https://github.com/PsychQuant/safari-browser/releases/download/"

    static func asset(_ name: String, tag: String = "v2.8.0", size: Int = 100, url: String? = nil) -> [String: Any] {
        ["name": name, "size": size, "browser_download_url": url ?? "\(prefix)\(tag)/\(name)"]
    }

    static func release(tag: String = "v2.8.0", draft: Bool = false, prerelease: Bool = false,
                        assets: [[String: Any]]? = nil) -> Data {
        let body: [String: Any] = [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": assets ?? [asset("safari-browser", tag: tag, size: 14_974_288),
                                 asset("safari-browser.sha256", tag: tag, size: 65)],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testWellFormedReleaseParses() throws {
        let release = try SelfUpdateRelease.parse(Self.release())
        XCTAssertEqual(release.tag, "v2.8.0")
        XCTAssertEqual(release.binaryURL.absoluteString, "\(Self.prefix)v2.8.0/safari-browser")
        XCTAssertEqual(release.checksumURL.absoluteString, "\(Self.prefix)v2.8.0/safari-browser.sha256")
        XCTAssertEqual(release.binarySize, 14_974_288)
    }

    func testOtherAssetsAreIgnored() throws {
        let data = Self.release(assets: [Self.asset("safari-browser"), Self.asset("safari-browser.sha256"),
                                         Self.asset("NOTARIZATION.json")])
        XCTAssertEqual(try SelfUpdateRelease.parse(data).tag, "v2.8.0")
    }

    func testTagShapeIsChecked() {
        for tag in ["2.8.0", "v2.8", "v2.8.0-rc1", "idd-314-baseline", ""] {
            XCTAssertThrowsError(try SelfUpdateRelease.parse(Self.release(tag: tag)), tag) { error in
                guard case SelfUpdateError.tagShape = error else { return XCTFail("\(tag): \(error)") }
            }
        }
    }

    func testDraftAndPrereleaseAreRefused() {
        XCTAssertThrowsError(try SelfUpdateRelease.parse(Self.release(draft: true)))
        XCTAssertThrowsError(try SelfUpdateRelease.parse(Self.release(prerelease: true)))
    }

    func testMissingAndDuplicatedAssetsAreRefusedByName() {
        XCTAssertThrowsError(try SelfUpdateRelease.parse(Self.release(assets: [Self.asset("safari-browser.sha256")]))) {
            XCTAssertEqual($0 as? SelfUpdateError, .assetMissing("safari-browser"))
        }
        XCTAssertThrowsError(try SelfUpdateRelease.parse(Self.release(assets: [Self.asset("safari-browser")]))) {
            XCTAssertEqual($0 as? SelfUpdateError, .assetMissing("safari-browser.sha256"))
        }
        let dup = [Self.asset("safari-browser"), Self.asset("safari-browser"), Self.asset("safari-browser.sha256")]
        XCTAssertThrowsError(try SelfUpdateRelease.parse(Self.release(assets: dup))) {
            XCTAssertEqual($0 as? SelfUpdateError, .assetDuplicated("safari-browser"))
        }
    }

    func testAssetHostedElsewhereIsRefusedNamingThePrefix() {
        let cases = [
            "https://github.com/someone/else/releases/download/v2.8.0/safari-browser",
            "https://github.com/PsychQuant/safari-browser/releases/download/v2.7.0/safari-browser",
            "http://github.com/PsychQuant/safari-browser/releases/download/v2.8.0/safari-browser",
            "https://evil.example/PsychQuant/safari-browser/releases/download/v2.8.0/safari-browser",
        ]
        for url in cases {
            let data = Self.release(assets: [Self.asset("safari-browser", url: url), Self.asset("safari-browser.sha256")])
            XCTAssertThrowsError(try SelfUpdateRelease.parse(data), url) { error in
                guard case SelfUpdateError.assetURL(let message) = error else { return XCTFail("\(url): \(error)") }
                XCTAssertTrue(message.contains("\(Self.prefix)v2.8.0/"), message)
            }
        }
    }

    func testSizeLimits() {
        let big = Self.release(assets: [Self.asset("safari-browser", size: 64 * 1024 * 1024 + 1),
                                        Self.asset("safari-browser.sha256")])
        XCTAssertThrowsError(try SelfUpdateRelease.parse(big)) { error in
            guard case SelfUpdateError.assetTooLarge = error else { return XCTFail("\(error)") }
        }
        let bigSum = Self.release(assets: [Self.asset("safari-browser"), Self.asset("safari-browser.sha256", size: 1025)])
        XCTAssertThrowsError(try SelfUpdateRelease.parse(bigSum))
    }

    func testNotJSONIsMalformed() {
        XCTAssertThrowsError(try SelfUpdateRelease.parse(Data("<html>rate limited</html>".utf8))) { error in
            guard case SelfUpdateError.malformedRelease = error else { return XCTFail("\(error)") }
        }
    }
}

/// #314: the asset names `self-update` downloads are produced by
/// `scripts/release.sh`; renaming one side alone must fail here, not at the
/// next real update.
final class SelfUpdateReleaseContractTests: XCTestCase {
    func testAssetNamesMatchTheReleaseScript() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/release.sh"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(?m)^BINARY_NAME="\$\{BINARY_NAME:-([^}"]+)\}"$"#)
        let found = try XCTUnwrap(regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
                                  "release.sh no longer sets BINARY_NAME the way this test reads it")
        let name = String(script[try XCTUnwrap(Range(found.range(at: 1), in: script))])
        XCTAssertEqual(name, SelfUpdateConstants.binaryAssetName)
        XCTAssertEqual(SelfUpdateConstants.checksumAssetName, "\(name).sha256")
        XCTAssertTrue(script.contains(#""$STAGE/$BINARY_NAME.sha256""#), "release.sh no longer writes <name>.sha256")
    }
}
