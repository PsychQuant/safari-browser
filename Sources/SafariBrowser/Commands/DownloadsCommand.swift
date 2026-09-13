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
        try entries(in: SafariDataStore.readPlist(sourceURL: url), sourceURL: url, limit: limit)
    }

    static func entries(in data: Data, sourceURL: URL, limit: Int) throws -> [DownloadEntry] {
        guard limit > 0 else { throw ValidationError("--limit must be a positive integer.") }
        let root = try SchemaDiagnostics.plist(data, sourceURL: sourceURL)
        guard let dictionary = root as? [String: Any],
            let rawEntries = dictionary[historyKey] as? [Any]
        else {
            throw SafariBrowserError.safariDataParseFailed(
                path: sourceURL.path, detail: "expected a '\(historyKey)' array at the root")
        }
        var diagnostics = SchemaDiagnostics(sourceURL: sourceURL, context: "downloads")
        var results: [(index: Int, entry: DownloadEntry)] = []
        for (index, raw) in rawEntries.enumerated() {
            guard let raw = raw as? [String: Any] else {
                diagnostics.invalid(at: "DownloadHistory[\(index)]", field: "dictionary")
                continue
            }
            guard let entry = parse(raw) else {
                diagnostics.invalid(at: "DownloadHistory[\(index)]", field: pathKey)
                continue
            }
            diagnostics.valid()
            results.append((index, entry))
        }
        try diagnostics.finish()
        return results.sorted { lhs, rhs in
            switch (lhs.entry.date, rhs.entry.date) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.index < rhs.index
            }
        }.prefix(limit).map(\.entry)
    }

    static func parse(_ raw: [String: Any]) -> DownloadEntry? {
        guard let path = SchemaDiagnostics.requiredString(raw[pathKey]) else { return nil }
        return DownloadEntry(
            filename: (path as NSString).lastPathComponent,
            sourceURL: raw[urlKey] as? String ?? "",
            date: SchemaDiagnostics.representableDate(raw[dateAddedKey] as? Date))
    }

    // MARK: - Formatting

    static func formatRow(index: Int, entry: DownloadEntry, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone

        let stamp = entry.date.map { formatter.string(from: $0) } ?? "(no date)"
        let source = entry.sourceURL.isEmpty ? "" : " ← \(LocalDataOutput.sanitizeTextField(entry.sourceURL))"
        return "[\(index)]  \(stamp)  \(LocalDataOutput.sanitizeTextField(entry.filename))\(source)"
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
        try run(sourceURL: SafariDataStore.sourceURL(for: .downloads))
    }

    func run(sourceURL: URL) throws {
        guard limit > 0 else {
            throw ValidationError("--limit must be a positive integer.")
        }

        let results: [DownloadEntry]
        do {
            results = try DownloadsCommand.entries(
                in: SafariDataStore.readPlist(sourceURL: sourceURL), sourceURL: sourceURL, limit: limit)
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
