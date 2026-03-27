import ArgumentParser
import Foundation

struct JSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "js",
        abstract: "Execute JavaScript in the current tab"
    )

    @Option(name: .long, help: "Execute JavaScript from a file")
    var file: String?

    @Option(name: .long, help: "Write result to file (for large outputs)")
    var output: String?

    @Flag(name: .long, help: "Use chunked read for large results")
    var large = false

    @Argument(help: "JavaScript code to execute")
    var code: String?

    func validate() throws {
        if file == nil && code == nil {
            throw ValidationError("Provide JavaScript code as an argument or use --file")
        }
    }

    func run() async throws {
        let jsCode: String
        if let file {
            let path = (file as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw SafariBrowserError.fileNotFound(file)
            }
            jsCode = try String(contentsOfFile: path, encoding: .utf8)
        } else {
            jsCode = code!
        }

        let result: String
        if large || output != nil {
            // Forced large mode or writing to file — use chunked read
            result = try await SafariBridge.doJavaScriptLarge(jsCode)
        } else {
            // Try normal first
            let normalResult = try await SafariBridge.doJavaScript(jsCode)
            if normalResult.isEmpty {
                // Might be silent truncation — retry with chunked read
                result = try await SafariBridge.doJavaScriptLarge(jsCode)
                if !result.isEmpty {
                    FileHandle.standardError.write(Data("warning: output was large, used chunked read. Use --large to skip retry.\n".utf8))
                }
            } else {
                result = normalResult
            }
        }

        if let output {
            let path = (output as NSString).expandingTildeInPath
            try result.write(toFile: path, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("Written \(result.count) bytes to \(output)\n".utf8))
        } else if !result.isEmpty {
            print(result)
        }
    }
}
