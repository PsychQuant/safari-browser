import Foundation
import XCTest
@testable import SafariBrowser

final class NativeUploadTargetConstraintTests: XCTestCase {
    private typealias Constraint = NativeUploadTargetConstraint
    private typealias Matcher = SafariBridge.UrlMatcher

    private func constraint(_ matcher: Matcher?, profile: String? = nil) throws -> Constraint {
        let value = try Constraint.from(.resolvedTab(
            windowID: 42, tabInWindow: 2, rematch: matcher, profile: profile
        ))
        return try XCTUnwrap(value)
    }

    private func decode(_ json: String) throws -> Constraint {
        try JSONDecoder().decode(Constraint.self, from: Data(json.utf8))
    }

    func testExactTargetRejectsChangedSlot() throws {
        let value = try XCTUnwrap(Constraint.from(.urlMatch(.exact("https://example.test/upload"))))
        XCTAssertTrue(value.matches(url: "https://example.test/upload", windowName: "Upload"))
        XCTAssertFalse(value.matches(url: "https://example.test/other", windowName: "Upload"))
    }

    func testAllMatchersPreserveUnicodeAndCaseSemantics() throws {
        let cases: [(Matcher, String, String)] = [
            (.contains("台灣/檔案"), "https://EXAMPLE.test/台灣/檔案?q=1", "https://EXAMPLE.test/台灣/檔"),
            (.contains("Case"), "https://example.test/Case", "https://example.test/case"),
            (.exact("https://EXAMPLE.test/台灣🧪"), "https://EXAMPLE.test/台灣🧪", "https://example.test/台灣🧪"),
            (.endsWith("/台灣/Case🧪"), "https://example.test/台灣/Case🧪", "https://example.test/台灣/case🧪"),
            (.regex(try NSRegularExpression(pattern: "台灣/.+🧪$")), "https://example.test/台灣/Case🧪", "https://example.test/台灣/Case🧪/"),
            (.regex(try NSRegularExpression(pattern: "Case")), "https://example.test/Case", "https://example.test/case"),
        ]
        for (matcher, accepted, rejected) in cases {
            let value = try constraint(matcher)
            XCTAssertTrue(value.matches(url: accepted, windowName: "任意標題"), matcher.description)
            XCTAssertFalse(value.matches(url: rejected, windowName: "任意標題"), matcher.description)
            XCTAssertEqual(value.matches(url: accepted, windowName: ""), matcher.matches(accepted))
        }
    }

    func testProfileAndMatcherBothRequired() throws {
        for matcher in [Matcher.contains("upload"), .exact("https://example.test/upload"), .endsWith("/upload"),
                        .regex(try NSRegularExpression(pattern: "/upload$"))] {
            let value = try constraint(matcher, profile: "工作🧪")
            XCTAssertTrue(value.matches(url: "https://example.test/upload", windowName: "工作🧪 — 頁面 — 子標題"))
            XCTAssertFalse(value.matches(url: "https://example.test/other", windowName: "工作🧪 — 頁面"))
            for name in ["個人 — 頁面", "工作🧪", "工作🧪 - 頁面", "工作🧪X — 頁面", " — 工作🧪"] {
                XCTAssertFalse(value.matches(url: "https://example.test/upload", windowName: name), name)
            }
        }
    }

    func testProfileOnlyUsesExistingFirstSeparatorAndCaseSemantics() throws {
        let value = try constraint(nil, profile: "Work")
        XCTAssertTrue(value.matches(url: "anything", windowName: "Work — Title — More"))
        XCTAssertTrue(value.matches(url: "", windowName: "Work — "))
        XCTAssertFalse(value.matches(url: "anything", windowName: "work — Title"))
        XCTAssertFalse(value.matches(url: "anything", windowName: "Title — Work"))
    }

    func testPositionalTargetsHaveNoConstraint() throws {
        let targets: [SafariBridge.TargetDocument] = [
            .frontWindow, .windowIndex(2), .documentIndex(3), .windowTab(window: 2, tabInWindow: 4),
            .resolvedTab(windowID: 42, tabInWindow: 2, rematch: nil, profile: nil),
        ]
        for target in targets { XCTAssertNil(try Constraint.from(target)) }
    }

    func testJSONRoundTripsAllKindsAndProfileCombinations() throws {
        let matchers: [Matcher?] = [
            nil, .contains("台灣"), .exact("https://example.test/🧪"), .endsWith(".TXT"),
            .regex(try NSRegularExpression(pattern: "^台灣/.+TXT$", options: [.caseInsensitive, .anchorsMatchLines])),
        ]
        for matcher in matchers {
            for profile in [nil, "工作🧪"] as [String?] where matcher != nil || profile != nil {
                let value = try constraint(matcher, profile: profile)
                let decoded = try JSONDecoder().decode(Constraint.self, from: JSONEncoder().encode(value))
                XCTAssertEqual(decoded, value)
                XCTAssertEqual(decoded.matcher, matcher)
                XCTAssertEqual(decoded.profile, profile)
                for url in ["台灣/report.txt", "https://example.test/🧪", "other"] {
                    for name in ["工作🧪 — 標題", "個人 — 標題", "無設定檔"] {
                        XCTAssertEqual(decoded.matches(url: url, windowName: name), value.matches(url: url, windowName: name))
                    }
                }
            }
        }
    }

    func testRegexOptionsPreservedAndAffectMatching() throws {
        let cases: [(String, NSRegularExpression.Options, String)] = [
            ("ABC", .caseInsensitive, "abc"),
            ("a b # comment", .allowCommentsAndWhitespace, "ab"),
            ("a.b", .ignoreMetacharacters, "a.b"),
            ("a.b", .dotMatchesLineSeparators, "a\nb"),
            ("^b$", .anchorsMatchLines, "a\nb\nc"),
            ("a.b", .useUnixLineSeparators, "a\rb"),
            ("\\b台灣\\b", .useUnicodeWordBoundaries, "台灣"),
        ]
        for (pattern, options, accepted) in cases {
            let regex = try NSRegularExpression(pattern: pattern, options: options)
            let value = try constraint(.regex(regex))
            let decoded = try JSONDecoder().decode(Constraint.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(decoded.matcher, .regex(regex))
            XCTAssertTrue(decoded.matches(url: accepted, windowName: ""), "\(pattern): \(options)")
        }
    }

    func testCompiledRegexRetainedAcrossMatches() throws {
        let original = try NSRegularExpression(pattern: "^台灣$", options: .caseInsensitive)
        let value = try constraint(.regex(original))
        guard case .regex(let retained) = value.matcher else { return XCTFail("Missing regex") }
        XCTAssertTrue(retained === original)
        let decoded = try JSONDecoder().decode(Constraint.self, from: JSONEncoder().encode(value))
        guard case .regex(let first) = decoded.matcher else { return XCTFail("Missing decoded regex") }
        for _ in 0..<10 {
            XCTAssertTrue(decoded.matches(url: "台灣", windowName: ""))
            guard case .regex(let current) = decoded.matcher else { return XCTFail("Missing cached regex") }
            XCTAssertTrue(first === current)
        }
    }

    func testClosedSchemaRejectsUnknownFieldsTypesAndCombinations() throws {
        let invalid = [
            #"{}"#, #"[]"#, #"null"#, #"{"profile":null}"#, #"{"profile":42}"#,
            #"{"profile":""}"#, #"{"profile":"Work","script":"do shell script"}"#,
            #"{"matcher":null}"#, #"{"matcher":"upload"}"#,
            #"{"matcher":{"kind":"exact","pattern":"x","extra":true}}"#,
            #"{"matcher":{"kind":"exact","pattern":"x","options":0}}"#,
            #"{"matcher":{"kind":"contains","pattern":"x","options":null}}"#,
            #"{"matcher":{"kind":"endsWith","pattern":"x","profile":"Work"}}"#,
            #"{"matcher":{"kind":"unknown","pattern":"x"}}"#,
            #"{"matcher":{"kind":"exact"}}"#, #"{"matcher":{"pattern":"x"}}"#,
            #"{"matcher":{"kind":1,"pattern":"x"}}"#,
            #"{"matcher":{"kind":"exact","pattern":null}}"#,
            #"{"matcher":{"kind":"exact","pattern":42}}"#,
            #"{"matcher":{"kind":"regex","pattern":"x"}}"#,
            #"{"matcher":{"kind":"regex","pattern":"[","options":0}}"#,
            #"{"matcher":{"kind":"regex","pattern":"x","options":128}}"#,
            #"{"matcher":{"kind":"regex","pattern":"x","options":-1}}"#,
            #"{"matcher":{"kind":"regex","pattern":"x","options":1.5}}"#,
            #"{"matcher":{"kind":"regex","pattern":"x","options":true}}"#,
            #"{"matcher":{"kind":"regex","pattern":"x","options":"1"}}"#,
            #"{"matcher":{"kind":"regex","pattern":"x","options":null}}"#,
            #"{"matcher":{"kind":"regex","pattern":"x","options":18446744073709551616}}"#,
            #"{"matcher":{"kind":"regex","pattern":"x","options":0,"extra":false}}"#,
        ]
        for json in invalid { XCTAssertThrowsError(try decode(json), json) }
    }

    func testConstructionRejectsNULAndUTF8OverLimits() throws {
        for matcher in [Matcher.contains("x\0y"), .exact("x\0y"), .endsWith("x\0y"),
                        .contains(String(repeating: "🧪", count: 16_385))] {
            XCTAssertThrowsError(try Constraint.from(.urlMatch(matcher)))
        }
        for profile in ["", "x\0y", String(repeating: "🧪", count: 1_025)] {
            XCTAssertThrowsError(try constraint(.contains("x"), profile: profile))
        }
        XCTAssertNoThrow(try constraint(.contains(String(repeating: "🧪", count: 16_384))))
        XCTAssertNoThrow(try constraint(nil, profile: String(repeating: "🧪", count: 1_024)))
    }

    func testDecodeRejectsNULAndUTF8OverLimits() throws {
        for kind in ["contains", "exact", "endsWith", "regex"] {
            for pattern in ["x\0y", String(repeating: "🧪", count: 16_385)] {
                var matcher: [String: Any] = ["kind": kind, "pattern": pattern]
                if kind == "regex" { matcher["options"] = 0 }
                let data = try JSONSerialization.data(withJSONObject: ["matcher": matcher])
                XCTAssertThrowsError(try JSONDecoder().decode(Constraint.self, from: data))
            }
        }
        for profile in ["x\0y", String(repeating: "🧪", count: 1_025)] {
            let data = try JSONSerialization.data(withJSONObject: ["profile": profile])
            XCTAssertThrowsError(try JSONDecoder().decode(Constraint.self, from: data))
        }
    }

    func testEmptyMatcherPatternsKeepExistingSemantics() throws {
        for matcher in [Matcher.contains(""), .exact(""), .endsWith("")] {
            let value = try constraint(matcher)
            for url in ["", "https://example.test"] {
                XCTAssertEqual(value.matches(url: url, windowName: ""), matcher.matches(url))
            }
        }
    }
}
