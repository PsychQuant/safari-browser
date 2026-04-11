import ArgumentParser

struct ConsoleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "console",
        abstract: "Capture and view console output (log/warn/error/info/debug)"
    )

    @Flag(name: .long, help: "Start capturing console output")
    var start = false

    @Flag(name: .long, help: "Clear the captured buffer")
    var clear = false

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let documentTarget = target.resolve()
        if start {
            _ = try await SafariBridge.doJavaScript("""
                (function(){
                    if (!window.__sbConsoleInstalled) {
                        window.__sbConsole = window.__sbConsole || [];
                        window.__sbConsoleInstalled = true;
                        var levels = ['log', 'warn', 'error', 'info', 'debug'];
                        for (var i = 0; i < levels.length; i++) {
                            (function(level) {
                                var orig = console[level];
                                console[level] = function() {
                                    var args = Array.prototype.slice.call(arguments);
                                    var msg = args.map(function(a){ try { return typeof a === 'object' ? JSON.stringify(a) : String(a); } catch(e) { return String(a); } }).join(' ');
                                    window.__sbConsole.push(level === 'log' ? msg : '[' + level + '] ' + msg);
                                    orig.apply(console, arguments);
                                };
                            })(levels[i]);
                        }
                    }
                })()
                """, target: documentTarget)
        } else if clear {
            _ = try await SafariBridge.doJavaScript("window.__sbConsole = []", target: documentTarget)
        } else {
            let result = try await SafariBridge.doJavaScript(
                "(window.__sbConsole || []).join('\\n')",
                target: documentTarget
            )
            if !result.isEmpty {
                print(result)
            }
        }
    }
}
