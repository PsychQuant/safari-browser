import Foundation
import MachO
import XCTest
@testable import SafariBrowser

final class MCPWorkerTests: XCTestCase {
    func image(commandSize: UInt32 = 24, uuid: Bool = true) -> Data {
        var header = mach_header_64()
        header.magic = MH_MAGIC_64
        header.ncmds = 1
        header.sizeofcmds = 24
        var command = uuid_command()
        command.cmd = uuid ? UInt32(LC_UUID) : UInt32(LC_SEGMENT_64)
        command.cmdsize = commandSize
        command.uuid = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
        var data = withUnsafeBytes(of: header) { Data($0) }
        data.append(withUnsafeBytes(of: command) { Data($0) })
        return data
    }
    func testImageUUIDAndMalformedLoadCommands() throws {
        XCTAssertEqual(try MCPWorkerContext.imageIdentifier(header: image()), "000102030405060708090a0b0c0d0e0f")
        for bad in [Data(), image(commandSize: 0), image(commandSize: 128), image(uuid: false), image().dropLast()] {
            XCTAssertThrowsError(try MCPWorkerContext.imageIdentifier(header: Data(bad)))
        }
    }
    func testOrdinaryCLIUnchangedAndChangedWorkerRefused() throws {
        try MCPWorkerContext.validate(environment: [:]) { XCTFail("normal CLI must not inspect image"); return "" }
        try MCPWorkerContext.validate(environment: [MCPWorkerContext.imageKey: "build-a"]) { "build-a" }
        XCTAssertThrowsError(try MCPWorkerContext.validate(environment: [MCPWorkerContext.imageKey: "build-a"]) { "build-b" })
        XCTAssertThrowsError(try MCPWorkerContext.validate(environment: [MCPWorkerContext.imageKey: ""]) { "" })
    }
    func testInternalDirectContextOverridesAllDaemonOptIns() {
        XCTAssertFalse(SafariBridge.shouldUseDaemon(flag: true, env: [MCPWorkerContext.directKey: "1", "SAFARI_BROWSER_DAEMON": "1"], socketExists: { _ in XCTFail("must not inspect socket"); return true }))
        XCTAssertTrue(SafariBridge.shouldUseDaemon(flag: true, env: [:], socketExists: { _ in false }))
    }
}
