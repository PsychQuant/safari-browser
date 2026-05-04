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

    @Flag(name: .long, help: "Full page state: accessibility tree + metadata + live regions + dialogs + validation")
    var page = false

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    @OptionGroup var target: TargetOptions

    func run() async throws {
        target.warnIfProfileUnsupported(commandName: "snapshot")
        if page {
            try await runPageScan()
            return
        }
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

        let (resolvedTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        var result = try await SafariBridge.doJavaScript(js, target: resolvedTarget)

        // If result is empty or not valid JSON, it may be truncated — retry with chunked read
        if result.isEmpty || result.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) == nil {
            result = try await SafariBridge.doJavaScriptLarge(js, target: resolvedTarget)
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

    // MARK: - --page: Full page state scan (#13)

    private func runPageScan() async throws {
        let scopeJS = if let selector {
            "document.querySelector('\(selector.escapedForJS)')"
        } else {
            "document.body || document"
        }

        let js = """
            (function(){
                var root = \(scopeJS);
                if (!root) return JSON.stringify({error: 'Scope element not found'});

                var meta = {
                    url: window.location.href,
                    title: document.title,
                    readyState: document.readyState
                };

                window.__sbRefs = [];
                var interactiveSelector = 'input,button,a,select,textarea,[role="button"],[role="link"],[role="menuitem"],[role="tab"],[contenteditable],[onclick]';

                var lines = [];
                var jsonTree = [];
                var jsonRefs = [];
                var jsonValidation = [];
                var refCount = 0;
                var maxLines = 2000;
                var totalLines = 0;
                var truncated = false;

                function isHidden(el) {
                    if (el.nodeType !== 1) return false;
                    if (el.getAttribute('aria-hidden') === 'true') return true;
                    var cs = getComputedStyle(el);
                    return cs.display === 'none' || cs.visibility === 'hidden';
                }

                function isInteractive(el) {
                    return el.matches && el.matches(interactiveSelector);
                }

                function getRole(el) {
                    var explicit = el.getAttribute('role');
                    if (explicit) return explicit;
                    var tag = el.tagName;
                    if (tag === 'NAV') return 'navigation';
                    if (tag === 'MAIN') return 'main';
                    if (tag === 'ASIDE') return 'complementary';
                    if (tag === 'HEADER') return 'banner';
                    if (tag === 'FOOTER') return 'contentinfo';
                    if (tag === 'SECTION') return el.getAttribute('aria-label') ? 'region' : null;
                    if (tag === 'FORM') return 'form';
                    if (/^H[1-6]$/.test(tag)) return 'heading';
                    if (tag === 'UL' || tag === 'OL') return 'list';
                    if (tag === 'LI') return 'listitem';
                    if (tag === 'TABLE') return 'table';
                    if (tag === 'DIALOG') return 'dialog';
                    return null;
                }

                function getLabel(el) {
                    if (el.getAttribute('aria-label')) return el.getAttribute('aria-label');
                    if (el.placeholder) return 'placeholder="' + el.placeholder + '"';
                    if (el.tagName === 'A' && el.textContent.trim().length < 60) return '"' + el.textContent.trim().replace(/\\s+/g, ' ') + '"';
                    if (el.tagName === 'BUTTON' && el.textContent.trim().length < 60) return '"' + el.textContent.trim().replace(/\\s+/g, ' ') + '"';
                    if (el.tagName === 'INPUT' && el.value) return 'value="' + el.value.substring(0, 40) + '"';
                    return '';
                }

                function addLine(indent, text, jsonNode) {
                    totalLines++;
                    if (!truncated && lines.length < maxLines) {
                        lines.push('  '.repeat(indent) + text);
                    } else {
                        truncated = true;
                    }
                    if (jsonNode) jsonTree.push(jsonNode);
                }

                function walk(el, depth) {
                    if (isHidden(el)) return;

                    for (var i = 0; i < el.childNodes.length; i++) {
                        var node = el.childNodes[i];

                        // Text node
                        if (node.nodeType === 3) {
                            var txt = node.textContent.trim().replace(/\\s+/g, ' ');
                            if (txt && txt.length > 0 && txt.length < 200) {
                                // Skip if parent is interactive (label already captured)
                                if (!isInteractive(node.parentElement)) {
                                    addLine(depth, '[text] ' + txt, {type: 'text', text: txt, depth: depth});
                                }
                            }
                            continue;
                        }

                        if (node.nodeType !== 1) continue;
                        if (isHidden(node)) continue;

                        var tag = node.tagName.toLowerCase();
                        var role = getRole(node);

                        // Heading
                        if (/^H[1-6]$/.test(node.tagName)) {
                            var level = parseInt(node.tagName[1]);
                            var hText = node.textContent.trim().replace(/\\s+/g, ' ').substring(0, 120);
                            addLine(depth, '[heading level=' + level + '] ' + hText, {type: 'heading', level: level, text: hText, depth: depth});
                            continue; // don't recurse into heading children
                        }

                        // Landmark
                        if (role === 'navigation' || role === 'main' || role === 'complementary' || role === 'banner' || role === 'contentinfo' || role === 'region' || role === 'form') {
                            var landmarkName = node.getAttribute('aria-label') || '';
                            addLine(depth, '[' + role + (landmarkName ? ' "' + landmarkName + '"' : '') + ']', {type: 'landmark', role: role, name: landmarkName, depth: depth});
                            walk(node, depth + 1);
                            continue;
                        }

                        // List
                        if (role === 'list') {
                            addLine(depth, '[list]', {type: 'list', depth: depth});
                            walk(node, depth + 1);
                            continue;
                        }
                        if (role === 'listitem') {
                            // Get direct text of listitem
                            var liText = '';
                            for (var j = 0; j < node.childNodes.length; j++) {
                                if (node.childNodes[j].nodeType === 3) liText += node.childNodes[j].textContent.trim() + ' ';
                            }
                            liText = liText.trim().replace(/\\s+/g, ' ').substring(0, 120);
                            addLine(depth, '[listitem] ' + (liText ? '"' + liText + '"' : ''), {type: 'listitem', text: liText, depth: depth});
                            walk(node, depth + 1);
                            continue;
                        }

                        // Dialog
                        if (role === 'dialog' || tag === 'dialog') {
                            var isOpen = tag === 'dialog' ? node.open : true;
                            if (isOpen) {
                                var modal = node.getAttribute('aria-modal') === 'true';
                                addLine(depth, '[dialog' + (modal ? ' aria-modal=true' : '') + ']', {type: 'dialog', modal: modal, depth: depth});
                                walk(node, depth + 1);
                            }
                            continue;
                        }

                        // Live region
                        var ariaLive = node.getAttribute('aria-live');
                        if (ariaLive) {
                            var liveText = node.textContent.trim().replace(/\\s+/g, ' ').substring(0, 200);
                            if (liveText) {
                                addLine(depth, '[' + (node.getAttribute('role') || 'region') + ' aria-live=' + ariaLive + '] ' + liveText, {type: 'live', role: node.getAttribute('role') || 'region', ariaLive: ariaLive, text: liveText, depth: depth});
                            }
                            continue; // don't recurse, text already captured
                        }

                        // Interactive element → @ref
                        if (isInteractive(node)) {
                            window.__sbRefs.push(node);
                            refCount++;
                            var ref = '@e' + refCount;
                            var desc = tag;
                            if (node.type && node.type !== 'submit' && node.type !== 'button') desc += '[type="' + node.type + '"]';
                            if (node.type === 'submit') desc += '[type="submit"]';
                            if (node.disabled) desc += '[disabled]';
                            var lbl = getLabel(node);
                            var refLine = ref + ' ' + desc + (lbl ? ' ' + lbl : '');
                            addLine(depth, refLine, null);
                            jsonRefs.push({ref: ref, tag: tag, type: node.type || undefined, label: lbl || undefined, depth: depth});

                            // Form validation
                            if ((tag === 'input' || tag === 'select' || tag === 'textarea') && typeof node.checkValidity === 'function' && !node.checkValidity()) {
                                var msg = node.validationMessage || 'invalid';
                                addLine(depth, '  [invalid: "' + msg + '"]', null);
                                jsonValidation.push({ref: ref, tag: tag, message: msg});
                            }
                            // Don't recurse into interactive elements
                            continue;
                        }

                        // Table
                        if (role === 'table') {
                            var caption = node.querySelector('caption');
                            addLine(depth, '[table' + (caption ? ' "' + caption.textContent.trim().substring(0, 60) + '"' : '') + ']', {type: 'table', depth: depth});
                            walk(node, depth + 1);
                            continue;
                        }

                        // Generic container — recurse without adding a line
                        walk(node, depth);
                    }
                }

                walk(root, 0);

                return JSON.stringify({
                    meta: meta,
                    lines: lines,
                    totalLines: totalLines,
                    truncated: truncated,
                    jsonTree: jsonTree,
                    jsonRefs: jsonRefs,
                    jsonValidation: jsonValidation
                });
            })()
            """

        let (resolvedTarget, firstMatch, warnWriter) = target.resolveWithFirstMatch()
        var result = try await SafariBridge.doJavaScript(js, target: resolvedTarget)

        if result.isEmpty || result.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) == nil {
            result = try await SafariBridge.doJavaScriptLarge(js, target: resolvedTarget)
        }

        guard let data = result.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            FileHandle.standardError.write(Data("warning: page scan output could not be parsed.\n".utf8))
            return
        }

        if let error = parsed["error"] as? String {
            throw SafariBrowserError.elementNotFound(error)
        }

        let meta = parsed["meta"] as? [String: Any] ?? [:]
        let lines = parsed["lines"] as? [String] ?? []
        let totalLines = parsed["totalLines"] as? Int ?? lines.count
        let truncated = parsed["truncated"] as? Bool ?? false

        if json {
            let jsonOutput: [String: Any] = [
                "url": meta["url"] ?? "",
                "title": meta["title"] ?? "",
                "readyState": meta["readyState"] ?? "",
                "tree": parsed["jsonTree"] ?? [],
                "refs": parsed["jsonRefs"] ?? [],
                "validation": parsed["jsonValidation"] ?? [],
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: jsonOutput, options: [.prettyPrinted, .sortedKeys]) {
                print(String(data: jsonData, encoding: .utf8) ?? "{}")
            }
        } else {
            // Metadata header
            print("URL: \(meta["url"] as? String ?? "")")
            print("Title: \(meta["title"] as? String ?? "")")
            print("Loading: \(meta["readyState"] as? String ?? "")")
            print("")

            for line in lines {
                print(line)
            }

            if truncated {
                print("... truncated (\(totalLines) total lines). Use -s \"<selector>\" to narrow scope.")
            }
        }
    }
}
