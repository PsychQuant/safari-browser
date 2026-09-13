import ArgumentParser
import Foundation

/// One bookmark or Reading List entry from `Bookmarks.plist` (#109).
struct BookmarkEntry: Equatable {
    /// Slash-joined folder path, e.g. `BookmarksBar/AI`. Empty at the root.
    let folder: String
    let title: String
    let url: String
    let isReadingList: Bool
}

/// Lists Safari bookmarks and the Reading List.
///
/// No default limit, unlike `history`: bookmarks are *curated* state — things
/// the user deliberately kept — not a behavioural record. Truncating them
/// would break the obvious use ("show me my bookmarks") to guard against a
/// disclosure risk that curation already bounds.
struct BookmarksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bookmarks",
        abstract: "List Safari bookmarks and Reading List (requires Full Disk Access)"
    )

    @Option(name: .long, help: "Filter to bookmarks whose folder path contains this text")
    var folder: String?

    @Option(name: .long, help: "Filter to entries whose URL or title contains this text")
    var search: String?

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    // MARK: - Parsing

    /// Reading List entries live in a folder whose title is this constant
    /// rather than under a distinct type, so identifying them is a path test.
    static let readingListFolderTitle = "com.apple.ReadingList"

    /// Walks the bookmark tree.
    ///
    /// `plutil -convert json` is not usable here: the plist contains objects
    /// with no JSON representation and the conversion fails outright
    /// (verified against a real `Bookmarks.plist`). A plist decoder is the
    /// only route.
    static func entries(inPlistAt url: URL) throws -> [BookmarkEntry] {
        try entries(in: SafariDataStore.readPlist(sourceURL: url), sourceURL: url)
    }

    static func entries(in data: Data, sourceURL: URL) throws -> [BookmarkEntry] {
        let root = try SchemaDiagnostics.plist(data, sourceURL: sourceURL)
        guard let dictionary = root as? [String: Any] else {
            throw SafariBrowserError.safariDataParseFailed(
                path: sourceURL.path, detail: "root object is not a dictionary")
        }
        var collected: [BookmarkEntry] = []
        var diagnostics = SchemaDiagnostics(sourceURL: sourceURL, context: "bookmarks")
        walk(dictionary, path: [], location: "root[0]", into: &collected, diagnostics: &diagnostics)
        try diagnostics.finish()
        return collected
    }

    private static func walk(
        _ node: [String: Any], path: [String], location: String,
        into results: inout [BookmarkEntry], diagnostics: inout SchemaDiagnostics
    ) {
        let type = node["WebBookmarkType"] as? String
        if type == "WebBookmarkTypeLeaf" {
            guard let urlString = SchemaDiagnostics.requiredString(node["URLString"]) else {
                diagnostics.invalid(at: location, field: "URLString")
                return
            }
            diagnostics.valid()
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
            results.append(BookmarkEntry(
                folder: path.joined(separator: "/"), title: title, url: urlString,
                isReadingList: path.contains(readingListFolderTitle)))
            return
        }
        // Safari's built-in proxy nodes (for example its history shortcut)
        // are not bookmarks and intentionally carry no URL or children.
        if type == "WebBookmarkTypeProxy" { return }
        // Safari omits Children for legitimate empty folders. A present but
        // wrong-typed Children value still signals schema failure.
        if type == "WebBookmarkTypeList" && node["Children"] == nil { return }
        if node.isEmpty && location == "root[0]" { return }
        guard let children = node["Children"] as? [Any] else {
            diagnostics.invalid(at: location, field: "Children")
            return
        }
        let title = type == "WebBookmarkTypeList" ? node["Title"] as? String ?? "" : ""
        let childPath = title.isEmpty ? path : path + [title]
        for (index, child) in children.enumerated() {
            let childLocation = "\(location).Children[\(index)]"
            guard let child = child as? [String: Any] else {
                diagnostics.invalid(at: childLocation, field: "dictionary")
                continue
            }
            walk(child, path: childPath, location: childLocation, into: &results, diagnostics: &diagnostics)
        }
    }

    static func filtered(_ entries: [BookmarkEntry], folder: String?, search: String?) -> [BookmarkEntry] {
        let folderNeedle = folder?.lowercased()
        let searchNeedle = search?.lowercased()
        return entries.filter { entry in
            let matchesFolder = folderNeedle.map { entry.folder.lowercased().contains($0) } ?? true
            let matchesSearch = searchNeedle.map {
                entry.title.lowercased().contains($0) || entry.url.lowercased().contains($0)
            } ?? true
            return matchesFolder && matchesSearch
        }
    }

    // MARK: - Formatting

    static func formatRow(index: Int, entry: BookmarkEntry) -> String {
        let marker = entry.isReadingList ? "[reading-list]" : ""
        let folder = entry.folder.isEmpty ? "(root)" : LocalDataOutput.sanitizeTextField(entry.folder)
        let title = LocalDataOutput.sanitizeTextField(entry.title)
        let suffix = title.isEmpty ? "" : " — \(title)"
        let parts = ["[\(index)]", folder, marker, LocalDataOutput.sanitizeTextField(entry.url)].filter { !$0.isEmpty }
        return parts.joined(separator: "  ") + suffix
    }

    static func encodeJSON(_ entries: [BookmarkEntry]) throws -> Data {
        let payload = entries.map { entry -> [String: Any] in
            [
                "folder": entry.folder,
                "title": entry.title,
                "url": entry.url,
                "reading_list": entry.isReadingList,
            ]
        }
        if payload.isEmpty { return Data("[]".utf8) }
        return try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Run

    func run() throws {
        try run(sourceURL: SafariDataStore.sourceURL(for: .bookmarks))
    }

    func run(sourceURL: URL) throws {
        let all: [BookmarkEntry]
        do {
            all = try BookmarksCommand.entries(
                in: SafariDataStore.readPlist(sourceURL: sourceURL), sourceURL: sourceURL)
        } catch let error as SafariBrowserError {
            if case .safariDataFileNotFound = error {
                LocalDataOutput.reportAbsentSource(.bookmarks, json: json)
                return
            }
            throw error
        }

        let results = BookmarksCommand.filtered(all, folder: folder, search: search)

        try LocalDataOutput.emit(
            json: json,
            jsonData: { try BookmarksCommand.encodeJSON(results) },
            textRows: results.enumerated().map { index, entry in
                BookmarksCommand.formatRow(index: index + 1, entry: entry)
            },
            legend: "bookmarks: [N]  folder  [reading-list]?  url — title  (no default limit)")
    }
}
