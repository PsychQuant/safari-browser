import ArgumentParser

struct FindCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Find element by text, role, label, or placeholder and perform an action"
    )

    @Argument(help: "Locator type: text, role, label, placeholder")
    var locator: String

    @Argument(help: "Value to search for")
    var value: String

    @Argument(help: "Action to perform: click, fill")
    var action: String

    @Argument(help: "Text for fill action (optional)")
    var actionText: String?

    func run() async throws {
        let findJS: String = switch locator.lowercased() {
        case "text":
            """
            (function(){
                var els = document.querySelectorAll('*');
                for (var i = 0; i < els.length; i++) {
                    if (els[i].children.length === 0 && els[i].textContent.indexOf('\(value.escapedForJS)') !== -1) {
                        window.__sbFound = els[i]; return 'OK';
                    }
                }
                return 'NOT_FOUND';
            })()
            """
        case "role":
            """
            (function(){
                var el = document.querySelector('[role="\(value.escapedForJS)"]');
                if (!el) return 'NOT_FOUND';
                window.__sbFound = el; return 'OK';
            })()
            """
        case "label":
            """
            (function(){
                var labels = document.querySelectorAll('label');
                for (var i = 0; i < labels.length; i++) {
                    if (labels[i].textContent.indexOf('\(value.escapedForJS)') !== -1) {
                        var forId = labels[i].getAttribute('for');
                        if (forId) { window.__sbFound = document.getElementById(forId); }
                        else { window.__sbFound = labels[i].querySelector('input,textarea,select'); }
                        if (window.__sbFound) return 'OK';
                    }
                }
                return 'NOT_FOUND';
            })()
            """
        case "placeholder":
            """
            (function(){
                var el = document.querySelector('[placeholder*="\(value.escapedForJS)"]');
                if (!el) return 'NOT_FOUND';
                window.__sbFound = el; return 'OK';
            })()
            """
        default:
            throw ValidationError("Locator must be text, role, label, or placeholder")
        }

        let findResult = try await SafariBridge.doJavaScript(findJS)
        if findResult == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound("\(locator)=\(value)")
        }

        switch action.lowercased() {
        case "click":
            _ = try await SafariBridge.doJavaScript("window.__sbFound.click()")
        case "fill":
            guard let text = actionText else {
                throw ValidationError("fill action requires text argument")
            }
            _ = try await SafariBridge.doJavaScript(
                "(function(){ var el = window.__sbFound; el.value = '\(text.escapedForJS)'; el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true})); })()"
            )
        default:
            throw ValidationError("Action must be click or fill")
        }
    }
}
