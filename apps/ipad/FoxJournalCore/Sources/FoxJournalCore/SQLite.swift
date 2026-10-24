import Foundation
import SQLite3

enum SQLValue {
    case text(String), integer(Int64), number(Double), null
    var text: String? { if case .text(let value) = self { return value }; return nil }
    var integer: Int64? { if case .integer(let value) = self { return value }; return nil }
}

final class JournalDatabase {
    private var handle: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }; handle = nil
            throw JournalError.corruptStore
        }
        sqlite3_busy_timeout(handle, 5000)
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
        try prepared(sql, bindings) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
    }
    func rows(_ sql: String, _ bindings: [SQLValue] = []) throws -> [[SQLValue]] {
        try prepared(sql, bindings) { statement in
            var rows: [[SQLValue]] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW else { throw failure() }
                rows.append((0..<sqlite3_column_count(statement)).map { index in
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
                    case SQLITE_FLOAT: return .number(sqlite3_column_double(statement, index))
                    case SQLITE_TEXT:
                        return .text(String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(statement, index), count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self))
                    default: return .null
                    }
                })
            }
        }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func prepared<T>(_ sql: String, _ bindings: [SQLValue], _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1), result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .integer(let integer): result = sqlite3_bind_int64(statement, index, integer)
            case .number(let number): result = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                result = string.withCString { sqlite3_bind_text(statement, index, $0, Int32(string.utf8.count), transient) }
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        return try body(statement)
    }
    private func failure() -> JournalError {
        let code = sqlite3_errcode(handle)
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB { return .corruptStore }
        return .sqlite(String(cString: sqlite3_errmsg(handle)))
    }
}
