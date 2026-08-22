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
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SafariBrowserError.safariDataParseFailed(
                path: url.path, detail: "could not read file: \(error.localizedDescription)")
        }

        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
        } catch {
            throw SafariBrowserError.safariDataParseFailed(
                path: url.path,
                detail: "property list decoding failed: \(error.localizedDescription)")
        }

        guard let dictionary = root as? [String: Any] else {
            throw SafariBrowserError.safariDataParseFailed(
                path: url.path, detail: "root object is not a dictionary")
        }

        var collected: [BookmarkEntry] = []
        walk(dictionary, path: [], into: &collected)
        return collected
    }

    /// Recursive descent over `WebBookmarkTypeList` / `WebBookmarkTypeLeaf`.
    static func walk(_ node: [String: Any], path: [String], into results: inout [BookmarkEntry]) {
        switch node["WebBookmarkType"] as? String {
        case "WebBookmarkTypeList":
            let title = node["Title"] as? String ?? ""
            let childPath = title.isEmpty ? path : path + [title]
            for child in node["Children"] as? [[String: Any]] ?? [] {
                walk(child, path: childPath, into: &results)
            }

        case "WebBookmarkTypeLeaf":
            guard let urlString = node["URLString"] as? String else { return }
            let uriDictionary = node["URIDictionary"] as? [String: Any]
            let title = uriDictionary?["title"] as? String ?? ""
            results.append(
                BookmarkEntry(
                    folder: path.joined(separator: "/"),
                    title: title,
                    url: urlString,
                    isReadingList: path.contains(readingListFolderTitle)))

        default:
            // Some nodes carry children without declaring a type; descend
            // anyway rather than silently dropping a whole subtree.
            for child in node["Children"] as? [[String: Any]] ?? [] {
                walk(child, path: path, into: &results)
            }
        }
    }

    // MARK: - Formatting

    static func formatRow(index: Int, entry: BookmarkEntry) -> String {
        let marker = entry.isReadingList ? "[reading-list]" : ""
        let folder = entry.folder.isEmpty ? "(root)" : entry.folder
        let title = entry.title.replacingOccurrences(of: "\n", with: " ")
        let suffix = title.isEmpty ? "" : " — \(title)"
        let parts = ["[\(index)]", folder, marker, entry.url].filter { !$0.isEmpty }
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
        let all: [BookmarkEntry]
        do {
            all = try SafariDataStore.withCopy(.bookmarks) { copy in
                try BookmarksCommand.entries(inPlistAt: copy)
            }
        } catch let error as SafariBrowserError {
            if case .safariDataFileNotFound = error {
                LocalDataOutput.reportAbsentSource(.bookmarks, json: json)
                return
            }
            throw error
        }

        let results: [BookmarkEntry]
        if let folder {
            let needle = folder.lowercased()
            results = all.filter { $0.folder.lowercased().contains(needle) }
        } else {
            results = all
        }

        try LocalDataOutput.emit(
            json: json,
            jsonData: { try BookmarksCommand.encodeJSON(results) },
            textRows: results.enumerated().map { index, entry in
                BookmarksCommand.formatRow(index: index + 1, entry: entry)
            },
            legend: "bookmarks: [N]  folder  [reading-list]?  url — title  (no default limit)")
    }
}
