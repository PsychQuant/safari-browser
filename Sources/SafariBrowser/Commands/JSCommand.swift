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

    @OptionGroup var target: TargetOptions

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

        // Resolve once at the command boundary so (a) `--first-match`
        // multi-match fires its stderr warning at most once and (b)
        // downstream internal `doJavaScript` calls (store/read-length/
        // read-result/delete) cannot race on Safari tab-list changes
        // between chunked reads. The concrete target is a `.windowTab`
        // or `.windowIndex` that resolveToAppleScript passes through
        // unchanged.
        let (initialTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        let profile = target.resolveProfile()
        let documentTarget = try await SafariBridge.resolveToConcreteTarget(
            initialTarget,
            firstMatch: firstMatch,
            warnWriter: warnWriter,
            profile: profile
        )
        let result: String
        if large || output != nil {
            // Intentional code evaluation — this CLI runs user-provided JS by design.
            result = try await SafariBridge.doJavaScriptLarge("eval(\(jsCode.jsStringLiteral))", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
        } else {
            // Wrap user code so both single expressions and multi-line scripts work.
            // eval() is intentional here — this is a browser automation CLI that executes
            // arbitrary user-provided JavaScript by design (same as browser console).
            // Intentional code evaluation — this CLI runs user-provided JS by design.
            _ = try await SafariBridge.doJavaScript(
                "(function(){ try { var r = '' + eval(\(jsCode.jsStringLiteral)); window.__sbLen = r.length; window.__sbResult = r; } catch(e) { window.__sbLen = -1; window.__sbResult = e.message; } })()",
                target: documentTarget,
                firstMatch: firstMatch,
                warnWriter: warnWriter
            )
            let lenStr = try await SafariBridge.doJavaScript("window.__sbLen", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
            // AppleScript returns numbers as "9.0" — parse via Double then truncate
            let len = Int(Double(lenStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)

            if len == -1 {
                let errMsg = try await SafariBridge.doJavaScript("window.__sbResult", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
                _ = try await SafariBridge.doJavaScript("delete window.__sbLen; delete window.__sbResult", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
                throw SafariBrowserError.appleScriptFailed("JavaScript error: \(errMsg)")
            } else if len == 0 {
                result = ""
            } else {
                let stored = try await SafariBridge.doJavaScript("window.__sbResult", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
                if stored.isEmpty && len > 0 {
                    result = try await SafariBridge.doJavaScriptLarge("window.__sbResult", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
                    FileHandle.standardError.write(Data("warning: output was large, used chunked read. Use --large to skip this.\n".utf8))
                } else {
                    result = stored
                }
            }
            _ = try await SafariBridge.doJavaScript("delete window.__sbLen; delete window.__sbResult", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
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
