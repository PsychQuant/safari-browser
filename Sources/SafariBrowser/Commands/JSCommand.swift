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
            result = try await runLargePath(jsCode, target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
        } else {
            // #76: user code is inlined into the injected string instead of
            // routed through page-context eval() — strict-CSP pages refuse
            // eval, while `do JavaScript` itself is UA-privileged and exempt.
            // Expression form first (preserves `js "1+1"` → "2"); when the
            // wrapper never ran (SyntaxError is swallowed silently by
            // `do JavaScript`), retry as a function body (statements; use
            // `return` for a value). The preset clears stale globals from a
            // crashed prior run so the sentinel read only ever reflects
            // this invocation.
            _ = try await SafariBridge.doJavaScript(JSWrapper.presetProtocolGlobals, target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
            _ = try await SafariBridge.doJavaScript(
                JSWrapper.expressionWrapper(jsCode),
                target: documentTarget,
                firstMatch: firstMatch,
                warnWriter: warnWriter
            )
            var lenStr = try await SafariBridge.doJavaScript("String(window.__sbLen)", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
            if lenStr.trimmingCharacters(in: .whitespacesAndNewlines) == JSWrapper.lenUnsetSentinel {
                _ = try await SafariBridge.doJavaScript(
                    JSWrapper.statementWrapper(jsCode),
                    target: documentTarget,
                    firstMatch: firstMatch,
                    warnWriter: warnWriter
                )
                lenStr = try await SafariBridge.doJavaScript("String(window.__sbLen)", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
                if lenStr.trimmingCharacters(in: .whitespacesAndNewlines) == JSWrapper.lenUnsetSentinel {
                    throw SafariBrowserError.appleScriptFailed(
                        "JavaScript syntax error: the provided code parses neither as an expression nor as a function body. (Safari's `do JavaScript` swallows the SyntaxError detail; check the code with a linter.)"
                    )
                }
            }
            // AppleScript returns numbers as "9.0" — parse via Double then truncate
            let len = Int(Double(lenStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)

            if len == -1 {
                let errMsg = try await SafariBridge.doJavaScript("window.__sbResult", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
                _ = try await SafariBridge.doJavaScript("delete window.__sbLen; delete window.__sbResult", target: documentTarget, firstMatch: firstMatch, warnWriter: warnWriter)
                // #76: user code calling eval()/new Function() on a strict-CSP
                // page surfaces here as a caught EvalError — append the hint.
                throw SafariBrowserError.appleScriptFailed("JavaScript error: \(errMsg)\(JSWrapper.cspEvalHint(for: errMsg) ?? "")")
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

    /// #76: `--large` / `--output` path without page-context eval().
    /// doJavaScriptLarge wraps its argument as `'' + (code)`, so the
    /// expression form is just newline-guarded parens. Parse failure is
    /// detected the same way as the non-large path: preset the protocol
    /// globals, then check whether the wrapper ever set __sbResultLen.
    private func runLargePath(
        _ jsCode: String,
        target: SafariBridge.TargetDocument,
        firstMatch: Bool,
        warnWriter: ((String) -> Void)?
    ) async throws -> String {
        _ = try await SafariBridge.doJavaScript(JSWrapper.presetLargeProtocolGlobals, target: target, firstMatch: firstMatch, warnWriter: warnWriter)
        do {
            var result = try await SafariBridge.doJavaScriptLarge(JSWrapper.largeExpression(jsCode), target: target, firstMatch: firstMatch, warnWriter: warnWriter)
            if result.isEmpty {
                let marker = try await SafariBridge.doJavaScript("String(window.__sbResultLen)", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
                if marker.trimmingCharacters(in: .whitespacesAndNewlines) == JSWrapper.lenUnsetSentinel {
                    // Expression form never parsed — retry as function body.
                    result = try await SafariBridge.doJavaScriptLarge(JSWrapper.largeStatement(jsCode), target: target, firstMatch: firstMatch, warnWriter: warnWriter)
                    if result.isEmpty {
                        let marker2 = try await SafariBridge.doJavaScript("String(window.__sbResultLen)", target: target, firstMatch: firstMatch, warnWriter: warnWriter)
                        if marker2.trimmingCharacters(in: .whitespacesAndNewlines) == JSWrapper.lenUnsetSentinel {
                            throw SafariBrowserError.appleScriptFailed(
                                "JavaScript syntax error: the provided code parses neither as an expression nor as a function body. (Safari's `do JavaScript` swallows the SyntaxError detail; check the code with a linter.)"
                            )
                        }
                    }
                }
            }
            return result
        } catch let error as SafariBrowserError {
            // #76: runtime errors on this path propagate as raw AppleScript
            // errors; append the CSP hint when the user code itself called
            // eval()/new Function() on a strict-CSP page.
            if case .appleScriptFailed(let msg) = error, let hint = JSWrapper.cspEvalHint(for: msg) {
                throw SafariBrowserError.appleScriptFailed(msg + hint)
            }
            throw error
        }
    }
}
