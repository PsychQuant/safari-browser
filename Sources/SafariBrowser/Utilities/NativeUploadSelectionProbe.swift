import AppKit
import ApplicationServices
import Foundation

protocol NativeUploadSelectionProvider {
    associatedtype Node: Equatable
    func foreground() throws -> Bool
    func windows() throws -> [Node]
    func windowID(_ node: Node) throws -> Int
    func string(_ node: Node, _ attribute: String) throws -> String?
    func selected(_ node: Node) throws -> Bool?
    func url(_ node: Node) throws -> URL?
    func elements(_ node: Node, _ attribute: String, limit: Int) throws -> [Node]
    func canonicalRegularFile(_ url: URL) throws -> String
}

private enum NativeSelectionReadError: Error { case unavailable }

/// This reader never performs an AX action. The worker owns every AX reference;
/// an IPC completing after timeout can only produce an abandoned read result.
enum NativeUploadSelectionProbe {
    static func check(windowID: Int, expectedPath: String, deadlineUptime: Double) -> String {
        let now = ProcessInfo.processInfo.systemUptime
        guard windowID > 0, deadlineUptime.isFinite, deadlineUptime > now,
              expectedPath.hasPrefix("/"), !expectedPath.contains("\0") else { return "UNAVAILABLE" }
        return BoundedAXWorker.shared.run(budget: min(0.8, deadlineUptime - now), fallback: "UNAVAILABLE") { deadline in
            do {
                let provider = try NativeSelectionAXProvider(deadline: deadline)
                return inspect(provider: provider, windowID: windowID, expectedPath: expectedPath, deadline: deadline)
            } catch { return "UNAVAILABLE" }
        }
    }

    static func inspect<P: NativeUploadSelectionProvider>(provider: P, windowID: Int, expectedPath: String,
        deadline: DispatchTime, maxNodes: Int = 256, maxDepth: Int = 18) -> String {
        var visited = 0
        func tick() throws {
            guard DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds else {
                throw NativeSelectionReadError.unavailable
            }
        }
        func visit(_ depth: Int) throws {
            try tick()
            visited += 1
            guard visited <= min(maxNodes, 256), depth <= min(maxDepth, 18) else {
                throw NativeSelectionReadError.unavailable
            }
        }
        func edges(_ node: P.Node, _ name: String) throws -> [P.Node] {
            try tick()
            let result = try provider.elements(node, name, limit: 64)
            guard result.count <= 64 else { throw NativeSelectionReadError.unavailable }
            return result
        }
        func role(_ node: P.Node) throws -> String {
            try tick()
            guard let role = try provider.string(node, "AXRole") else { throw NativeSelectionReadError.unavailable }
            return role
        }
        func sheets(_ window: P.Node) throws -> [P.Node] {
            var result: [P.Node] = []
            for child in try edges(window, "AXChildren") {
                try visit(0)
                if try role(child) == "AXSheet" { result.append(child) }
            }
            return result
        }
        do {
            try tick()
            guard windowID > 0, expectedPath.hasPrefix("/"), !expectedPath.contains("\0"),
                  try provider.foreground() else { return "UNAVAILABLE" }
            let expected = try provider.canonicalRegularFile(URL(fileURLWithPath: expectedPath))
            // The parent already captured a canonical path. Re-resolving that
            // path must not silently authorize a newly substituted symlink.
            guard expected == expectedPath else { return "UNAVAILABLE" }
            try tick()
            let windows = try provider.windows()
            guard windows.count <= 32 else { return "UNAVAILABLE" }
            var matches: [P.Node] = []
            for window in windows {
                try visit(0)
                if try provider.windowID(window) == windowID { matches.append(window) }
            }
            guard matches.count == 1 else { return "UNAVAILABLE" }
            let window = matches[0]
            let panels = try sheets(window)
            guard panels.count == 1, try provider.string(panels[0], "AXIdentifier") == "open-panel" else {
                return "UNAVAILABLE"
            }
            let panel = panels[0]
            // Discover exactly one supported file view through native structure.
            // Sidebar and web contents cannot supply evidence for this chooser.
            var pending = [(panel, 0)]
            var views: [(P.Node, Int, String)] = []
            while let (node, depth) = pending.popLast() {
                try visit(depth)
                let nodeRole = try role(node)
                let identifier = try provider.string(node, "AXIdentifier")
                if nodeRole == "AXWebArea" || identifier == "_NS:61" { continue }
                if node != panel && nodeRole == "AXSheet" { throw NativeSelectionReadError.unavailable }
                if let identifier, ["ColumnView", "ListView", "IconView"].contains(identifier) {
                    let validRole = identifier == "ColumnView" ? "AXBrowser" : identifier == "ListView" ? "AXOutline" : "AXList"
                    guard nodeRole == validRole else { throw NativeSelectionReadError.unavailable }
                    views.append((node, depth, identifier)); continue
                }
                if ["AXList", "AXOutline", "AXTable", "AXBrowser"].contains(nodeRole) {
                    throw NativeSelectionReadError.unavailable
                }
                if ["AXSheet", "AXSplitGroup", "AXGroup", "AXScrollArea"].contains(nodeRole) {
                    let children = try edges(node, nodeRole == "AXScrollArea" ? "AXContents" : "AXChildren")
                    pending.append(contentsOf: children.map { ($0, depth + 1) })
                }
            }
            guard views.count == 1 else { return "UNAVAILABLE" }
            let (view, viewDepth, mode) = views[0]
            var selectedPaths: [String] = []
            var selectedPending: [(P.Node, Int, Bool)] = []
            func selectedGroup(_ node: P.Node, _ attribute: String, _ depth: Int, required: Bool) throws {
                let selections = try edges(node, attribute)
                guard selections.count <= 1, !required || selections.count == 1 else {
                    throw NativeSelectionReadError.unavailable
                }
                selectedPending.append(contentsOf: selections.map { ($0, depth + 1, true) })
            }
            if mode == "ColumnView" {
                selectedPending = try edges(view, "AXColumns").map { ($0, viewDepth + 1, false) }
            } else {
                try selectedGroup(view, mode == "ListView" ? "AXSelectedRows" : "AXSelectedChildren", viewDepth, required: true)
            }
            while let (node, depth, onSelectedEdge) = selectedPending.popLast() {
                try visit(depth)
                let nodeRole = try role(node)
                if ["AXSheet", "AXWebArea", "AXBrowser", "AXOutline", "AXTable"].contains(nodeRole) {
                    throw NativeSelectionReadError.unavailable
                }
                if nodeRole == "AXList" {
                    guard mode == "ColumnView", !onSelectedEdge else { throw NativeSelectionReadError.unavailable }
                    try selectedGroup(node, "AXSelectedChildren", depth, required: false)
                    continue
                }
                if onSelectedEdge, ["AXTextField", "AXImage"].contains(nodeRole),
                   try provider.selected(node) == true, let url = try provider.url(node) {
                    guard url.isFileURL else { throw NativeSelectionReadError.unavailable }
                    selectedPaths.append(try provider.canonicalRegularFile(url))
                    guard selectedPaths.count <= 1 else { throw NativeSelectionReadError.unavailable }
                }
                // Only bounded structure beneath selected rows/groups is read.
                if ["AXScrollArea", "AXGroup", "AXRow", "AXCell", "AXColumn"].contains(nodeRole) {
                    let children = try edges(node, nodeRole == "AXScrollArea" ? "AXContents" : "AXChildren")
                    selectedPending.append(contentsOf: children.map { ($0, depth + 1, onSelectedEdge) })
                }
            }
            try tick()
            guard selectedPaths == [expected], try provider.foreground(),
                  try provider.windowID(window) == windowID,
                  try sheets(window) == [panel],
                  try provider.string(panel, "AXIdentifier") == "open-panel" else { return "UNAVAILABLE" }
            try tick()
            return "MATCH"
        } catch { return "UNAVAILABLE" }
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func nativeSelectionWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// C AX adapter: query counts before copying arrays. Every IPC receives a fresh
/// remaining timeout; provider instances and their AX nodes stay on the worker.
private struct NativeSelectionAXProvider: NativeUploadSelectionProvider {
    let deadline: DispatchTime
    let application: NSRunningApplication
    let root: AXUIElement

    init(deadline: DispatchTime) throws {
        guard GUISession.live.state == .available, AXIsProcessTrusted() else { throw NativeSelectionReadError.unavailable }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari")
        guard applications.count == 1, let application = applications.first, application.isActive else {
            throw NativeSelectionReadError.unavailable
        }
        self.deadline = deadline
        self.application = application
        root = AXUIElementCreateApplication(application.processIdentifier)
    }
    func foreground() throws -> Bool { application.isActive && !application.isTerminated && GUISession.live.state == .available }
    func prepare(_ node: AXUIElement) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { throw NativeSelectionReadError.unavailable }
        let seconds = Float(Double(deadline.uptimeNanoseconds - now) / 1_000_000_000)
        guard AXUIElementSetMessagingTimeout(node, seconds) == .success else { throw NativeSelectionReadError.unavailable }
    }
    func windows() throws -> [AXUIElement] { try elements(root, "AXWindows", limit: 32) }
    func windowID(_ node: AXUIElement) throws -> Int {
        try prepare(node)
        var result: CGWindowID = 0
        guard nativeSelectionWindowID(node, &result) == .success, result > 0 else { throw NativeSelectionReadError.unavailable }
        return Int(result)
    }
    func value(_ node: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
        try prepare(node)
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(node, attribute as CFString, &result)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success else { throw NativeSelectionReadError.unavailable }
        return result
    }
    func string(_ node: AXUIElement, _ attribute: String) throws -> String? {
        guard let value = try value(node, attribute) else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { throw NativeSelectionReadError.unavailable }
        return value as? String
    }
    func selected(_ node: AXUIElement) throws -> Bool? {
        guard let value = try value(node, "AXSelected") else { return nil }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { throw NativeSelectionReadError.unavailable }
        return CFEqual(value, kCFBooleanTrue)
    }
    func url(_ node: AXUIElement) throws -> URL? {
        guard let value = try value(node, "AXURL") else { return nil }
        guard CFGetTypeID(value) == CFURLGetTypeID(), let url = value as? NSURL,
              url.isFileURL, let pathURL = url.filePathURL else { throw NativeSelectionReadError.unavailable }
        return pathURL
    }
    func elements(_ node: AXUIElement, _ attribute: String, limit: Int) throws -> [AXUIElement] {
        try prepare(node)
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(node, attribute as CFString, &count) == .success,
              count >= 0, count <= limit else { throw NativeSelectionReadError.unavailable }
        if count == 0 { return [] }
        try prepare(node)
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(node, attribute as CFString, 0, count, &values) == .success,
              let values, CFArrayGetCount(values) == count else { throw NativeSelectionReadError.unavailable }
        // A changed count makes a partial selection snapshot ambiguous.
        try prepare(node)
        var after: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(node, attribute as CFString, &after) == .success, after == count else {
            throw NativeSelectionReadError.unavailable
        }
        let objects = values as [AnyObject]
        guard objects.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { throw NativeSelectionReadError.unavailable }
        return objects.map { $0 as! AXUIElement } // Each CF type ID was checked.
    }
    func canonicalRegularFile(_ url: URL) throws -> String {
        try NativeUploadSelectionProbe.canonicalRegularFile(url)
    }
}

extension NativeUploadSelectionProbe {
    static func canonicalRegularFile(_ url: URL) throws -> String {
        return try canonicalRegularFile(url as NSURL)
    }

    static func canonicalRegularFile(_ url: NSURL) throws -> String {
        guard url.isFileURL, let fileURL = url.filePathURL else { throw NativeSelectionReadError.unavailable }
        let canonical = fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard try canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw NativeSelectionReadError.unavailable
        }
        return canonical.path
    }
}
