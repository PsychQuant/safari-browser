import Foundation
import XCTest
@testable import SafariBrowser

final class DaemonRequestLimitCodecTests: XCTestCase {
    private func header(_ scalar: String?) -> Data {
        let field = scalar.map { ",\"maxRequestLineBytes\":" + $0 } ?? ""
        return Data((#"{"protocol":{"version":{"semver":"2.1.3","commit":"abc","dirty":false,"vendor":"git"}"# + field + "}}").utf8)
    }

    func testLimitScalarsArePositiveExactIntegers() throws {
        for (raw, expected) in [("1", 1), ("1024", 1024),
                                ("9007199254740993", 9007199254740993),
                                (String(Int.max), Int.max)] {
            let decoded = try XCTUnwrap(DaemonProtocol.decodeHandshake(header("\"" + raw + "\"")), raw)
            XCTAssertEqual(decoded.maxRequestLineBytes, expected, raw)
        }
        for raw in ["null", "true", "false", "1", "0", "-1", "1.5", "1e3",
                    "9007199254740993.5", "9223372036854775808", "1e99", "{}", "[]"] {
            XCTAssertNil(DaemonProtocol.decodeHandshake(header(raw)), raw)
        }
        for value in ["", "0", "-1", "+1", "01", " 1", "1 ", "1.0", "1e3", "١", "１",
                      "9007199254740993.5", "9223372036854775808", String(repeating: "9", count: 100)] {
            XCTAssertNil(DaemonProtocol.decodeHandshake(header("\"" + value + "\"")), value)
        }
    }

    func testAbsentLimitRetainsVersionAndUnknownFieldsAreIgnored() throws {
        let legacy = try XCTUnwrap(DaemonProtocol.decodeHandshake(header(nil)))
        XCTAssertNil(legacy.maxRequestLineBytes)
        XCTAssertEqual(legacy.version, DaemonProtocol.decodeHandshakeVersion(header(nil)))
        let extra = Data(String(decoding: header("\"1024\""), as: UTF8.self).replacingOccurrences(
            of: "\"protocol\":{", with: "\"protocol\":{\"future\":true,").utf8)
        XCTAssertEqual(DaemonProtocol.decodeHandshake(extra)?.maxRequestLineBytes, 1024)
    }

    func testEncodingIsCompatibleWithLegacyVersionDecoder() throws {
        let version = try XCTUnwrap(DaemonProtocol.decodeHandshakeVersion(header(nil)))
        for limit in [nil, 1024, Int.max] as [Int?] {
            let encoded = DaemonProtocol.encodeHandshake(version: version, maxRequestLineBytes: limit)
            XCTAssertEqual(DaemonProtocol.decodeHandshakeVersion(encoded), version)
            let decoded = try XCTUnwrap(DaemonProtocol.decodeHandshake(encoded))
            XCTAssertEqual(decoded.version, version)
            XCTAssertEqual(decoded.maxRequestLineBytes, limit)
        }
    }

    func testMalformedVersionDoesNotBecomeValidWithLimit() {
        for replacement in ["\"dirty\":0", "\"dirty\":1", "\"dirty\":null", "\"dirty\":\"false\""] {
            let invalid = String(decoding: header("\"1024\""), as: UTF8.self)
                .replacingOccurrences(of: "\"dirty\":false", with: replacement)
            XCTAssertNil(DaemonProtocol.decodeHandshake(Data(invalid.utf8)))
        }
    }
}
