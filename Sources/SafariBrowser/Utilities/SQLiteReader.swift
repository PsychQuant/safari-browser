import Foundation
import SQLite3
import Darwin

enum SQLiteReader {
    enum Value {
        case text(String), double(Double), integer(Int), null
        var stringValue: String? { if case .text(let s) = self { return s }; return nil }
        var doubleValue: Double? {
            switch self {
            case .double(let d): return d.isFinite ? d : nil
            case .integer(let i): return Double(i)
            default: return nil
            }
        }
        var intValue: Int? {
            switch self {
            case .integer(let i): return i
            case .double(let d):
                return Int(exactly: d)
            default: return nil
            }
        }
    }

    final class Database {
        fileprivate let handle: OpaquePointer
        let sourceURL: URL
        fileprivate init(_ handle: OpaquePointer, sourceURL: URL) {
            self.handle = handle; self.sourceURL = sourceURL
        }
        deinit { sqlite3_close_v2(handle) }
    }

    static func withDatabase<T>(at url: URL, _ body: (Database) throws -> T) throws -> T {
        let fd = try SafariDataStore.openSource(url)
        close(fd)
        let db = try open(path: url.path, flags: SQLITE_OPEN_READONLY, source: url)
        try execute(db, "PRAGMA temp_store=MEMORY")
        return try body(db)
    }

    private struct InitializationFailure: Error {
        let code: Int32
        let reported: SafariBrowserError
    }

    /// Backup while holding a read transaction, then query only private memory.
    static func withSnapshot<T>(
        at url: URL, timeout: TimeInterval = 5,
        afterStep: (() throws -> Void)? = nil,
        _ body: (Database) throws -> T
    ) throws -> T {
        guard timeout.isFinite, timeout > 0 else {
            throw SafariBrowserError.safariDataReadFailed(path: url.path, detail: "snapshot timeout must be positive and finite")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let snapshot: Database
        do {
            snapshot = try initialSnapshot(at: url, deadline: deadline, timeout: timeout, afterStep: afterStep)
        } catch let failure as InitializationFailure {
            guard failure.code & 0xff == SQLITE_CANTOPEN else { throw failure.reported }
            // Some macOS SQLite builds cannot open a checkpointed WAL header
            // with no sidecars read-only. Never create a WAL in the user's folder.
            // Instead require a SQLite-compatible exclusive lease before using
            // an immutable reader of the held descriptor; file metadata is not
            // used as a heuristic proof that a live source is immutable.
            do {
                snapshot = try checkpointedSnapshot(at: url, deadline: deadline, timeout: timeout,
                                                    afterStep: afterStep, originalError: failure.reported)
            } catch let nested as InitializationFailure { throw nested.reported }
        }
        return try body(snapshot)
    }

    private static func initialSnapshot(at url: URL, deadline: TimeInterval, timeout: TimeInterval,
                                        afterStep: (() throws -> Void)?) throws -> Database {
        let fd = try SafariDataStore.openSource(url)
        close(fd)
        let source = try open(path: url.path, flags: SQLITE_OPEN_READONLY, source: url, initialization: true)
        try execute(source, "PRAGMA temp_store=MEMORY", initialization: true)
        return try backup(source: source, deadline: deadline, timeout: timeout, afterStep: afterStep)
    }

    private static func backup(source: Database, deadline: TimeInterval, timeout: TimeInterval,
                               afterStep: (() throws -> Void)?) throws -> Database {
        let url = source.sourceURL
        sqlite3_busy_timeout(source.handle, 10)
        try execute(source, "BEGIN", initialization: true)
        defer { _ = sqlite3_exec(source.handle, "ROLLBACK", nil, nil, nil) }
        // Reading schema establishes the read snapshot before any backup
        // progress hook / concurrent checkpoint can change the view.
        var pin = sqlite3_exec(source.handle, "SELECT count(*) FROM sqlite_schema", nil, nil, nil)
        while (pin == SQLITE_BUSY || pin == SQLITE_LOCKED) && ProcessInfo.processInfo.systemUptime < deadline {
            sqlite3_sleep(5)
            pin = sqlite3_exec(source.handle, "SELECT count(*) FROM sqlite_schema", nil, nil, nil)
        }
        guard pin == SQLITE_OK else { throw InitializationFailure(code: pin, reported: failure(source, code: pin, operation: "establish snapshot")) }
        let pageSizes = try query(in: source, sql: "PRAGMA page_size") { $0[0].intValue }
        guard let pageSize = pageSizes.first, pageSize > 0 else {
            throw SafariBrowserError.safariDataParseFailed(path: url.path, detail: "missing SQLite page size")
        }
        let memory = try open(path: ":memory:", flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, source: url)
        try execute(memory, "PRAGMA page_size=\(pageSize)")
        try execute(memory, "PRAGMA temp_store=MEMORY")
        guard let backup = sqlite3_backup_init(memory.handle, "main", source.handle, "main") else {
            throw failure(memory, code: sqlite3_errcode(memory.handle), operation: "start snapshot")
        }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw SafariBrowserError.safariDataReadFailed(path: url.path, detail: "snapshot exceeded its \(timeout)-second deadline")
            }
            let rc = sqlite3_backup_step(backup, 64)
            try afterStep?()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw SafariBrowserError.safariDataReadFailed(path: url.path, detail: "snapshot exceeded its \(timeout)-second deadline")
            }
            if rc == SQLITE_DONE {
                let finish = sqlite3_backup_finish(backup); finished = true
                guard finish == SQLITE_OK else { throw failure(memory, code: finish, operation: "finish snapshot") }
                try execute(memory, "PRAGMA query_only=ON")
                return memory
            }
            guard rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED else {
                throw failure(memory, code: rc, operation: "copy snapshot", sourceHandle: source.handle)
            }
            if rc != SQLITE_OK { sqlite3_sleep(5) }
        }
    }

    /// The fallback supports local APFS/HFS POSIX locking only. An OFD lease
    /// survives SQLite opening/closing another descriptor and conflicts with
    /// its ordinary POSIX database locks, including other connections in this
    /// process. R/W access is used solely to acquire the write lock; no data is
    /// written. The SQLite connection itself remains read-only and immutable.
    static func checkpointedSnapshot(at url: URL, deadline: TimeInterval, timeout: TimeInterval,
                                             afterStep: (() throws -> Void)?, originalError: SafariBrowserError) throws -> Database {
        // Avoid a writable source ever occupying a closed standard descriptor.
        guard (0...2).allSatisfy({ fcntl(Int32($0), F_GETFD) >= 0 }) else { throw originalError }
        let fd = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw originalError }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw originalError }
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else { throw originalError }
        let kind = withUnsafePointer(to: &filesystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        guard kind == "apfs" || kind == "hfs" else { throw originalError }
        // SQLite's PENDING, RESERVED and SHARED locking bytes (lockingv3.html).
        var lease = flock(l_start: 0x40000000, l_len: 512, l_pid: 0,
                          l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        while fcntl(fd, F_OFD_SETLK, &lease) != 0 {
            let code = errno
            guard [EAGAIN, EACCES, EINTR].contains(code), ProcessInfo.processInfo.systemUptime < deadline else { throw originalError }
            sqlite3_sleep(5)
        }
        var header = [UInt8](repeating: 0, count: 20)
        guard pread(fd, &header, header.count, 0) == header.count,
              Array(header.prefix(16)) == Array("SQLite format 3\0".utf8), header[18] == 2, header[19] == 2 else { throw originalError }
        // With cooperating SQLite writers excluded, a missing/empty WAL holds
        // no committed frames. A nonempty WAL must use normal SQLite recovery.
        for suffix in ["-wal", "-journal"] {
            var sidecar = stat()
            if lstat(url.path + suffix, &sidecar) == 0 {
                guard sidecar.st_mode & S_IFMT == S_IFREG, sidecar.st_size == 0 else { throw originalError }
            } else if errno != ENOENT { throw originalError }
        }
        let source = try open(path: "file:/dev/fd/\(fd)?immutable=1",
                              flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, source: url)
        try execute(source, "PRAGMA temp_store=MEMORY")
        return try backup(source: source, deadline: deadline, timeout: timeout, afterStep: afterStep)
    }

    private static func open(path: String, flags: Int32, source: URL, initialization: Bool = false) throws -> Database {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_PRIVATECACHE, nil)
        guard rc == SQLITE_OK, let handle else {
            let code = handle.map { sqlite3_system_errno($0) } ?? 0
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database handle"
            sqlite3_close(handle)
            let reported = sqliteAccessError(path: source.path, systemCode: code,
                                             detail: "could not open database: \(message) (sqlite code \(rc))")
            if initialization { throw InitializationFailure(code: rc, reported: reported) }
            throw reported
        }
        return Database(handle, sourceURL: source)
    }

    private static func execute(_ db: Database, _ sql: String, initialization: Bool = false) throws {
        let rc = sqlite3_exec(db.handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else {
            let reported = failure(db, code: rc, operation: "prepare snapshot")
            if initialization { throw InitializationFailure(code: rc, reported: reported) }
            throw reported
        }
    }

    private static func failure(_ db: Database, code: Int32, operation: String, sourceHandle: OpaquePointer? = nil) -> SafariBrowserError {
        let system = sqlite3_system_errno(db.handle)
        let sourceSystem = sourceHandle.map { sqlite3_system_errno($0) } ?? 0
        // sqlite3_system_errno may retain an earlier filesystem failure.
        // Consult it only for a current filesystem-class SQLite error, never
        // let stale ENOENT turn malformed SQL/data into a successful absence.
        if [SQLITE_IOERR, SQLITE_CANTOPEN].contains(code & 0xff), system != 0 || sourceSystem != 0 {
            return sqliteAccessError(path: db.sourceURL.path, systemCode: system != 0 ? system : sourceSystem,
                detail: "\(operation): \(String(cString: sqlite3_errmsg(db.handle))) (sqlite code \(code))")
        }
        let detail = "\(operation): \(String(cString: sqlite3_errmsg(db.handle))) (sqlite code \(code), extended \(sqlite3_extended_errcode(db.handle)))"
        switch code & 0xff {
        case SQLITE_ERROR, SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_SCHEMA:
            return .safariDataParseFailed(path: db.sourceURL.path, detail: detail)
        default: return .safariDataReadFailed(path: db.sourceURL.path, detail: detail)
        }
    }

    private static func sqliteAccessError(path: String, systemCode: Int32, detail: String) -> SafariBrowserError {
        // Only the initial POSIX source open can establish ordinary absence.
        // SQLite may be opening an auxiliary WAL/journal after main is present.
        if systemCode == EACCES || systemCode == EPERM {
            return .fullDiskAccessRequired(path: path, signing: CodeSigningState.current())
        }
        let suffix = systemCode == 0 ? "" : "; \(String(cString: strerror(systemCode))) (errno \(systemCode))"
        return .safariDataReadFailed(path: path, detail: detail + suffix)
    }

    static func query<T>(at url: URL, sql: String, bindings: [Value] = [], maxResults: Int? = nil,
                         rowMapper: ([Value]) throws -> T?) throws -> [T] {
        try withDatabase(at: url) { try query(in: $0, sql: sql, bindings: bindings, maxResults: maxResults, rowMapper: rowMapper) }
    }

    static func query<T>(in db: Database, sql: String, bindings: [Value] = [], maxResults: Int? = nil,
                         rowMapper: ([Value]) throws -> T?) throws -> [T] {
        if let maxResults, maxResults <= 0 { return [] }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(db.handle, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let stmt = statement else {
            sqlite3_finalize(statement)
            throw failure(db, code: prepare, operation: "query failed")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_parameter_count(stmt) == Int32(bindings.count) else {
            throw SafariBrowserError.safariDataParseFailed(path: db.sourceURL.path, detail: "query binding count mismatch")
        }
        for (i, value) in bindings.enumerated() {
            let slot = Int32(i + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, slot)
            case .integer(let n): rc = sqlite3_bind_int64(stmt, slot, Int64(n))
            case .double(let n): rc = sqlite3_bind_double(stmt, slot, n)
            case .text(let text): rc = text.withCString { sqlite3_bind_text(stmt, slot, $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            }
            guard rc == SQLITE_OK else { throw failure(db, code: rc, operation: "bind query") }
        }
        var results: [T] = []
        var rowsStepped = 0
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return results }
            guard rc == SQLITE_ROW else {
                throw failure(db, code: rc, operation: "query stopped after \(rowsStepped) row(s), \(results.count) accepted; requested result was not completed")
            }
            rowsStepped += 1
            let row: [Value] = (0..<sqlite3_column_count(stmt)).map { index in
                switch sqlite3_column_type(stmt, index) {
                case SQLITE_TEXT:
                    guard let bytes = sqlite3_column_text(stmt, index) else { return .null }
                    return .text(String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(stmt, index))), as: UTF8.self))
                case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, index))
                case SQLITE_INTEGER: return .integer(Int(sqlite3_column_int64(stmt, index)))
                default: return .null
                }
            }
            let columnError = sqlite3_errcode(db.handle)
            if columnError != SQLITE_OK && columnError != SQLITE_ROW {
                throw failure(db, code: columnError, operation: "decode row \(rowsStepped)")
            }
            if let mapped = try rowMapper(row) { results.append(mapped) }
            if let maxResults, results.count >= maxResults { return results }
        }
    }
}
