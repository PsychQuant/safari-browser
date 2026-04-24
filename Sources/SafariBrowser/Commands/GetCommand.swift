import ArgumentParser

struct GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get page or element information",
        subcommands: [
            GetURL.self,
            GetTitle.self,
            GetText.self,
            GetSource.self,
            GetHTML.self,
            GetValue.self,
            GetAttr.self,
            GetCount.self,
            GetBox.self,
        ]
    )
}

struct GetURL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "url",
        abstract: "Get the current page URL"
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        print(try await SafariBridge.getCurrentURL(target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter))
    }
}

struct GetTitle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "title",
        abstract: "Get the current page title"
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        print(try await SafariBridge.getCurrentTitle(target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter))
    }
}

struct GetText: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "Get page text or element text by selector"
    )

    @Argument(help: "CSS selector (optional — omit for full page text)")
    var selector: String?

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let (documentTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        if let selector {
            let result = try await SafariBridge.doJavaScript(
                "(function(){ var el = \(selector.resolveRefJS); if (!el) return '\\0NOT_FOUND'; return el.textContent; })()",
                target: documentTarget
            )
            if result == "\0NOT_FOUND" {
                throw SafariBrowserError.elementNotFound(selector)
            }
            // Check if empty is genuine or truncation
            if result.isEmpty {
                let lenStr = try await SafariBridge.doJavaScript(
                    "(function(){ var el = \(selector.resolveRefJS); return el ? String(el.textContent.length) : '0'; })()",
                    target: documentTarget
                )
                let len = Int(lenStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if len > 0 {
                    // Truncated — use chunked read (no re-execution)
                    _ = try await SafariBridge.doJavaScript(
                        "(function(){ var el = \(selector.resolveRefJS); window.__sbResult = el ? el.textContent : ''; window.__sbResultLen = window.__sbResult.length; })()",
                        target: documentTarget
                    )
                    print(try await SafariBridge.doJavaScriptLarge("window.__sbResult", target: documentTarget))
                }
                // else genuinely empty — print nothing
            } else {
                print(result)
            }
        } else {
            // Try native property first
            let nativeResult = try await SafariBridge.getCurrentText(target: documentTarget)
            if nativeResult.isEmpty {
                // Fallback to JS + chunked read for large pages
                let jsResult = try await SafariBridge.doJavaScriptLarge("document.body.innerText", target: documentTarget)
                print(jsResult)
            } else {
                print(nativeResult)
            }
        }
    }
}

struct GetSource: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "source",
        abstract: "Get the current page HTML source"
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        print(try await SafariBridge.getCurrentSource(target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter))
    }
}

struct GetHTML: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "html",
        abstract: "Get element innerHTML by selector"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let (documentTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return '\\0NOT_FOUND'; return el.innerHTML; })()",
            target: documentTarget
        )
        if result == "\0NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
        if result.isEmpty {
            // May be truncated — check length and use chunked read
            let lenStr = try await SafariBridge.doJavaScript(
                "(function(){ var el = \(selector.resolveRefJS); return el ? String(el.innerHTML.length) : '0'; })()",
                target: documentTarget
            )
            let len = Int(lenStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if len > 0 {
                _ = try await SafariBridge.doJavaScript(
                    "(function(){ var el = \(selector.resolveRefJS); window.__sbResult = el ? el.innerHTML : ''; window.__sbResultLen = window.__sbResult.length; })()",
                    target: documentTarget
                )
                print(try await SafariBridge.doJavaScriptLarge("window.__sbResult", target: documentTarget))
                return
            }
        }
        print(result)
    }
}

struct GetValue: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "value",
        abstract: "Get input/textarea value by selector"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return '\\0NOT_FOUND'; return el.value || ''; })()",
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter
        )
        if result == "\0NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
        print(result)
    }
}

struct GetAttr: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attr",
        abstract: "Get element attribute value"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @Argument(help: "Attribute name")
    var name: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return '\\0NOT_FOUND'; return el.getAttribute('\(name.escapedForJS)') || ''; })()",
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter
        )
        if result == "\0NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
        print(result)
    }
}

struct GetCount: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "count",
        abstract: "Count elements matching a selector"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "document.querySelectorAll('\(selector.escapedForJS)').length",
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter
        )
        print(result)
    }
}

struct GetBox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "box",
        abstract: "Get element bounding box as JSON"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return '\\0NOT_FOUND'; var r = el.getBoundingClientRect(); return JSON.stringify({x:Math.round(r.x),y:Math.round(r.y),width:Math.round(r.width),height:Math.round(r.height)}); })()",
            target: target.resolve(), firstMatch: target.firstMatch, warnWriter: TargetOptions.stderrWarnWriter
        )
        if result == "\0NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
        print(result)
    }
}
