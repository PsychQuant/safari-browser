import ArgumentParser
import Foundation

struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Scan interactive elements and assign @ref IDs"
    )

    @Flag(name: .shortAndLong, help: "Only interactive elements (default)")
    var interactive = false

    @Flag(name: .shortAndLong, help: "Exclude hidden/invisible elements")
    var compact = false

    @Option(name: .shortAndLong, help: "Scope to descendants of this CSS selector")
    var selector: String?

    @Option(name: .shortAndLong, help: "Max DOM depth to scan")
    var depth: Int?

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    func run() async throws {
        let scopeJS = if let selector {
            "document.querySelector('\(selector.escapedForJS)')"
        } else {
            "document.body || document"
        }

        let depthCheck = if let _ = depth {
            """
            function getDepth(el, root) {
                var d = 0; var n = el;
                while (n && n !== root) { d++; n = n.parentElement; }
                return d;
            }
            """
        } else {
            "function getDepth() { return 0; }"
        }

        let depthFilter = if let depth {
            "if (getDepth(el, root) > \(depth)) continue;"
        } else {
            ""
        }

        let compactFilter = compact ?
            "var cs = getComputedStyle(el); var r = el.getBoundingClientRect(); if (cs.display === 'none' || cs.visibility === 'hidden' || (r.width === 0 && r.height === 0)) continue;" :
            ""

        let js = """
            (function(){
                var root = \(scopeJS);
                if (!root) return JSON.stringify({error: 'Scope element not found'});
                \(depthCheck)
                var sel = 'input,button,a,select,textarea,[role="button"],[role="link"],[role="menuitem"],[role="tab"],[contenteditable],[onclick]';
                var els = root.querySelectorAll(sel);
                window.__sbRefs = [];
                var results = [];
                var jsonResults = [];
                for (var i = 0; i < els.length; i++) {
                    var el = els[i];
                    if (el.offsetParent === null && el.tagName !== 'INPUT' && el.type !== 'hidden' && getComputedStyle(el).position !== 'fixed' && getComputedStyle(el).position !== 'sticky') continue;
                    \(compactFilter)
                    \(depthFilter)
                    window.__sbRefs.push(el);
                    var idx = window.__sbRefs.length;
                    var tag = el.tagName.toLowerCase();
                    var desc = '';
                    if (el.type && el.type !== 'submit' && el.type !== 'button') desc += '[type="' + el.type + '"]';
                    if (el.type === 'submit') desc += '[type="submit"]';
                    if (el.disabled) desc += '[disabled]';
                    var idStr = el.id ? '  #' + el.id : '';
                    var clsArr = Array.prototype.slice.call(el.classList).slice(0, 3);
                    var clsStr = clsArr.length > 0 ? '  .' + clsArr.join('.') : '';
                    var label = '';
                    if (el.placeholder) label = 'placeholder="' + el.placeholder + '"';
                    else if (el.getAttribute('aria-label')) label = 'aria-label="' + el.getAttribute('aria-label') + '"';
                    else if (el.textContent && el.textContent.trim().length > 0 && el.textContent.trim().length < 60) label = '"' + el.textContent.trim().replace(/\\s+/g, ' ') + '"';
                    else if (el.value && tag === 'input') label = 'value="' + el.value.substring(0, 40) + '"';
                    else if (el.href) label = 'href="' + el.href.substring(0, 60) + '"';
                    results.push('@e' + idx + '  ' + tag + desc + idStr + clsStr + (label ? '  ' + label : ''));
                    var jo = {ref: '@e' + idx, tag: tag};
                    if (el.type) jo.type = el.type;
                    if (el.id) jo.id = el.id;
                    if (clsArr.length) jo.classes = clsArr;
                    if (el.disabled) jo.disabled = true;
                    if (el.placeholder) jo.placeholder = el.placeholder;
                    else if (el.getAttribute('aria-label')) jo.ariaLabel = el.getAttribute('aria-label');
                    else if (el.textContent && el.textContent.trim().length > 0 && el.textContent.trim().length < 60) jo.text = el.textContent.trim().replace(/\\s+/g, ' ');
                    else if (el.href) jo.href = el.href;
                    jsonResults.push(jo);
                }
                return JSON.stringify({refs: results, json: jsonResults});
            })()
            """

        var result = try await SafariBridge.doJavaScript(js)

        // If result is empty or not valid JSON, it may be truncated — retry with chunked read
        if result.isEmpty || result.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) == nil {
            result = try await SafariBridge.doJavaScriptLarge(js)
        }

        guard let data = result.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            FileHandle.standardError.write(Data("warning: snapshot output could not be parsed. Page may have too many elements.\n".utf8))
            return
        }

        if let error = parsed["error"] as? String {
            throw SafariBrowserError.elementNotFound(error)
        }

        if json {
            if let jsonArr = parsed["json"] as? [[String: Any]] {
                let jsonData = try JSONSerialization.data(withJSONObject: jsonArr, options: [.prettyPrinted, .sortedKeys])
                print(String(data: jsonData, encoding: .utf8) ?? "[]")
            }
        } else {
            if let refs = parsed["refs"] as? [String] {
                for ref in refs {
                    print(ref)
                }
            }
        }
    }
}
