import Foundation
import XCTest
@testable import SafariBrowser

final class MCPJSONTests: XCTestCase {
    func testScalarTypesAndNestedRoundTripRemainDistinct() throws {
        let source = #"{"n":null,"b":true,"i":9223372036854775807,"d":1.5,"s":"line\n\u0000","a":[false,2]}"#
        let value = try JSONValue.decode(Data(source.utf8))
        XCTAssertEqual(value["n"], .null)
        XCTAssertEqual(value["b"], .bool(true))
        XCTAssertEqual(value["i"], .int(Int64.max))
        XCTAssertEqual(value["d"], .double(1.5))
        XCTAssertEqual(value["s"], .string("line\n\0"))
        XCTAssertNil(value["b"]?.intValue)
        XCTAssertEqual(try JSONValue.decode(value.encoded()), value)
        XCTAssertFalse(try value.encoded().contains(10), "wire encoding has no literal newline")
    }
    func testInvalidJSONAndNonFiniteOutputFail() {
        for source in ["{", "[1,]", "NaN", "{\"x\":Infinity}"] {
            XCTAssertThrowsError(try JSONValue.decode(Data(source.utf8)))
        }
        XCTAssertThrowsError(try JSONValue.double(.nan).encoded())
    }
}
