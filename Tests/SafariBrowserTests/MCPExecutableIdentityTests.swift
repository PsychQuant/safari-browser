import Darwin
import Foundation
import MachO
import XCTest
@testable import SafariBrowser

final class MCPExecutableIdentityTests: XCTestCase {
    typealias Architecture = MCPExecutableIdentity.Architecture
    let arm = Architecture(cpuType: 0x0100000c, cpuSubtype: 0)
    let x86 = Architecture(cpuType: 0x01000007, cpuSubtype: 3)
    let uuid = "000102030405060708090a0b0c0d0e0f"

    func word(_ value: UInt64, bytes: Int = 4, big: Bool = false) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ((big ? bytes - 1 - $0 : $0) * 8)) })
    }
    func set(_ data: inout Data, _ offset: Int, _ value: UInt64, bytes: Int = 4, big: Bool = false) {
        data.replaceSubrange(offset..<(offset + bytes), with: word(value, bytes: bytes, big: big))
    }
    func thin(_ architecture: Architecture? = nil, big: Bool = false, seed: UInt8 = 0) -> Data {
        let a = architecture ?? arm
        // Literal Mach-O64 executable, one 24-byte LC_UUID.
        var data = Data()
        for value in [UInt32(0xfeedfacf), UInt32(bitPattern: a.cpuType), UInt32(bitPattern: a.cpuSubtype), 2, 1, 24, 0, 0, 0x1b, 24] {
            data.append(word(UInt64(value), big: big))
        }
        data.append(contentsOf: (0..<16).map { seed &+ UInt8($0) })
        return data
    }
    func fat(wide: Bool = false, big: Bool = true, slices: [(Architecture, Data)]? = nil) -> Data {
        let entries = slices ?? [(x86, thin(x86, seed: 16)), (arm, thin())]
        var data = word(wide ? 0xcafebabf : 0xcafebabe, big: big)
        data.append(word(UInt64(entries.count), big: big))
        for (index, entry) in entries.enumerated() {
            data.append(word(UInt64(UInt32(bitPattern: entry.0.cpuType)), big: big))
            data.append(word(UInt64(UInt32(bitPattern: entry.0.cpuSubtype)), big: big))
            data.append(word(UInt64(4096 * (index + 1)), bytes: wide ? 8 : 4, big: big))
            data.append(word(UInt64(entry.1.count), bytes: wide ? 8 : 4, big: big))
            data.append(word(12, big: big))
            if wide { data.append(word(0, big: big)) }
        }
        for (index, entry) in entries.enumerated() {
            data.append(Data(repeating: 0, count: 4096 * (index + 1) - data.count))
            data.append(entry.1)
        }
        return data
    }
    func temporary(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
    func probe(_ data: Data, architecture: Architecture? = nil) throws -> String {
        var result = ""
        try temporary { directory in
            let url = directory.appendingPathComponent("executable")
            try data.write(to: url)
            result = try MCPExecutableIdentity.readImage(at: url, architecture: architecture ?? arm)
        }
        return result
    }
    func reject(_ data: Data, architecture: Architecture? = nil, file: StaticString = #file, line: UInt = #line) {
        XCTAssertThrowsError(try probe(data, architecture: architecture), file: file, line: line) { error in
            XCTAssertEqual(String(describing: error), "MCP image identity unavailable; restart the server with a supported executable", file: file, line: line)
        }
    }
    func testThinNativeAndSwappedDiskImages() throws {
        XCTAssertEqual(try probe(thin()), uuid)
        XCTAssertEqual(try probe(thin(big: true)), uuid)
        XCTAssertEqual(try probe(thin(x86), architecture: x86), uuid)
    }
    func testFat32And64BothByteOrdersSelectExactLoadedArchitecture() throws {
        for wide in [false, true] {
            for big in [false, true] {
                XCTAssertEqual(try probe(fat(wide: wide, big: big)), uuid)
                XCTAssertEqual(try probe(fat(wide: wide, big: big), architecture: x86), "101112131415161718191a1b1c1d1e1f")
            }
        }
        let subtype = Architecture(cpuType: arm.cpuType, cpuSubtype: 2)
        XCTAssertEqual(try probe(fat(slices: [(arm, thin()), (subtype, thin(subtype, seed: 16))]), architecture: subtype), "101112131415161718191a1b1c1d1e1f")
        let capability = Architecture(cpuType: arm.cpuType, cpuSubtype: Int32(bitPattern: 0x80000000))
        reject(fat(slices: [(capability, thin(capability))]))
    }
    func testDiskRequiresArchitectureAndExecutableFiletype() {
        reject(thin(x86))
        // Same subtype isolates the CPU-type check from subtype validation.
        reject(thin(Architecture(cpuType: x86.cpuType, cpuSubtype: arm.cpuSubtype)))
        var image = thin(); set(&image, 12, 6); reject(image)
        image = thin(); set(&image, 8, 2); reject(image)
        reject(fat(slices: [(arm, thin(x86))]))
        reject(fat(slices: [(x86, thin(x86))]))
    }
    func testLegacyThinAPIKeepsItsAcceptanceAndErrors() throws {
        var image = thin(); set(&image, 4, 0); set(&image, 8, 0); set(&image, 12, 0)
        XCTAssertEqual(try MCPExecutableIdentity.imageIdentifier(header: image), uuid)
        XCTAssertEqual(try MCPWorkerContext.imageIdentifier(header: image), uuid)
        image.append(contentsOf: [0xff, 0xff])
        XCTAssertEqual(try MCPExecutableIdentity.imageIdentifier(header: image), uuid)
        XCTAssertThrowsError(try MCPExecutableIdentity.imageIdentifier(header: thin(big: true)))
    }
    func testMalformedLoadCommandsAndMissingOrDuplicateUUID() {
        var images = [Data(), Data(thin().prefix(31)), Data(thin().dropLast())]
        for (offset, value) in [(16, UInt64(4)), (20, 0xfffffff8), (32, 1), (36, 0), (36, 16), (36, 25), (36, 128)] {
            var data = thin(); set(&data, offset, value); images.append(data)
        }
        var duplicate = thin(); duplicate.append(thin().suffix(24)); set(&duplicate, 16, 2); set(&duplicate, 20, 48); images.append(duplicate)
        var trailing = thin(); trailing.append(Data(repeating: 0, count: 8)); set(&trailing, 20, 32); images.append(trailing)
        var noCommands = thin(); set(&noCommands, 16, 0); set(&noCommands, 20, 0); images.append(noCommands)
        for data in images {
            reject(data)
            XCTAssertThrowsError(try MCPExecutableIdentity.imageIdentifier(header: data))
            XCTAssertThrowsError(try MCPWorkerContext.imageIdentifier(header: data))
        }
    }
    func testRejectsUnknownFormatsAndNonFiles() throws {
        for magic in [UInt64(0), 0xfeedface, 0x7f454c46] {
            var data = thin(); set(&data, 0, magic); reject(data)
        }
        try temporary { directory in
            XCTAssertThrowsError(try MCPExecutableIdentity.readImage(at: directory, architecture: arm))
            XCTAssertThrowsError(try MCPExecutableIdentity.readImage(at: directory.appendingPathComponent("missing"), architecture: arm))
            let fifo = directory.appendingPathComponent("fifo")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertThrowsError(try MCPExecutableIdentity.readImage(at: fifo, architecture: arm))
        }
    }
    func testFatRejectsDuplicateAmbiguousAndOverlappingSlices() {
        reject(fat(slices: [(arm, thin()), (arm, thin(seed: 16))]))
        reject(fat(slices: [(x86, thin(x86)), (x86, thin(x86)), (arm, thin())]))
        var overlap = fat(); set(&overlap, 20, 4140, big: true); reject(overlap)
        var headerOverlap = fat(); set(&headerOverlap, 16, 0, big: true); reject(headerOverlap)
        var subtypeMismatch = fat(); set(&subtypeMismatch, 32, 2, big: true); reject(subtypeMismatch)
    }
    func testFatBoundsOverflowAlignmentAndTruncation() {
        for wide in [false, true] {
            for big in [false, true] {
                var data = fat(wide: wide, big: big); set(&data, 4, 129, big: big); reject(data)
                data = fat(wide: wide, big: big); set(&data, 4, 0, big: big); reject(data)
                reject(Data(fat(wide: wide, big: big).prefix(10)))
                reject(Data(fat(wide: wide, big: big).dropLast()))
                let width = wide ? 8 : 4
                data = fat(wide: wide, big: big); set(&data, 16, wide ? UInt64.max - 8 : 0xfffffff8, bytes: width, big: big); reject(data)
                data = fat(wide: wide, big: big); set(&data, 16 + width, wide ? UInt64.max : 0xffffffff, bytes: width, big: big); reject(data)
                data = fat(wide: wide, big: big); set(&data, 16 + width * 2, 64, big: big); reject(data)
                data = fat(wide: wide, big: big); set(&data, 16, 4097, bytes: width, big: big); reject(data)
                // Matching slice too short even when the containing file has trailing bytes.
                let second = 8 + (wide ? 32 : 20)
                data = fat(wide: wide, big: big); set(&data, second + 8 + width, 32, bytes: width, big: big); reject(data)
            }
        }
    }
    func testLargeSparseFileUsesBoundedHeaders() throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("sparse")
            try thin().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 8 * 1024 * 1024 * 1024)
            try handle.close()
            XCTAssertEqual(try MCPExecutableIdentity.readImage(at: url, architecture: arm), uuid)
            var oversized = thin(); set(&oversized, 20, 64 * 1024 * 1024 + 8)
            let writer = try FileHandle(forWritingTo: url)
            try writer.write(contentsOf: oversized); try writer.close()
            XCTAssertThrowsError(try MCPExecutableIdentity.readImage(at: url, architecture: arm))
        }
    }
    func testEveryOpenObservesAtomicReplacementAndSymlinkRetarget() throws {
        try temporary { directory in
            let first = directory.appendingPathComponent("first")
            let second = directory.appendingPathComponent("second")
            let link = directory.appendingPathComponent("launch")
            try thin().write(to: first)
            try thin(seed: 16).write(to: second)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
            XCTAssertEqual(try MCPExecutableIdentity.readImage(at: link, architecture: arm), uuid)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
            XCTAssertEqual(try MCPExecutableIdentity.readImage(at: link, architecture: arm), "101112131415161718191a1b1c1d1e1f")
            // rename is an actual atomic replacement of the pathname target.
            XCTAssertEqual(rename(first.path, second.path), 0)
            XCTAssertEqual(try MCPExecutableIdentity.readImage(at: link, architecture: arm), uuid)
        }
    }
    func testFatSliceCountBoundaryAndReservedField() throws {
        let slices = (0..<128).map { subtype -> (Architecture, Data) in
            let architecture = Architecture(cpuType: arm.cpuType, cpuSubtype: Int32(subtype))
            return (architecture, thin(architecture))
        }
        XCTAssertEqual(try probe(fat(slices: slices)), uuid)
        let extra = Architecture(cpuType: arm.cpuType, cpuSubtype: 128)
        reject(fat(slices: slices + [(extra, thin(extra))]))
        var reserved = fat(wide: true); set(&reserved, 36, 1, big: true); reject(reserved)
    }
    func testFat64SparseOffsetBeyond32BitRange() throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("wide-offset")
            // A real 64-bit slice offset, well beyond a UInt32, with a tiny header.
            var table = fat(wide: true, slices: [(arm, thin())]).prefix(40)
            set(&table, 16, 0x1_0000_0000, bytes: 8, big: true)
            try table.write(to: url)
            let writer = try FileHandle(forWritingTo: url)
            try writer.seek(toOffset: 0x1_0000_0000)
            try writer.write(contentsOf: thin()); try writer.close()
            XCTAssertEqual(try MCPExecutableIdentity.readImage(at: url, architecture: arm), uuid)
        }
    }
    func testLoadCommandLimitAcceptsExactBoundary() throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("command-boundary")
            var image = thin()
            set(&image, 16, 2); set(&image, 20, 64 * 1024 * 1024)
            image.append(word(0x7777)) // Unknown commands retain the old parser's acceptance.
            image.append(word(64 * 1024 * 1024 - 24))
            try image.write(to: url)
            let writer = try FileHandle(forWritingTo: url)
            try writer.truncate(atOffset: 32 + 64 * 1024 * 1024); try writer.close()
            XCTAssertEqual(try MCPExecutableIdentity.readImage(at: url, architecture: arm), uuid)
            // Still structurally valid, but one aligned command exceeds the disk budget.
            set(&image, 20, 64 * 1024 * 1024 + 8)
            set(&image, 60, 64 * 1024 * 1024 - 16)
            let oversized = try FileHandle(forWritingTo: url)
            try oversized.write(contentsOf: image)
            try oversized.truncate(atOffset: 32 + 64 * 1024 * 1024 + 8); try oversized.close()
            XCTAssertThrowsError(try MCPExecutableIdentity.readImage(at: url, architecture: arm))
        }
    }
    func testActualLaunchPathMatchesLoadedImage() throws {
        XCTAssertEqual(try MCPExecutableIdentity.readImage(at: MCPWorkerContext.executableURL(),
                                                           architecture: MCPExecutableIdentity.currentArchitecture()),
                       try MCPWorkerContext.currentImageIdentifier())
    }
    func testCurrentArchitectureUsesLoadedHeader() throws {
        let pointer = try XCTUnwrap(_dyld_get_image_header(0))
        let actual = try MCPExecutableIdentity.currentArchitecture()
        XCTAssertEqual(actual.cpuType, pointer.pointee.cputype)
        XCTAssertEqual(actual.cpuSubtype, pointer.pointee.cpusubtype)
    }
}
