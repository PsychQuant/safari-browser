import ArgumentParser

struct ConsoleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "console",
        abstract: "Capture and view console.log output"
    )

    @Flag(name: .long, help: "Start capturing console output")
    var start = false

    @Flag(name: .long, help: "Clear the captured buffer")
    var clear = false

    func run() async throws {
        if start {
            _ = try await SafariBridge.doJavaScript("""
                (function(){
                    if (!window.__sbConsole) {
                        window.__sbConsole = [];
                        var orig = console.log;
                        console.log = function() {
                            var args = Array.prototype.slice.call(arguments);
                            window.__sbConsole.push(args.map(function(a){ return typeof a === 'object' ? JSON.stringify(a) : String(a); }).join(' '));
                            orig.apply(console, arguments);
                        };
                    }
                })()
                """)
        } else if clear {
            _ = try await SafariBridge.doJavaScript("window.__sbConsole = []")
        } else {
            let result = try await SafariBridge.doJavaScript(
                "(window.__sbConsole || []).join('\\n')"
            )
            if !result.isEmpty {
                print(result)
            }
        }
    }
}
