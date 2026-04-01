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
            // eval() wrapping supports multi-line scripts (intentional — CLI executes user JS)
            result = try await SafariBridge.doJavaScriptLarge("eval(\(jsCode.jsStringLiteral))")
        } else {
            // Wrap user code so both single expressions and multi-line scripts work.
            // eval() is intentional here — this is a browser automation CLI that executes
            // arbitrary user-provided JavaScript by design (same as browser console).
            _ = try await SafariBridge.doJavaScript(
                "(function(){ try { var r = '' + eval(\(jsCode.jsStringLiteral)); window.__sbLen = r.length; window.__sbResult = r; } catch(e) { window.__sbLen = -1; window.__sbResult = e.message; } })()"
            )
            let lenStr = try await SafariBridge.doJavaScript("window.__sbLen")
            // AppleScript returns numbers as "9.0" — parse via Double then truncate
            let len = Int(Double(lenStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)

            if len == -1 {
                // JS execution error
                let errMsg = try await SafariBridge.doJavaScript("window.__sbResult")
                _ = try await SafariBridge.doJavaScript("delete window.__sbLen; delete window.__sbResult")
                throw SafariBrowserError.appleScriptFailed("JavaScript error: \(errMsg)")
            } else if len == 0 {
                // Genuinely empty — no retry needed
                result = ""
            } else {
                // Try reading the stored result
                let stored = try await SafariBridge.doJavaScript("window.__sbResult")
                if stored.isEmpty && len > 0 {
                    // Truncated — read via chunks (no re-execution of user JS)
                    result = try await SafariBridge.doJavaScriptLarge("window.__sbResult")
                    FileHandle.standardError.write(Data("warning: output was large, used chunked read. Use --large to skip this.\n".utf8))
                } else {
                    result = stored
                }
            }
            _ = try await SafariBridge.doJavaScript("delete window.__sbLen; delete window.__sbResult")
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
