import Foundation
import SQLite3

/// Independent local SQLite FTS5 cache (`~/Library/Caches/MailPilot/body_fts.sqlite`)
/// for instant full-text body search without ever writing to Apple Mail's `Envelope Index`.
public actor BodySearchIndex {
    private let databaseURL: URL
    private var db: OpaquePointer?

    public init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dir = caches.appendingPathComponent("MailPilot", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.databaseURL = dir.appendingPathComponent("body_fts.sqlite")
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func ensureOpen() -> OpaquePointer? {
        if let db { return db }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 1000)
        let setupSQL = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS indexed_rows (
            row_id INTEGER PRIMARY KEY,
            subject TEXT NOT NULL,
            sender TEXT NOT NULL,
            body TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS mail_fts USING fts5(
            subject,
            sender,
            body,
            content='indexed_rows',
            content_rowid='row_id',
            tokenize='unicode61'
        );
        CREATE TRIGGER IF NOT EXISTS mail_fts_ai AFTER INSERT ON indexed_rows BEGIN
            INSERT INTO mail_fts(rowid, subject, sender, body) VALUES (new.row_id, new.subject, new.sender, new.body);
        END;
        CREATE TRIGGER IF NOT EXISTS mail_fts_ad AFTER DELETE ON indexed_rows BEGIN
            INSERT INTO mail_fts(mail_fts, rowid, subject, sender, body) VALUES('delete', old.row_id, old.subject, old.sender, old.body);
        END;
        """
        sqlite3_exec(handle, setupSQL, nil, nil, nil)
        self.db = handle
        return handle
    }

    public func indexedRowIDs(in candidates: [Int64]) -> Set<Int64> {
        guard !candidates.isEmpty, let db = ensureOpen() else { return [] }
        let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
        let sql = "SELECT row_id FROM indexed_rows WHERE row_id IN (\(placeholders));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (idx, id) in candidates.enumerated() {
            sqlite3_bind_int64(stmt, Int32(idx + 1), id)
        }
        var found: Set<Int64> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            found.insert(sqlite3_column_int64(stmt, 0))
        }
        return found
    }

    public func upsertBatch(_ entries: [(rowID: Int64, subject: String, sender: String, body: String)]) {
        guard !entries.isEmpty, let db = ensureOpen() else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
        let sql = "INSERT OR REPLACE INTO indexed_rows(row_id, subject, sender, body) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for item in entries {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, item.rowID)
            sqlite3_bind_text(stmt, 2, item.subject, -1, transient)
            sqlite3_bind_text(stmt, 3, item.sender, -1, transient)
            sqlite3_bind_text(stmt, 4, String(item.body.prefix(12000)), -1, transient)
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    /// Searches indexed bodies using FTS5 first, with substring LIKE fallback for CJK partial terms.
    public func searchRowIDs(query: String, limit: Int = 200) -> [Int64] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = ensureOpen() else { return [] }

        var matched: [Int64] = []
        var seen: Set<Int64> = []

        // 1. FTS5 MATCH (fast token/prefix query)
        let escapedFTS = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
        let ftsQuery = "\"\(escapedFTS)\""
        let ftsSQL = "SELECT rowid FROM mail_fts WHERE mail_fts MATCH ? LIMIT ?;"
        var ftsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, ftsSQL, -1, &ftsStmt, nil) == SQLITE_OK {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(ftsStmt, 1, ftsQuery, -1, transient)
            sqlite3_bind_int(ftsStmt, 2, Int32(limit))
            while sqlite3_step(ftsStmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(ftsStmt, 0)
                if seen.insert(id).inserted {
                    matched.append(id)
                }
            }
            sqlite3_finalize(ftsStmt)
        }

        // 2. Substring LIKE fallback (essential for arbitrary Chinese substrings & order numbers)
        if matched.count < limit {
            let likeSQL = "SELECT row_id FROM indexed_rows WHERE body LIKE ? OR subject LIKE ? OR sender LIKE ? LIMIT ?;"
            var likeStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, likeSQL, -1, &likeStmt, nil) == SQLITE_OK {
                let pattern = "%\(trimmed)%"
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(likeStmt, 1, pattern, -1, transient)
                sqlite3_bind_text(likeStmt, 2, pattern, -1, transient)
                sqlite3_bind_text(likeStmt, 3, pattern, -1, transient)
                sqlite3_bind_int(likeStmt, 4, Int32(limit))
                while sqlite3_step(likeStmt) == SQLITE_ROW {
                    let id = sqlite3_column_int64(likeStmt, 0)
                    if seen.insert(id).inserted {
                        matched.append(id)
                    }
                }
                sqlite3_finalize(likeStmt)
            }
        }
        return matched
    }

    public func totalIndexedCount() -> Int {
        guard let db = ensureOpen() else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM indexed_rows;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }
}
