import ArgumentParser

struct CookiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cookies",
        abstract: "Manage cookies",
        subcommands: [
            CookiesGet.self,
            CookiesSet.self,
            CookiesClear.self,
        ]
    )
}

struct CookiesGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get cookies (all or by name)"
    )

    @Argument(help: "Cookie name (optional — omit for all)")
    var name: String?

    @Flag(name: .long, help: "Output as JSON object")
    var json = false

    func run() async throws {
        if let name {
            let result = try await SafariBridge.doJavaScript(
                "(function(){ var m = document.cookie.match('(?:^|; )\(name.escapedForJS)=([^;]*)'); return m ? decodeURIComponent(m[1]) : ''; })()"
            )
            print(result)
        } else if json {
            let result = try await SafariBridge.doJavaScript(
                "(function(){ var o = {}; document.cookie.split(';').forEach(function(c){ var p = c.trim().split('='); if (p[0]) o[p[0]] = decodeURIComponent(p.slice(1).join('=')); }); return JSON.stringify(o); })()"
            )
            print(result)
        } else {
            print(try await SafariBridge.doJavaScript("document.cookie"))
        }
    }
}

struct CookiesSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a cookie"
    )

    @Argument(help: "Cookie name")
    var name: String

    @Argument(help: "Cookie value")
    var value: String

    func run() async throws {
        _ = try await SafariBridge.doJavaScript(
            "document.cookie = '\(name.escapedForJS)=\(value.escapedForJS); path=/'"
        )
    }
}

struct CookiesClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Clear all cookies for the current domain"
    )

    func run() async throws {
        _ = try await SafariBridge.doJavaScript(
            "(function(){ document.cookie.split(';').forEach(function(c){ var n = c.split('=')[0].trim(); document.cookie = n + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/'; }); })()"
        )
    }
}
