import ArgumentParser
import Darwin
import Foundation
import MachO

/// Mach-O build identity only; UUIDs do not authenticate code or make a later
/// pathname replacement atomic with execution.
enum MCPExecutableIdentity {
    struct Architecture: Equatable, Hashable {
        let cpuType: Int32
        let cpuSubtype: Int32
    }

    private static let maximumCommands = 64 * 1024 * 1024
    private static let maximumSlices = 128
    private static let headerSize = MemoryLayout<mach_header_64>.size
    private static var invalid: ValidationError {
        ValidationError("MCP image identity unavailable; restart the server with a supported executable")
    }

    private enum ByteOrder {
        case native, little, big

        func uint32(_ data: Data, _ offset: Int) -> UInt32 {
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            switch self {
            case .native: return value
            case .little: return UInt32(littleEndian: value)
            case .big: return UInt32(bigEndian: value)
            }
        }

        func uint64(_ data: Data, _ offset: Int) -> UInt64 {
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            switch self {
            case .native: return value
            case .little: return UInt64(littleEndian: value)
            case .big: return UInt64(bigEndian: value)
            }
        }
    }

    static func currentArchitecture() throws -> Architecture {
        guard let pointer = _dyld_get_image_header(0), pointer.pointee.magic == MH_MAGIC_64 else { throw invalid }
        return Architecture(cpuType: pointer.pointee.cputype, cpuSubtype: pointer.pointee.cpusubtype)
    }

    /// Preserve the loaded-image API: native Mach-O64 only, without adding disk
    /// filetype/architecture restrictions or a new size limit to this parser.
    static func imageIdentifier(header data: Data) throws -> String {
        guard data.count >= headerSize, ByteOrder.native.uint32(data, 0) == MH_MAGIC_64 else { throw invalid }
        return try identifier(data, order: .native)
    }

    private static func identifier(_ data: Data, order: ByteOrder) throws -> String {
        let commandBytes = order.uint32(data, 20)
        let commandCount = order.uint32(data, 16)
        guard UInt64(commandBytes) <= UInt64(data.count - headerSize), commandCount <= commandBytes / 8 else { throw invalid }
        let end = headerSize + Int(commandBytes)
        var offset = headerSize
        var result: String?
        for _ in 0..<commandCount {
            guard offset <= end - 8 else { throw invalid }
            let command = order.uint32(data, offset)
            let size = order.uint32(data, offset + 4)
            guard size >= 8, size % 8 == 0, Int(size) <= end - offset else { throw invalid }
            if command == LC_UUID {
                guard size == MemoryLayout<uuid_command>.size, result == nil else { throw invalid }
                result = data.withUnsafeBytes { bytes in
                    bytes[(offset + 8)..<(offset + 24)].map { String(format: "%02x", $0) }.joined()
                }
            }
            offset += Int(size)
        }
        guard offset == end, let result else { throw invalid }
        return result
    }

    /// Open the original launch path on every probe, including symlinks. The
    /// descriptor pins this one observation through atomic pathname replacement.
    /// Only a small FAT table and the selected header/load commands are read.
    static func readImage(at url: URL, architecture: Architecture) throws -> String {
        guard url.isFileURL else { throw invalid }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw invalid }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0 else { throw invalid }
        let fileSize = UInt64(metadata.st_size)
        let prefix = try read(descriptor, offset: 0, count: 8, fileSize: fileSize)
        let magic = ByteOrder.big.uint32(prefix, 0)
        let order: ByteOrder
        let wide: Bool
        switch magic {
        case 0xfeedfacf, 0xcffaedfe:
            return try readThin(descriptor, offset: 0, size: fileSize, fileSize: fileSize, architecture: architecture)
        case 0xcafebabe: order = .big; wide = false
        case 0xbebafeca: order = .little; wide = false
        case 0xcafebabf: order = .big; wide = true
        case 0xbfbafeca: order = .little; wide = true
        default: throw invalid
        }
        let count = order.uint32(prefix, 4)
        guard count > 0, count <= maximumSlices else { throw invalid }
        let entrySize = wide ? 32 : 20
        // count was bounded before multiplication and allocation.
        let tableEnd = 8 + Int(count) * entrySize
        let table = try read(descriptor, offset: 8, count: tableEnd - 8, fileSize: fileSize)
        var slices: [(architecture: Architecture, offset: UInt64, size: UInt64, end: UInt64)] = []
        var architectures = Set<Architecture>()
        for index in 0..<Int(count) {
            let base = index * entrySize
            let sliceArchitecture = Architecture(cpuType: Int32(bitPattern: order.uint32(table, base)),
                                                 cpuSubtype: Int32(bitPattern: order.uint32(table, base + 4)))
            let offset = wide ? order.uint64(table, base + 8) : UInt64(order.uint32(table, base + 8))
            let size = wide ? order.uint64(table, base + 16) : UInt64(order.uint32(table, base + 12))
            let alignment = order.uint32(table, base + (wide ? 24 : 16))
            let (end, overflow) = offset.addingReportingOverflow(size)
            guard !overflow, offset >= UInt64(tableEnd), size >= UInt64(headerSize), end <= fileSize,
                  alignment < 64, offset % (UInt64(1) << alignment) == 0,
                  architectures.insert(sliceArchitecture).inserted else { throw invalid }
            if wide, order.uint32(table, base + 28) != 0 { throw invalid }
            guard !slices.contains(where: { offset < $0.end && $0.offset < end }) else { throw invalid }
            slices.append((sliceArchitecture, offset, size, end))
        }
        // Use the exact subtype from the loaded header, including capability
        // bits. Masking bits or guessing a native fallback can select another image.
        let matches = slices.filter { $0.architecture == architecture }
        guard matches.count == 1, let selected = matches.first else { throw invalid }
        return try readThin(descriptor, offset: selected.offset, size: selected.size,
                            fileSize: fileSize, architecture: selected.architecture)
    }

    private static func readThin(_ descriptor: Int32, offset: UInt64, size: UInt64,
                                 fileSize: UInt64, architecture: Architecture) throws -> String {
        guard size >= UInt64(headerSize) else { throw invalid }
        let header = try read(descriptor, offset: offset, count: headerSize, fileSize: fileSize)
        let order: ByteOrder
        switch ByteOrder.big.uint32(header, 0) {
        case 0xfeedfacf: order = .big
        case 0xcffaedfe: order = .little
        default: throw invalid
        }
        guard Int32(bitPattern: order.uint32(header, 4)) == architecture.cpuType,
              Int32(bitPattern: order.uint32(header, 8)) == architecture.cpuSubtype,
              order.uint32(header, 12) == MH_EXECUTE else { throw invalid }
        let commandBytes = order.uint32(header, 20)
        guard commandBytes <= maximumCommands,
              order.uint32(header, 16) <= commandBytes / 8,
              UInt64(commandBytes) <= size - UInt64(headerSize) else { throw invalid }
        let (commandOffset, overflow) = offset.addingReportingOverflow(UInt64(headerSize))
        guard !overflow else { throw invalid }
        var data = header
        data.append(try read(descriptor, offset: commandOffset, count: Int(commandBytes), fileSize: fileSize))
        return try identifier(data, order: order)
    }

    private static func read(_ descriptor: Int32, offset: UInt64, count: Int, fileSize: UInt64) throws -> Data {
        guard count >= 0, count <= maximumCommands else { throw invalid }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(count))
        guard !overflow, end <= fileSize, end <= UInt64(Int64.max) else { throw invalid }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var completed = 0
            while completed < count {
                let amount = pread(descriptor, bytes.baseAddress!.advanced(by: completed), count - completed,
                                   off_t(offset + UInt64(completed)))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw invalid }
                completed += amount
            }
        }
        return data
    }
}
