import ArgumentParser
import Foundation
import MachO

/// Build identity, not a replacement for macOS code signing or permissions.
enum MCPWorkerContext {
    static let imageKey = "SAFARI_BROWSER_MCP_IMAGE_ID"
    static let directKey = "SAFARI_BROWSER_MCP_DIRECT"

    static func imageIdentifier(header data: Data) throws -> String {
        try MCPExecutableIdentity.imageIdentifier(header: data)
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

    static var imageChangedError: ValidationError {
        ValidationError("MCP executable changed; restart the MCP server before calling tools. The command was not executed.")
    }

    static func validate(environment: [String: String], currentImage: () throws -> String) throws {
        guard let expected = environment[imageKey] else { return }
        guard !expected.isEmpty, try currentImage() == expected else {
            throw imageChangedError
        }
    }
}

struct MCPWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__mcp-exec", shouldDisplay: false)
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []

    mutating func run() async throws {
        try await run(environment: ProcessInfo.processInfo.environment)
    }

    mutating func run(environment: [String: String],
                      sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws {
        guard environment[MCPWorkerContext.imageKey] != nil, environment[MCPWorkerContext.directKey] == "1" else {
            throw ValidationError("This command is an internal MCP worker")
        }
        // The normal main entry point has already checked the loaded image.
        let command = try SafariBrowser.parseAsRoot(arguments)
        // The public catalog excludes hidden commands. Internal daemon start
        // also uses this guard to launch its hidden service, which detaches itself.
        guard !(command is MCPWorkerCommand),
              type(of: command).configuration.commandName != "mcp" else {
            throw ValidationError("Recursive or hidden MCP dispatch is not allowed")
        }
        try await CLIExecution.runParsed(command, environment: environment, sleep: sleep)
    }
}
