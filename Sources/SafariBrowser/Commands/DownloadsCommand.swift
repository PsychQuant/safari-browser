import ArgumentParser
import Foundation

/// One entry from Safari's download history (#109).
struct DownloadEntry: Equatable {
    let filename: String
    let sourceURL: String
    let date: Date?
}

/// Lists Safari's download history.
///
/// Like `history`, this is a *behavioural record* — it says what the user
/// fetched and when — so it carries the same default `--limit`.
///
/// The `Downloads.plist` shape here was established empirically during
/// implementation (it was the one source of the four that had not been
/// inspected when the design was written): a root dictionary with a single
/// `DownloadHistory` array, whose entries carry `DownloadEntryPath`,
/// `DownloadEntryURL`, and native plist dates. Note the dates are real
/// `Date` values — *not* Core Data reference times like `History.db` — so no
/// epoch offset applies here.
struct DownloadsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "downloads",
        abstract: "List Safari's download history (requires Full Disk Access)"
    )

    @Option(name: .long, help: "Maximum rows to return (default 50)")
    var limit: Int = 50

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    // MARK: - Parsing

    static let historyKey = "DownloadHistory"
    static let pathKey = "DownloadEntryPath"
    static let urlKey = "DownloadEntryURL"
    static let dateAddedKey = "DownloadEntryDateAddedKey"

    static func entries(inPlistAt url: URL, limit: Int) throws -> [DownloadEntry] {
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

        guard let dictionary = root as? [String: Any],
            let rawEntries = dictionary[historyKey] as? [[String: Any]]
        else {
            throw SafariBrowserError.safariDataParseFailed(
                path: url.path, detail: "expected a '\(historyKey)' array at the root")
        }

        return
            rawEntries
            .compactMap { parse($0) }
            .sorted { lhs, rhs in
                // Most recent first, matching `history`. Entries without a
                // date sort last rather than being dropped — the download
                // still happened.
                switch (lhs.date, rhs.date) {
                case let (l?, r?): return l > r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return false
                }
            }
            .prefix(limit)
            .map { $0 }
    }

    static func parse(_ raw: [String: Any]) -> DownloadEntry? {
        guard let path = raw[pathKey] as? String else { return nil }
        return DownloadEntry(
            filename: (path as NSString).lastPathComponent,
            sourceURL: raw[urlKey] as? String ?? "",
            date: raw[dateAddedKey] as? Date)
    }

    // MARK: - Formatting

    static func formatRow(index: Int, entry: DownloadEntry, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone

        let stamp = entry.date.map { formatter.string(from: $0) } ?? "(no date)"
        let source = entry.sourceURL.isEmpty ? "" : " ← \(entry.sourceURL)"
        return "[\(index)]  \(stamp)  \(entry.filename)\(source)"
    }

    static func encodeJSON(_ entries: [DownloadEntry]) throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone.current

        let payload = entries.map { entry -> [String: Any] in
            [
                "filename": entry.filename,
                "source_url": entry.sourceURL,
                "date": entry.date.map { iso.string(from: $0) } as Any? ?? NSNull(),
            ]
        }
        if payload.isEmpty { return Data("[]".utf8) }
        return try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Run

    func run() throws {
        guard limit > 0 else {
            throw ValidationError("--limit must be a positive integer.")
        }

        let results: [DownloadEntry]
        do {
            results = try SafariDataStore.withCopy(.downloads) { copy in
                try DownloadsCommand.entries(inPlistAt: copy, limit: limit)
            }
        } catch let error as SafariBrowserError {
            if case .safariDataFileNotFound = error {
                LocalDataOutput.reportAbsentSource(.downloads, json: json)
                return
            }
            throw error
        }

        try LocalDataOutput.emit(
            json: json,
            jsonData: { try DownloadsCommand.encodeJSON(results) },
            textRows: results.enumerated().map { index, entry in
                DownloadsCommand.formatRow(
                    index: index + 1, entry: entry, timeZone: TimeZone.current)
            },
            legend: "downloads: [N]  local-time  filename ← source-url  (default limit 50; use --limit)")
    }
}
