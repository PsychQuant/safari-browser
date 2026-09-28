import Foundation
import XCTest
@testable import SafariBrowser

final class MCPWorkerWireTests: XCTestCase {
    typealias Wire = MCPWorkerWire
    let id = UUID(uuidString: "12345678-1234-ABCD-ABCD-123456789012")!
    let idText = "12345678-1234-abcd-abcd-123456789012"
    func data(_ text: String) -> Data { Data(text.utf8) }
    func request(_ extra: String = "", arguments: String = "[]", input: String = "\"\"") -> Data {
        data("{\"kind\":\"request\",\"version\":\"1\",\"id\":\"\(idText)\",\"arguments\":\(arguments),\"input\":\(input)\(extra)}")
    }
    func complete(code: String = "\"0\"", reusable: String = "true") -> Data {
        data("{\"kind\":\"complete\",\"version\":\"1\",\"id\":\"\(idText)\",\"exitCode\":\(code),\"reusable\":\(reusable)}")
    }
    func rejectClient(_ frame: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Wire.decodeClient(frame), file: file, line: line) { error in
            XCTAssertEqual(error as? Wire.WireError, .invalidFrame, file: file, line: line)
            XCTAssertEqual(error.localizedDescription, "Invalid private worker frame.", file: file, line: line)
        }
    }
    func rejectServer(_ frame: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Wire.decodeServer(frame), file: file, line: line) { error in
            XCTAssertEqual(error as? Wire.WireError, .invalidFrame, file: file, line: line)
        }
    }
    func testLiteralFixturesAndRoundTripsPreserveBinaryAndArguments() throws {
        XCTAssertEqual(try Wire.decodeClient(data(#"{"kind":"shutdown","version":"1"}"#)), .shutdown)
        XCTAssertEqual(try Wire.decodeClient(request(arguments: #"["wait","0","\n","台灣"]"#, input: #""AP8K""#)),
                       .request(id: id, arguments: ["wait", "0", "\n", "台灣"], input: Data([0, 255, 10])))
        XCTAssertEqual(try Wire.decodeServer(data(#"{"kind":"hello","version":"1","image":"image-a","workerPID":"1","supervisorPID":"2147483647"}"#)),
                       .hello(image: "image-a", workerPID: 1, supervisorPID: .max))
        XCTAssertEqual(try Wire.decodeServer(complete(code: #""255""#, reusable: "false")), .complete(id: id, exitCode: 255, reusable: false))
        let bytes = Data([0, 255, 254, 10, 13]) + data(#"{"kind":"complete","exitCode":"0"}"#)
        let clients: [Wire.ClientMessage] = [.shutdown, .request(id: id, arguments: ["", "a\\b", "\"", "台灣", "\n"], input: bytes)]
        for message in clients {
            let frame = try Wire.encodeClient(message)
            XCTAssertFalse(frame.contains(10))
            XCTAssertEqual(try Wire.decodeClient(frame), message)
        }
        let servers: [Wire.ServerMessage] = [
            .hello(image: "binary\nimage", workerPID: .max, supervisorPID: 1),
            .output(id: id, stream: .stdout, bytes: bytes), .output(id: id, stream: .stderr, bytes: Data()),
            .complete(id: id, exitCode: 0, reusable: true),
            .retire(id: id, reason: .descendants, exitCode: nil),
            .retire(id: id, reason: .io, exitCode: 255), .retire(id: id, reason: .scope, exitCode: 1),
        ]
        for message in servers {
            let frame = try Wire.encodeServer(message)
            XCTAssertFalse(frame.contains(10))
            XCTAssertEqual(try Wire.decodeServer(frame), message)
        }
        XCTAssertEqual(try Wire.decodeServer(data("{\"kind\":\"output\",\"version\":\"1\",\"id\":\"\(idText)\",\"stream\":\"stdout\",\"bytes\":\"AP8K\"}")),
                       .output(id: id, stream: .stdout, bytes: Data([0, 255, 10])))
        XCTAssertEqual(try Wire.decodeServer(data("{\"kind\":\"retire\",\"version\":\"1\",\"id\":\"\(idText)\",\"reason\":\"scope\"}")),
                       .retire(id: id, reason: .scope, exitCode: nil))
    }
    func testClosedShapesMissingNullAndTypeConfusion() {
        for frame in [Data(), data("[]"), data("null"), data("{}"), request(",\"secret-source\":\"secret-input\""),
                      request(arguments: "null"), request(input: "null"), request(arguments: "[true]"), request(input: "42"),
                      data(#"{"kind":"shutdown","version":1}"#), data(#"{"kind":"shutdown","version":true}"#),
                      data(#"{"kind":"shutdown","version":"2"}"#), data(#"{"kind":"shutdown","version":"1","id":null}"#),
                      data(#"{"kind":"shutdown"}"#), data(#"{"kind":"unknown","version":"1"}"#)] { rejectClient(frame) }
        for key in ["kind", "version", "id", "arguments", "input"] {
            var object = try! JSONSerialization.jsonObject(with: request()) as! [String: Any]
            object.removeValue(forKey: key)
            rejectClient(try! JSONSerialization.data(withJSONObject: object))
        }
        for value in ["true", "false", "0", "255", "null", #""00""#, #""+1""#, #""-0""#, #"" 1""#, #""1 ""#, #""1.0""#, #""1e0""#, #""256""#, #""-1""#, #""2147483648""#, #""١""#] {
            rejectServer(complete(code: value))
        }
        for value in ["0", "1", "null", #""true""#] { rejectServer(complete(reusable: value)) }
        for pid in ["true", "1", "null", #""0""#, #""-1""#, #""01""#, #""2147483648""#] {
            rejectServer(data("{\"kind\":\"hello\",\"version\":\"1\",\"image\":\"x\",\"workerPID\":\(pid),\"supervisorPID\":\"1\"}"))
        }
        for extra in [",\"exitCode\":null", ",\"reason2\":\"io\""] {
            rejectServer(data("{\"kind\":\"retire\",\"version\":\"1\",\"id\":\"\(idText)\",\"reason\":\"io\"\(extra)}"))
        }
        rejectServer(data("{\"kind\":\"retire\",\"version\":\"1\",\"id\":\"\(idText)\",\"reason\":\"unknown\"}"))
        rejectServer(data("{\"kind\":\"output\",\"version\":\"1\",\"id\":\"\(idText)\",\"stream\":\"stdin\",\"bytes\":\"\"}"))
    }
    func testCanonicalUUIDBase64AndNUL() throws {
        for value in ["123456781234abcdabcd123456789012", "{\(idText)}", " \(idText)", "not-a-uuid"] {
            rejectClient(data(String(decoding: request(), as: UTF8.self).replacingOccurrences(of: idText, with: value)))
        }
        for value in ["Zg", "Zg=", "Zh==", "Zg===", " Zg==", "Zg==\\n", "____", "!!!!"] {
            rejectClient(request(input: "\"\(value)\""))
        }
        rejectClient(request(arguments: #"["secret\u0000source"]"#))
        XCTAssertThrowsError(try Wire.encodeClient(.request(id: id, arguments: ["secret\0source"], input: Data())))
        XCTAssertEqual(try Wire.decodeClient(request(input: #""Zg==""#)), .request(id: id, arguments: [], input: data("f")))
        let other = UUID()
        XCTAssertEqual(try Wire.decodeServer(Wire.encodeServer(.complete(id: other, exitCode: 0, reusable: true))), .complete(id: other, exitCode: 0, reusable: true))
    }
    func testDuplicateKeysUseOneTypedInterpretation() throws {
        struct Version: Decodable { let version: String }
        for fixture in [#"{"kind":"shutdown","version":"1","version":"2"}"#,
                        #"{"kind":"shutdown","version":"2","version":"1"}"#,
                        #"{"kind":"shutdown","version":"1","version":true}"#] {
            let frame = data(fixture)
            if let version = try? JSONDecoder().decode(Version.self, from: frame), version.version == "1" {
                XCTAssertEqual(try Wire.decodeClient(frame), .shutdown)
            } else { rejectClient(frame) }
        }
        XCTAssertEqual(try Wire.decodeClient(data(#"{"kind":"shutdown","version":"1","version":"1"}"#)), .shutdown)
    }
    func testExactFrameCapsRawLFAndTruncation() throws {
        let shutdown = data(#"{"kind":"shutdown","version":"1"}"#)
        let client = shutdown + Data(repeating: 32, count: 8 * 1024 * 1024 - shutdown.count)
        XCTAssertEqual(try Wire.decodeClient(client), .shutdown)
        rejectClient(client + Data([32]))
        let complete = complete()
        let server = complete + Data(repeating: 32, count: 64 * 1024 - complete.count)
        XCTAssertEqual(try Wire.decodeServer(server), .complete(id: id, exitCode: 0, reusable: true))
        rejectServer(server + Data([32]))
        rejectClient(shutdown + Data([10]))
        rejectClient(data("{\n\"kind\":\"shutdown\",\"version\":\"1\"}"))
        rejectServer(complete + Data([10]))
        for size in 0..<shutdown.count { rejectClient(Data(shutdown.prefix(size))) }
        XCTAssertThrowsError(try Wire.encodeServer(.hello(image: String(repeating: "x", count: 64 * 1024), workerPID: 1, supervisorPID: 2)))
        XCTAssertThrowsError(try Wire.encodeClient(.request(id: id, arguments: [String(repeating: "x", count: 8 * 1024 * 1024)], input: Data())))
    }
    func testExactDecodedPayloadAndArgumentCaps() throws {
        let input = Data(repeating: 255, count: 4 * 1024 * 1024)
        let message = Wire.ClientMessage.request(id: id, arguments: [], input: input)
        XCTAssertEqual(try Wire.decodeClient(Wire.encodeClient(message)), message)
        XCTAssertThrowsError(try Wire.encodeClient(.request(id: id, arguments: [], input: input + Data([0]))))
        rejectClient(request(input: "\"\((input + Data([0])).base64EncodedString())\""))
        let bytes = Data(repeating: 0xff, count: 8192)
        let output = Wire.ServerMessage.output(id: id, stream: .stdout, bytes: bytes)
        XCTAssertEqual(try Wire.decodeServer(Wire.encodeServer(output)), output)
        XCTAssertThrowsError(try Wire.encodeServer(.output(id: id, stream: .stdout, bytes: bytes + Data([0]))))
        rejectServer(data("{\"kind\":\"output\",\"version\":\"1\",\"id\":\"\(idText)\",\"stream\":\"stdout\",\"bytes\":\"\((bytes + Data([0])).base64EncodedString())\"}"))
        let arguments = Array(repeating: "", count: 65536)
        let maxArgs = Wire.ClientMessage.request(id: id, arguments: arguments, input: Data())
        XCTAssertEqual(try Wire.decodeClient(Wire.encodeClient(maxArgs)), maxArgs)
        XCTAssertThrowsError(try Wire.encodeClient(.request(id: id, arguments: arguments + [""], input: Data())))
        rejectClient(request(arguments: "[" + Array(repeating: "\"\"", count: 65537).joined(separator: ",") + "]"))
    }
    func testEveryShapeRejectsUnknownMissingNullAndWrongDirection() throws {
        let fixtures = [
            #"{"kind":"hello","version":"1","image":"image","workerPID":"1","supervisorPID":"2"}"#,
            "{\"kind\":\"output\",\"version\":\"1\",\"id\":\"\(idText)\",\"stream\":\"stderr\",\"bytes\":\"AP8=\"}",
            String(decoding: complete(), as: UTF8.self),
            "{\"kind\":\"retire\",\"version\":\"1\",\"id\":\"\(idText)\",\"reason\":\"descendants\"}",
        ]
        for fixture in fixtures {
            let frame = data(fixture)
            _ = try Wire.decodeServer(frame)
            rejectClient(frame)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
            for key in object.keys {
                var missing = object; missing.removeValue(forKey: key)
                rejectServer(try JSONSerialization.data(withJSONObject: missing))
                var null = object; null[key] = NSNull()
                rejectServer(try JSONSerialization.data(withJSONObject: null))
            }
            var unknown = object; unknown["source"] = "secret-script"
            rejectServer(try JSONSerialization.data(withJSONObject: unknown))
            for size in [1, frame.count / 2, frame.count - 1] { rejectServer(Data(frame.prefix(size))) }
        }
        rejectServer(request())
        rejectServer(data(#"{"kind":"shutdown","version":"1"}"#))
        rejectClient(request(arguments: #"["secret-script"]"#, input: #""secret-input""#))
        XCTAssertThrowsError(try Wire.encodeClient(.request(id: id, arguments: ["secret-script\0"], input: data("secret-input")))) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid private worker frame.")
            XCTAssertEqual(String(describing: error), "invalidFrame")
        }
    }
    func testEncodedFrameExactLimitsAndUnalignedRecordSlice() throws {
        // Literal envelope overhead uses unescaped ASCII. It is independent of encoder field order.
        let clientOverhead = data("{\"kind\":\"request\",\"version\":\"1\",\"id\":\"\(idText)\",\"arguments\":[\"\"],\"input\":\"\"}").count
        let argument = String(repeating: "a", count: 8 * 1024 * 1024 - clientOverhead)
        let client = try Wire.encodeClient(.request(id: id, arguments: [argument], input: Data()))
        XCTAssertEqual(client.count, 8 * 1024 * 1024)
        XCTAssertEqual(try Wire.decodeClient(client), .request(id: id, arguments: [argument], input: Data()))
        XCTAssertThrowsError(try Wire.encodeClient(.request(id: id, arguments: [argument + "a"], input: Data())))
        let serverOverhead = data(#"{"kind":"hello","version":"1","image":"","workerPID":"1","supervisorPID":"2"}"#).count
        let image = String(repeating: "a", count: 64 * 1024 - serverOverhead)
        let server = try Wire.encodeServer(.hello(image: image, workerPID: 1, supervisorPID: 2))
        XCTAssertEqual(server.count, 64 * 1024)
        XCTAssertEqual(try Wire.decodeServer(server), .hello(image: image, workerPID: 1, supervisorPID: 2))
        XCTAssertThrowsError(try Wire.encodeServer(.hello(image: image + "a", workerPID: 1, supervisorPID: 2)))
        let fixture = Data([0xff, 0x31, 0x4d, 0x42, 0x53, 1, 0, 0, 0, 9, 0, 0, 0])
        XCTAssertEqual(try Wire.TerminationRecord.decode(fixture.dropFirst()), .init(workerPID: 1, rawWaitStatus: 9))
    }
    func testEncodeRejectsInvalidMetadata() {
        for pid: Int32 in [0, -1, .min] {
            XCTAssertThrowsError(try Wire.encodeServer(.hello(image: "x", workerPID: pid, supervisorPID: 1)))
            XCTAssertThrowsError(try Wire.encodeServer(.hello(image: "x", workerPID: 1, supervisorPID: pid)))
        }
        for code: Int32 in [-1, 256, .min, .max] {
            XCTAssertThrowsError(try Wire.encodeServer(.complete(id: id, exitCode: code, reusable: true)))
            XCTAssertThrowsError(try Wire.encodeServer(.retire(id: id, reason: .io, exitCode: code)))
        }
    }
    func testTypedImageInvalidationIsNotAnOrdinaryCompletion() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let frame = Data(#"{"kind":"retire","version":"1","id":"00000000-0000-0000-0000-000000000001","reason":"image","exitCode":"64"}"#.utf8)
        XCTAssertEqual(try MCPWorkerWire.decodeServer(frame), .retire(id: id, reason: .image, exitCode: 64))
        XCTAssertEqual(try MCPWorkerWire.decodeServer(MCPWorkerWire.encodeServer(.retire(id: id, reason: .image, exitCode: 64))), .retire(id: id, reason: .image, exitCode: 64))
    }

    func testTerminationLiteralAndValidStatuses() throws {
        let fixture = Data([0x31, 0x4d, 0x42, 0x53, 0x78, 0x56, 0x34, 0x12, 0, 0xff, 0, 0])
        let expected = Wire.TerminationRecord(workerPID: 0x12345678, rawWaitStatus: 0xff00)
        XCTAssertEqual(try Wire.TerminationRecord.decode(fixture), expected)
        XCTAssertEqual(try expected.encode(), fixture)
        for status: Int32 in [0, 0x100, 0xff00, 1, 9, 15, 31, 0x89] {
            let record = Wire.TerminationRecord(workerPID: .max, rawWaitStatus: status)
            XCTAssertEqual(try Wire.TerminationRecord.decode(record.encode()), record)
        }
        for size in 0..<12 { XCTAssertThrowsError(try Wire.TerminationRecord.decode(Data(fixture.prefix(size)))) }
        XCTAssertThrowsError(try Wire.TerminationRecord.decode(fixture + Data([0])))
        var badMagic = fixture; badMagic[0] = 0
        XCTAssertThrowsError(try Wire.TerminationRecord.decode(badMagic))
        for pid: Int32 in [0, -1, .min] {
            XCTAssertThrowsError(try Wire.TerminationRecord(workerPID: pid, rawWaitStatus: 0).encode())
            var frame = fixture
            withUnsafeBytes(of: pid.littleEndian) { frame.replaceSubrange(4..<8, with: $0) }
            XCTAssertThrowsError(try Wire.TerminationRecord.decode(frame))
        }
        for status: Int32 in [-1, 0x7f, 0x137f, 0xffff, 0x80, 32, 0x109, 0x10000, .max] {
            XCTAssertThrowsError(try Wire.TerminationRecord(workerPID: 1, rawWaitStatus: status).encode())
            var frame = fixture
            withUnsafeBytes(of: status.littleEndian) { frame.replaceSubrange(8..<12, with: $0) }
            XCTAssertThrowsError(try Wire.TerminationRecord.decode(frame))
        }
    }
}
