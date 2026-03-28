import ArgumentParser

struct ErrorsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "errors",
        abstract: "Capture and view JavaScript errors"
    )

    @Flag(name: .long, help: "Start capturing errors")
    var start = false

    @Flag(name: .long, help: "Clear the captured buffer")
    var clear = false

    func run() async throws {
        if start {
            _ = try await SafariBridge.doJavaScript("""
                (function(){
                    if (!window.__sbErrorsInstalled) {
                        window.__sbErrors = window.__sbErrors || [];
                        window.__sbErrorsInstalled = true;
                        var origOnerror = window.onerror;
                        window.onerror = function(msg, src, line, col, err) {
                            window.__sbErrors.push(msg + ' at ' + src + ':' + line + ':' + col);
                            if (origOnerror) return origOnerror(msg, src, line, col, err);
                        };
                    }
                })()
                """)
        } else if clear {
            _ = try await SafariBridge.doJavaScript("window.__sbErrors = []")
        } else {
            let result = try await SafariBridge.doJavaScript(
                "(window.__sbErrors || []).join('\\n')"
            )
            if !result.isEmpty {
                print(result)
            }
        }
    }
}
