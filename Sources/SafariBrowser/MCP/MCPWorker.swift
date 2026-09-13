import ArgumentParser
import Foundation
import MachO

/// Build identity, not a replacement for macOS code signing or permissions.
enum MCPWorkerContext {
    static let imageKey = "SAFARI_BROWSER_MCP_IMAGE_ID"
    static let directKey = "SAFARI_BROWSER_MCP_DIRECT"

    static func imageIdentifier(header data: Data) throws -> String {
        let invalid = ValidationError("MCP image identity unavailable; restart the server with a supported executable")
        let headerSize = MemoryLayout<mach_header_64>.size
        guard data.count >= headerSize else { throw invalid }
        let header = data.withUnsafeBytes { $0.loadUnaligned(as: mach_header_64.self) }
        guard header.magic == MH_MAGIC_64,
              UInt64(header.sizeofcmds) <= UInt64(data.count - headerSize),
              header.ncmds <= header.sizeofcmds / 8 else { throw invalid }
        let end = headerSize + Int(header.sizeofcmds)
        var offset = headerSize
        var identifier: String?
        for _ in 0..<header.ncmds {
            guard offset <= end - 8 else { throw invalid }
            let command = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: load_command.self) }
            guard command.cmdsize >= 8, command.cmdsize % 8 == 0,
                  Int(command.cmdsize) <= end - offset else { throw invalid }
            if command.cmd == LC_UUID {
                guard command.cmdsize == MemoryLayout<uuid_command>.size, identifier == nil else { throw invalid }
                identifier = data[(offset + 8)..<(offset + 24)].map { String(format: "%02x", $0) }.joined()
            }
            offset += Int(command.cmdsize)
        }
        guard offset == end, let identifier else { throw invalid }
        return identifier
    }

    static func currentImageIdentifier() throws -> String {
        guard let pointer = _dyld_get_image_header(0), pointer.pointee.magic == MH_MAGIC_64,
              pointer.pointee.sizeofcmds <= 64 * 1024 * 1024 else {
            throw ValidationError("MCP requires an identifiable Mach-O executable")
        }
        return try imageIdentifier(header: Data(bytes: pointer, count: MemoryLayout<mach_header_64>.size + Int(pointer.pointee.sizeofcmds)))
    }

    static func executableURL() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0, size < 1024 * 1024 else { throw ValidationError("Cannot locate MCP executable") }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { throw ValidationError("Cannot locate MCP executable") }
        return URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).standardizedFileURL
    }

    static func subprocessArguments(executable: URL, arguments: [String], environment: [String: String]) throws -> [String] {
        guard environment[directKey] == "1", environment[imageKey] != nil else { return arguments }
        guard executable.standardizedFileURL.resolvingSymlinksInPath()
                == (try executableURL()).standardizedFileURL.resolvingSymlinksInPath() else { return arguments }
        // Even a replacement predating the image guard rejects this hidden entry
        // before it can execute an ordinary command from the old catalog.
        return ["__mcp-exec"] + arguments
    }

    static func validate(environment: [String: String], currentImage: () throws -> String) throws {
        guard let expected = environment[imageKey] else { return }
        guard !expected.isEmpty, try currentImage() == expected else {
            throw ValidationError("MCP executable changed; restart the MCP server before calling tools. The command was not executed.")
        }
    }
}

struct MCPWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__mcp-exec", shouldDisplay: false)
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []

    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[MCPWorkerContext.imageKey] != nil, environment[MCPWorkerContext.directKey] == "1" else {
            throw ValidationError("This command is an internal MCP worker")
        }
        // The normal main entry point has already checked the loaded image.
        var command = try SafariBrowser.parseAsRoot(arguments)
        // The public catalog excludes hidden commands. Internal daemon start
        // also uses this guard to launch its hidden service, which detaches itself.
        guard !(command is MCPWorkerCommand),
              type(of: command).configuration.commandName != "mcp" else {
            throw ValidationError("Recursive or hidden MCP dispatch is not allowed")
        }
        if var asynchronous = command as? AsyncParsableCommand {
            try await asynchronous.run()
        } else {
            try command.run()
        }
    }
}
