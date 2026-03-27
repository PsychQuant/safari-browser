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

    func run() async throws {
        print(try await SafariBridge.getCurrentURL())
    }
}

struct GetTitle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "title",
        abstract: "Get the current page title"
    )

    func run() async throws {
        print(try await SafariBridge.getCurrentTitle())
    }
}

struct GetText: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "Get page text or element text by selector"
    )

    @Argument(help: "CSS selector (optional — omit for full page text)")
    var selector: String?

    func run() async throws {
        if let selector {
            let result = try await SafariBridge.doJavaScript(
                "(function(){ var el = \(selector.resolveRefJS); if (!el) return '\\0NOT_FOUND'; return el.textContent; })()"
            )
            if result == "\0NOT_FOUND" {
                throw SafariBrowserError.elementNotFound(selector)
            }
            if result.isEmpty {
                // Silent truncation — retry with chunked read
                let largeResult = try await SafariBridge.doJavaScriptLarge(
                    "(function(){ var el = \(selector.resolveRefJS); return el ? el.textContent : ''; })()"
                )
                print(largeResult)
            } else {
                print(result)
            }
        } else {
            // Try native property first
            let nativeResult = try await SafariBridge.getCurrentText()
            if nativeResult.isEmpty {
                // Fallback to JS + chunked read for large pages
                let jsResult = try await SafariBridge.doJavaScriptLarge("document.body.innerText")
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

    func run() async throws {
        print(try await SafariBridge.getCurrentSource())
    }
}

struct GetHTML: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "html",
        abstract: "Get element innerHTML by selector"
    )

    @Argument(help: "CSS selector")
    var selector: String

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return '\\0NOT_FOUND'; return el.innerHTML; })()"
        )
        if result == "\0NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
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

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return '\\0NOT_FOUND'; return el.value || ''; })()"
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

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return '\\0NOT_FOUND'; return el.getAttribute('\(name.escapedForJS)') || ''; })()"
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

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "document.querySelectorAll('\(selector.escapedForJS)').length"
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

    func run() async throws {
        let result = try await SafariBridge.doJavaScript(
            "(function(){ var el = \(selector.resolveRefJS); if (!el) return '\\0NOT_FOUND'; var r = el.getBoundingClientRect(); return JSON.stringify({x:Math.round(r.x),y:Math.round(r.y),width:Math.round(r.width),height:Math.round(r.height)}); })()"
        )
        if result == "\0NOT_FOUND" {
            throw SafariBrowserError.elementNotFound(selector)
        }
        print(result)
    }
}
