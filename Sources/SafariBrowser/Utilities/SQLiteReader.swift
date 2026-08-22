import Foundation
import SQLite3

/// Minimal read-only SQLite access for the local-data-query commands (#109).
///
/// Deliberately not a general-purpose wrapper: it opens read-only, runs one
/// query, and hands back rows. Safari's databases are the only thing this
/// tool reads from disk, and both callers want the same three lines.
enum SQLiteReader {
    /// A single result value, narrowed to the three column types Safari's
    /// schemas actually use.
    enum Value {
        case text(String)
        case double(Double)
        case integer(Int)
        case null

        var stringValue: String? {
            if case .text(let s) = self { return s }
            return nil
        }
        var doubleValue: Double? {
            switch self {
            case .double(let d): return d
            case .integer(let i): return Double(i)
            default: return nil
            }
        }
        var intValue: Int? {
            switch self {
            case .integer(let i): return i
            case .double(let d): return Int(d)
            default: return nil
            }
        }
    }

    /// Opens `url` read-only, runs `sql`, and maps each row through `rowMapper`.
    ///
    /// `SQLITE_OPEN_READONLY` is not merely a precaution — these are the
    /// user's live browser databases, and this tool has no business being
    /// able to write to them even by accident.
    static func query<T>(
        at url: URL,
        sql: String,
        rowMapper: ([Value]) -> T?
    ) throws -> [T] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let handle = db
        else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw SafariBrowserError.safariDataParseFailed(
                path: url.path, detail: "could not open database: \(message)")
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let stmt = statement
        else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw SafariBrowserError.safariDataParseFailed(
                path: url.path, detail: "query failed: \(message)")
        }
        defer { sqlite3_finalize(stmt) }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let columnCount = Int(sqlite3_column_count(stmt))
            var row: [Value] = []
            row.reserveCapacity(columnCount)
            for column in 0..<columnCount {
                let index = Int32(column)
                switch sqlite3_column_type(stmt, index) {
                case SQLITE_TEXT:
                    row.append(.text(String(cString: sqlite3_column_text(stmt, index))))
                case SQLITE_FLOAT:
                    row.append(.double(sqlite3_column_double(stmt, index)))
                case SQLITE_INTEGER:
                    row.append(.integer(Int(sqlite3_column_int64(stmt, index))))
                default:
                    row.append(.null)
                }
            }
            if let mapped = rowMapper(row) {
                results.append(mapped)
            }
        }
        return results
    }
}
