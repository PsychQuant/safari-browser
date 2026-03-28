import ArgumentParser

struct PressCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "Press a keyboard key (e.g., Enter, Tab, Escape, Control+a)"
    )

    @Argument(help: "Key to press (e.g., Enter, Tab, Escape, ArrowDown, Control+a, Shift+Tab)")
    var key: String

    func run() async throws {
        let parts = key.split(separator: "+").map(String.init)
        let keyName: String
        var ctrlKey = false
        var shiftKey = false
        var altKey = false
        var metaKey = false

        if parts.count == 1 {
            keyName = parts[0]
        } else {
            keyName = parts.last!
            for modifier in parts.dropLast() {
                switch modifier.lowercased() {
                case "control", "ctrl": ctrlKey = true
                case "shift": shiftKey = true
                case "alt": altKey = true
                case "meta", "cmd", "command": metaKey = true
                default: break
                }
            }
        }

        let js = """
            (function(){
                var el = document.activeElement || document.body;
                var opts = {key: '\(keyName.escapedForJS)', bubbles: true, cancelable: true, ctrlKey: \(ctrlKey), shiftKey: \(shiftKey), altKey: \(altKey), metaKey: \(metaKey)};
                var down = el.dispatchEvent(new KeyboardEvent('keydown', opts));
                el.dispatchEvent(new KeyboardEvent('keyup', opts));
                // Simulate browser default behavior for common keys
                if (down) {
                    var key = '\(keyName.escapedForJS)';
                    if (key === 'Enter') {
                        if (el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
                        else if (el.click) el.click();
                    } else if (key === 'Tab') {
                        var focusable = Array.from(document.querySelectorAll('input,button,select,textarea,a[href],[tabindex]'));
                        var idx = focusable.indexOf(el);
                        if (idx >= 0) {
                            var next = \(shiftKey) ? focusable[idx - 1] : focusable[idx + 1];
                            if (next) next.focus();
                        }
                    } else if (key === 'Escape') {
                        if (el.blur) el.blur();
                    }
                }
                return 'OK';
            })()
            """
        _ = try await SafariBridge.doJavaScript(js)
    }
}
