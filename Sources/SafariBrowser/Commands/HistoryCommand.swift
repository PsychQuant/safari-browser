import ArgumentParser
import Foundation

/// One visited page, as recorded in `History.db` (#109).
struct HistoryVisit: Equatable {
    let url: String
    let title: String?
    let visitTime: Date?
    let visitCount: Int?
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

        let stamp = visit.visitTime.map { formatter.string(from: $0) } ?? "(no date)"
        let title = LocalDataOutput.sanitizeTextField(visit.title ?? "")
        let suffix = title.isEmpty ? "" : " — \(title)"
        return "[\(index)]  \(stamp)  \(LocalDataOutput.sanitizeTextField(visit.url))\(suffix)"
    }

    static func encodeJSON(_ visits: [HistoryVisit]) throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone.current

        let payload = visits.map { visit -> [String: Any] in
            [
                "url": visit.url,
                "title": visit.title as Any? ?? NSNull(),
                "visit_time": visit.visitTime.map { iso.string(from: $0) } as Any? ?? NSNull(),
                "visit_count": visit.visitCount as Any? ?? NSNull(),
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
        try SQLiteReader.withDatabase(at: url) { database in
            try visits(in: database, search: search, since: since, limit: limit)
        }
    }

    static func visits(
        in database: SQLiteReader.Database, search: String?, since: Date?, limit: Int
    ) throws -> [HistoryVisit] {
        guard limit > 0 else { throw ValidationError("--limit must be a positive integer.") }
        var sql = """
            SELECT i.url, v.title, v.visit_time, i.visit_count
            FROM history_visits v
            LEFT JOIN history_items i ON i.id = v.history_item
            """
        var bindings: [SQLiteReader.Value] = []
        if let since {
            sql += " WHERE typeof(v.visit_time) IN ('integer', 'real') AND v.visit_time >= ?"
            bindings.append(.double(since.timeIntervalSince1970 - coreDataEpochOffset))
        }
        sql += " ORDER BY v.visit_time DESC"

        let needle = search?.lowercased()
        var diagnostics = SchemaDiagnostics(sourceURL: database.sourceURL, context: "history")
        var index = 0
        // Count accepted results, not raw rows: malformed rows and search misses
        // must not consume --limit. Do not step again once the answer is full.
        let results = try SQLiteReader.query(
            in: database, sql: sql, bindings: bindings, maxResults: limit
        ) { row -> HistoryVisit? in
            defer { index += 1 }
            guard row.count >= 4,
                let pageURL = SchemaDiagnostics.requiredString(row[0].stringValue)
            else {
                diagnostics.invalid(at: "row[\(index)]", field: "url")
                return nil
            }
            diagnostics.valid()
            let title = row[1].stringValue
            if let needle, !pageURL.lowercased().contains(needle),
                !(title?.lowercased().contains(needle) ?? false)
            { return nil }
            let reference = row[2].doubleValue.flatMap { $0.isFinite ? $0 : nil }
            let visitTime = SchemaDiagnostics.representableDate(reference.map { date(fromCoreDataReferenceTime: $0) })
            // The SQL comparison is a fast prefilter; an unrepresentable date
            // cannot establish that the visit occurred on/after --since.
            if let since, visitTime.map({ $0 < since }) ?? true { return nil }
            return HistoryVisit(
                url: pageURL, title: title,
                visitTime: visitTime,
                visitCount: row[3].intValue.flatMap { $0 >= 0 ? $0 : nil })
        }
        try diagnostics.finish()
        return results
    }

    // MARK: - Run

    func run() throws {
        try run(sourceURL: SafariDataStore.sourceURL(for: .history))
    }

    func run(sourceURL: URL) throws {
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
            results = try SafariDataStore.withDatabaseSnapshot(sourceURL: sourceURL) { database in
                try HistoryCommand.visits(
                    in: database, search: search, since: sinceDate, limit: limit)
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
