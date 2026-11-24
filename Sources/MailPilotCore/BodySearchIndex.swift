import Foundation
import SQLite3

/// Independent local SQLite FTS5 cache (`~/Library/Caches/MailPilot/body_fts.sqlite`)
/// for instant full-text body search without ever writing to Apple Mail's `Envelope Index`.
public actor BodySearchIndex {
    private static let currentSchemaVersion: Int32 = 3
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

    private func readUserVersion(_ handle: OpaquePointer) -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
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
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA recursive_triggers=ON; PRAGMA cache_size=-2000;", nil, nil, nil)

        let existingVersion = readUserVersion(handle)
        if existingVersion < Self.currentSchemaVersion {
            // Migrate cleanly to v3: trigram tokenizer + file_mtime freshness tracking + explicit UPDATE trigger.
            let dropSQL = """
            DROP TRIGGER IF EXISTS mail_fts_ai;
            DROP TRIGGER IF EXISTS mail_fts_ad;
            DROP TRIGGER IF EXISTS mail_fts_au;
            DROP TABLE IF EXISTS mail_fts;
            DROP TABLE IF EXISTS indexed_rows;
            """
            sqlite3_exec(handle, dropSQL, nil, nil, nil)
        }

        let setupSQL = """
        CREATE TABLE IF NOT EXISTS indexed_rows (
            row_id INTEGER PRIMARY KEY,
            subject TEXT NOT NULL,
            sender TEXT NOT NULL,
            body TEXT NOT NULL,
            file_mtime REAL NOT NULL DEFAULT 0
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS mail_fts USING fts5(
            subject,
            sender,
            body,
            content='indexed_rows',
            content_rowid='row_id',
            tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS mail_fts_ai AFTER INSERT ON indexed_rows BEGIN
            INSERT INTO mail_fts(rowid, subject, sender, body) VALUES (new.row_id, new.subject, new.sender, new.body);
        END;
        CREATE TRIGGER IF NOT EXISTS mail_fts_ad AFTER DELETE ON indexed_rows BEGIN
            INSERT INTO mail_fts(mail_fts, rowid, subject, sender, body) VALUES('delete', old.row_id, old.subject, old.sender, old.body);
        END;
        CREATE TRIGGER IF NOT EXISTS mail_fts_au AFTER UPDATE ON indexed_rows BEGIN
            INSERT INTO mail_fts(mail_fts, rowid, subject, sender, body) VALUES('delete', old.row_id, old.subject, old.sender, old.body);
            INSERT INTO mail_fts(rowid, subject, sender, body) VALUES (new.row_id, new.subject, new.sender, new.body);
        END;
        PRAGMA user_version = \(Self.currentSchemaVersion);
        """
        sqlite3_exec(handle, setupSQL, nil, nil, nil)
        self.db = handle
        return handle
    }

    public func indexedRowIDs(in candidates: [Int64]) -> Set<Int64> {
        Set(indexedVersions(in: candidates).keys)
    }

    /// Returns stored `file_mtime` timestamps for candidate `row_id`s so changed `.emlx` files are re-indexed automatically.
    public func indexedVersions(in candidates: [Int64]) -> [Int64: Double] {
        guard !candidates.isEmpty, let db = ensureOpen() else { return [:] }
        var found: [Int64: Double] = [:]
        let chunkSize = 400
        var start = 0
        while start < candidates.count {
            let end = min(start + chunkSize, candidates.count)
            let chunk = Array(candidates[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT row_id, file_mtime FROM indexed_rows WHERE row_id IN (\(placeholders));"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for (idx, id) in chunk.enumerated() {
                    sqlite3_bind_int64(stmt, Int32(idx + 1), id)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    found[sqlite3_column_int64(stmt, 0)] = sqlite3_column_double(stmt, 1)
                }
                sqlite3_finalize(stmt)
            }
            start = end
        }
        return found
    }

    public func allIndexedRowIDs() -> [Int64] {
        guard let db = ensureOpen() else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT row_id FROM indexed_rows;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    public func upsertBatch(_ entries: [(rowID: Int64, subject: String, sender: String, body: String)]) {
        upsertBatchWithMTime(entries.map { ($0.rowID, $0.subject, $0.sender, $0.body, 0.0) })
    }

    public func upsertBatchWithMTime(_ entries: [(rowID: Int64, subject: String, sender: String, body: String, fileMTime: Double)]) {
        guard !entries.isEmpty, let db = ensureOpen() else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
        // Store full plain-text body (no arbitrary char truncation) and use ON CONFLICT DO UPDATE so `mail_fts_au` purges old tokens.
        let sql = """
        INSERT INTO indexed_rows(row_id, subject, sender, body, file_mtime)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(row_id) DO UPDATE SET
            subject = excluded.subject,
            sender = excluded.sender,
            body = excluded.body,
            file_mtime = excluded.file_mtime;
        """
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
            sqlite3_bind_text(stmt, 4, item.body, -1, transient)
            sqlite3_bind_double(stmt, 5, item.fileMTime)
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    public func deleteRowIDs(_ rowIDs: [Int64]) {
        guard !rowIDs.isEmpty, let db = ensureOpen() else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM indexed_rows WHERE row_id = ?;", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return
        }
        defer { sqlite3_finalize(stmt) }
        for id in rowIDs {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    public func clearAll() {
        guard let db = ensureOpen() else { return }
        sqlite3_exec(db, "DELETE FROM indexed_rows; INSERT INTO mail_fts(mail_fts) VALUES('rebuild');", nil, nil, nil)
    }

    /// Searches indexed bodies using FTS5 trigram index first (fast for 3+ char English & Chinese substrings),
    /// with LIKE fallback for 1–2 character queries.
    /// Pass `limit = nil` to return ALL matching `row_id`s (ordered newest-first) so downstream mailbox/label
    /// filtering never loses inbox hits behind non-inbox matches.
    public func searchRowIDs(query: String, limit: Int? = nil) -> [Int64] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = ensureOpen() else { return [] }

        var matched: [Int64] = []
        var seen: Set<Int64> = []
        let limitClause = limit != nil ? " LIMIT ?" : ""

        // 1. FTS5 trigram MATCH (requires >= 3 characters to match trigram tokens)
        if trimmed.count >= 3 {
            let escapedFTS = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
            let ftsQuery = "\"\(escapedFTS)\""
            let ftsSQL = "SELECT rowid FROM mail_fts WHERE mail_fts MATCH ? ORDER BY rowid DESC\(limitClause);"
            var ftsStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, ftsSQL, -1, &ftsStmt, nil) == SQLITE_OK {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(ftsStmt, 1, ftsQuery, -1, transient)
                if let limit {
                    sqlite3_bind_int(ftsStmt, 2, Int32(limit))
                }
                while sqlite3_step(ftsStmt) == SQLITE_ROW {
                    let id = sqlite3_column_int64(ftsStmt, 0)
                    if seen.insert(id).inserted {
                        matched.append(id)
                    }
                }
                sqlite3_finalize(ftsStmt)
            }
        }

        // 2. Short-query fallback (< 3 chars) or backfill when trigram returns empty
        if trimmed.count < 3 || matched.isEmpty {
            let likeSQL = "SELECT row_id FROM indexed_rows WHERE body LIKE ? OR subject LIKE ? OR sender LIKE ? ORDER BY row_id DESC\(limitClause);"
            var likeStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, likeSQL, -1, &likeStmt, nil) == SQLITE_OK {
                let pattern = "%\(trimmed)%"
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(likeStmt, 1, pattern, -1, transient)
                sqlite3_bind_text(likeStmt, 2, pattern, -1, transient)
                sqlite3_bind_text(likeStmt, 3, pattern, -1, transient)
                if let limit {
                    sqlite3_bind_int(likeStmt, 4, Int32(limit))
                }
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

    public func releaseMemory() {
        guard let db else { return }
        sqlite3_db_release_memory(db)
    }
}
