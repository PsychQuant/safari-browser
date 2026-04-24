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

    @OptionGroup var target: TargetOptions

    func run() async throws {
        let (documentTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()
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

        let findResult = try await SafariBridge.doJavaScript(findJS, target: documentTarget)
        if findResult == "NOT_FOUND" {
            throw SafariBrowserError.elementNotFound("\(locator)=\(value)")
        }

        switch action.lowercased() {
        case "click":
            // Check if element is visible and not obstructed by an overlay (#8)
            let occlusionResult = try await SafariBridge.doJavaScript("""
                (function(){
                    var el = window.__sbFound;
                    var style = window.getComputedStyle(el);
                    if (style.display === 'none') return 'HIDDEN';
                    if (style.visibility === 'hidden') return 'HIDDEN';
                    if (!el.offsetParent && el.tagName !== 'BODY' && el.tagName !== 'HTML'
                        && style.position !== 'fixed' && style.position !== 'sticky') return 'HIDDEN';
                    var rect = el.getBoundingClientRect();
                    if (rect.width === 0 || rect.height === 0) return 'HIDDEN';
                    el.scrollIntoView({block:'center',behavior:'instant'});
                    rect = el.getBoundingClientRect();
                    var cx = rect.left + rect.width / 2;
                    var cy = rect.top + rect.height / 2;
                    var topEl = document.elementFromPoint(cx, cy);
                    if (!topEl) return 'OK';
                    if (el === topEl || el.contains(topEl) || topEl.contains(el)) return 'OK';
                    return 'OBSTRUCTED:' + topEl.tagName;
                })()
                """, target: documentTarget)
            if occlusionResult.isEmpty || occlusionResult == "HIDDEN" {
                throw SafariBrowserError.elementNotFound("\(locator)=\(value) (element found but hidden)")
            }
            if occlusionResult.hasPrefix("OBSTRUCTED") {
                let blocker = occlusionResult.replacingOccurrences(of: "OBSTRUCTED:", with: "")
                throw SafariBrowserError.elementNotFound("\(locator)=\(value) (element obstructed by \(blocker))")
            }
            _ = try await SafariBridge.doJavaScript("window.__sbFound.click()", target: documentTarget)
        case "fill":
            guard let text = actionText else {
                throw ValidationError("fill action requires text argument")
            }
            _ = try await SafariBridge.doJavaScript(
                "(function(){ var el = window.__sbFound; el.value = '\(text.escapedForJS)'; el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true})); })()",
                target: documentTarget
            )
        default:
            throw ValidationError("Action must be click or fill")
        }
    }
}
