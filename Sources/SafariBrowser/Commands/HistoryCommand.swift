import ArgumentParser
import Foundation

/// One visited page, as recorded in `History.db` (#109).
struct HistoryVisit: Equatable {
    let url: String
    let title: String?
    let visitTime: Date
    let visitCount: Int
}

/// Queries Safari's on-disk browsing history.
///
/// This is a *behavioural record* — unlike every other command in this tool,
/// which can only see what the user currently has open. That asymmetry is why
/// it carries a default `--limit` (see the `local-data-query` spec): an
/// unqualified invocation must not dump years of activity into a terminal or
/// an agent's context.
struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Search Safari's browsing history (requires Full Disk Access)"
    )

    @Option(name: .long, help: "Filter to entries whose URL or title contains this text")
    var search: String?

    @Option(name: .long, help: "Filter to visits on or after this date (YYYY-MM-DD)")
    var since: String?

    @Option(name: .long, help: "Maximum rows to return (default 50)")
    var limit: Int = 50

    @Flag(name: .long, help: "Output as JSON array")
    var json = false

    // MARK: - Timestamp conversion

    /// Seconds between the Unix epoch (1970-01-01) and Core Data's reference
    /// date (2001-01-01). `history_visits.visit_time` is stored in the latter.
    static let coreDataEpochOffset: TimeInterval = 978_307_200

    static func date(fromCoreDataReferenceTime reference: Double) -> Date {
        Date(timeIntervalSince1970: reference + coreDataEpochOffset)
    }

    static func parseSinceDate(_ text: String) -> Date? {
        // `DateFormatter` alone is looser than the `YYYY-MM-DD` the flag help
        // advertises: it accepts unpadded components and tolerates trailing
        // junk, so `2026-2-3` or `2026-01-01xyz` would quietly parse as
        // something the user did not write. Shape-check first, then confirm by
        // formatting the result back and requiring it to match the input.
        let shape = #/^\d{4}-\d{2}-\d{2}$/#
        guard text.wholeMatch(of: shape) != nil else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.isLenient = false

        guard let parsed = formatter.date(from: text),
            formatter.string(from: parsed) == text
        else { return nil }
        return parsed
    }

    // MARK: - Formatting

    static func formatRow(index: Int, visit: HistoryVisit, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone

        let stamp = formatter.string(from: visit.visitTime)
        let title = visit.title?.replacingOccurrences(of: "\n", with: " ") ?? ""
        let suffix = title.isEmpty ? "" : " — \(title)"
        return "[\(index)]  \(stamp)  \(visit.url)\(suffix)"
    }

    static func encodeJSON(_ visits: [HistoryVisit]) throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone.current

        let payload = visits.map { visit -> [String: Any] in
            [
                "url": visit.url,
                "title": visit.title as Any? ?? NSNull(),
                "visit_time": iso.string(from: visit.visitTime),
                "visit_count": visit.visitCount,
            ]
        }
        if payload.isEmpty {
            return Data("[]".utf8)
        }
        return try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Query

    static func visits(
        inDatabaseAt url: URL, search: String?, since: Date?, limit: Int
    ) throws -> [HistoryVisit] {
        // Ordering happens in SQL; limiting and filtering do NOT — they run in
        // the row mapper below. So this walks and sorts the whole visit table
        // even for `--limit 1`: measured ~1.1s against 273k visits, which is
        // tolerable but is a full scan, not the cheap query the shape suggests.
        // Pushing `--since` and `--limit` into SQL is tracked separately; the
        // reason it is not free is `--search`, which needs Swift-side
        // case-insensitive matching that SQLite's default LIKE will not do
        // correctly for non-ASCII.
        let sql = """
            SELECT i.url, v.title, v.visit_time, i.visit_count
            FROM history_visits v
            JOIN history_items i ON i.id = v.history_item
            ORDER BY v.visit_time DESC
            """

        let sinceReference = since.map { $0.timeIntervalSince1970 - coreDataEpochOffset }
        let needle = search?.lowercased()
        var collected: [HistoryVisit] = []

        _ = try SQLiteReader.query(at: url, sql: sql) { row -> HistoryVisit? in
            guard collected.count < limit else { return nil }
            guard row.count >= 4,
                let pageURL = row[0].stringValue,
                let reference = row[2].doubleValue
            else { return nil }

            if let sinceReference, reference < sinceReference { return nil }

            let title = row[1].stringValue
            if let needle,
                !pageURL.lowercased().contains(needle),
                !(title?.lowercased().contains(needle) ?? false)
            {
                return nil
            }

            let visit = HistoryVisit(
                url: pageURL,
                title: title,
                visitTime: date(fromCoreDataReferenceTime: reference),
                visitCount: row[3].intValue ?? 0)
            collected.append(visit)
            return visit
        }

        return collected
    }

    // MARK: - Run

    func run() throws {
        guard limit > 0 else {
            throw ValidationError("--limit must be a positive integer.")
        }
        var sinceDate: Date?
        if let since {
            guard let parsed = HistoryCommand.parseSinceDate(since) else {
                throw ValidationError("--since expects YYYY-MM-DD, got '\(since)'.")
            }
            sinceDate = parsed
        }

        let results: [HistoryVisit]
        do {
            results = try SafariDataStore.withCopy(.history) { copy in
                try HistoryCommand.visits(
                    inDatabaseAt: copy, search: search, since: sinceDate, limit: limit)
            }
        } catch let error as SafariBrowserError {
            if case .safariDataFileNotFound = error {
                LocalDataOutput.reportAbsentSource(.history, json: json)
                return
            }
            throw error
        }

        try LocalDataOutput.emit(
            json: json,
            jsonData: { try HistoryCommand.encodeJSON(results) },
            textRows: results.enumerated().map { index, visit in
                HistoryCommand.formatRow(
                    index: index + 1, visit: visit, timeZone: TimeZone.current)
            },
            legend: "history: [N]  local-time  url — title  (default limit 50; use --limit)")
    }
}
