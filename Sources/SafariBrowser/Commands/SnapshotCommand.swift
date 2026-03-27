import ArgumentParser
import Foundation

struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Scan interactive elements and assign @ref IDs"
    )

    @Flag(name: .shortAndLong, help: "Only interactive elements (default)")
    var interactive = false

    @Option(name: .shortAndLong, help: "Scope to descendants of this CSS selector")
    var selector: String?

    func run() async throws {
        let scopeJS = if let selector {
            "document.querySelector('\(selector.escapedForJS)')"
        } else {
            "document"
        }

        let js = """
            (function(){
                var root = \(scopeJS);
                if (!root) return JSON.stringify({error: 'Scope element not found'});
                var sel = 'input,button,a,select,textarea,[role="button"],[role="link"],[role="menuitem"],[role="tab"],[contenteditable],[onclick]';
                var els = root.querySelectorAll(sel);
                window.__sbRefs = [];
                var results = [];
                for (var i = 0; i < els.length; i++) {
                    var el = els[i];
                    if (el.offsetParent === null && el.tagName !== 'INPUT' && el.type !== 'hidden') continue;
                    window.__sbRefs.push(el);
                    var idx = window.__sbRefs.length;
                    var tag = el.tagName.toLowerCase();
                    var desc = '';
                    if (el.type && el.type !== 'submit' && el.type !== 'button') desc += '[type="' + el.type + '"]';
                    if (el.type === 'submit') desc += '[type="submit"]';
                    if (el.name) desc += ' name="' + el.name + '"';
                    var label = '';
                    if (el.placeholder) label = 'placeholder="' + el.placeholder + '"';
                    else if (el.getAttribute('aria-label')) label = 'aria-label="' + el.getAttribute('aria-label') + '"';
                    else if (el.textContent && el.textContent.trim().length > 0 && el.textContent.trim().length < 60) label = '"' + el.textContent.trim().replace(/\\s+/g, ' ') + '"';
                    else if (el.value && tag === 'input') label = 'value="' + el.value.substring(0, 40) + '"';
                    else if (el.href) label = 'href="' + el.href.substring(0, 60) + '"';
                    results.push('@e' + idx + '  ' + tag + desc + (label ? '  ' + label : ''));
                }
                return JSON.stringify({refs: results});
            })()
            """

        let result = try await SafariBridge.doJavaScript(js)

        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let error = json["error"] as? String {
            throw SafariBrowserError.elementNotFound(error)
        }

        if let refs = json["refs"] as? [String] {
            for ref in refs {
                print(ref)
            }
        }
    }
}
