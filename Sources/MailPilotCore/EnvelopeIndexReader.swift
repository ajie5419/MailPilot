import Foundation
import SQLite3

/// Strictly read-only reader for Apple Mail's `Envelope Index` SQLite database.
/// Never writes to SQLite directly to avoid corrupting Mail.app's sync state.
public final class EnvelopeIndexReader: @unchecked Sendable {
    public let mailVersionURL: URL
    public let databaseURL: URL
    private let schemaLock = NSLock()
    private var cachedMessageColumns: Set<String>?
    private var cachedLabelTableResolved = false
    private var cachedLabelTable: LabelTableInfo?

    private struct LabelTableInfo {
        let tableName: String
        let messageColumn: String
        let mailboxColumn: String
    }

    public init(mailVersionURL: URL, databaseURL: URL) {
        self.mailVersionURL = mailVersionURL
        self.databaseURL = databaseURL
    }

    /// Discovers the highest `~/Library/Mail/V*` directory containing `MailData/Envelope Index`.
    public static func discoverDefault() throws -> EnvelopeIndexReader {
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail", isDirectory: true)

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && (nsError.code == NSFileReadNoPermissionError || nsError.code == 257) {
                throw MailAccessError.fullDiskAccessRequired(path: baseURL.path)
            }
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EPERM) {
                throw MailAccessError.fullDiskAccessRequired(path: baseURL.path)
            }
            throw MailAccessError.mailDirectoryNotFound
        }

        let versionDirs = contents
            .filter { $0.lastPathComponent.hasPrefix("V") }
            .compactMap { url -> (Int, URL)? in
                let numStr = String(url.lastPathComponent.dropFirst())
                guard let num = Int(numStr) else { return nil }
                return (num, url)
            }
            .sorted { $0.0 > $1.0 }

        for (_, versionURL) in versionDirs {
            let dbURL = versionURL
                .appendingPathComponent("MailData", isDirectory: true)
                .appendingPathComponent("Envelope Index", isDirectory: false)
            if FileManager.default.fileExists(atPath: dbURL.path) {
                return EnvelopeIndexReader(mailVersionURL: versionURL, databaseURL: dbURL)
            }
        }

        throw MailAccessError.mailDirectoryNotFound
    }

    public func fetchMailboxes() throws -> [MailboxInfo] {
        let db = try openReadOnly()
        defer { sqlite3_close(db) }

        let sql: String
        if let labelTable = inspectLabelTable(db: db) {
            // Gmail/IMAP multi-label messages may live in `[Gmail]/All Mail` as their primary `m.mailbox`
            // while referencing `INBOX` / `Starred` / custom folders via the `labels` join table.
            sql = """
            SELECT mb.ROWID,
                   COALESCE(mb.url, ''),
                   COALESCE(u.cnt, 0) AS unread_count
            FROM mailboxes mb
            LEFT JOIN (
                SELECT mailbox_id, COUNT(DISTINCT msg_id) AS cnt
                FROM (
                    SELECT m.mailbox AS mailbox_id, m.ROWID AS msg_id
                    FROM messages m
                    WHERE COALESCE(m.read, 0) = 0 AND COALESCE(m.deleted, 0) = 0
                    UNION ALL
                    SELECT l.\(labelTable.mailboxColumn) AS mailbox_id, m.ROWID AS msg_id
                    FROM \(labelTable.tableName) l
                    JOIN messages m ON m.ROWID = l.\(labelTable.messageColumn)
                    WHERE COALESCE(m.read, 0) = 0 AND COALESCE(m.deleted, 0) = 0
                )
                GROUP BY mailbox_id
            ) u ON u.mailbox_id = mb.ROWID
            ORDER BY unread_count DESC, mb.ROWID ASC;
            """
        } else {
            sql = """
            SELECT mb.ROWID,
                   COALESCE(mb.url, ''),
                   COALESCE(SUM(CASE WHEN m.ROWID IS NOT NULL AND COALESCE(m.read, 0) = 0 AND COALESCE(m.deleted, 0) = 0 THEN 1 ELSE 0 END), 0) AS unread_count
            FROM mailboxes mb
            LEFT JOIN messages m ON m.mailbox = mb.ROWID
            GROUP BY mb.ROWID
            ORDER BY unread_count DESC, mb.ROWID ASC;
            """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailAccessError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [MailboxInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let url = columnText(stmt, 1)
            let unread = Int(sqlite3_column_int64(stmt, 2))
            let displayName = Self.humanizeMailboxURL(url)
            if !displayName.isEmpty && !Self.isInternalUUIDFolder(displayName) {
                let accountID = Self.extractAccountID(from: url)
                let sortOrder = Self.mailboxSortOrder(displayName: displayName)
                results.append(
                    MailboxInfo(
                        id: id,
                        url: url,
                        accountID: accountID,
                        displayName: displayName,
                        unreadCount: unread,
                        sortOrder: sortOrder
                    )
                )
            }
        }
        return results
    }

    public func fetchMessages(
        mailboxID: Int64? = nil,
        onlyInbox: Bool = false,
        onlyUnread: Bool = false,
        onlyFlagged: Bool = false,
        searchQuery: String = "",
        limit: Int = 150,
        offset: Int = 0
    ) throws -> [MailMessageSummary] {
        let db = try openReadOnly()
        defer { sqlite3_close(db) }

        let messageColumns = inspectColumns(db: db, table: "messages")
        let labelTable = inspectLabelTable(db: db)
        let hasDeleted = messageColumns.contains("deleted")
        let hasMessageIDHeader = messageColumns.contains("message_id")
        let hasDateReceived = messageColumns.contains("date_received")
        let dateCol = hasDateReceived ? "m.date_received" : "m.date_sent"
        let msgIDExpr = hasMessageIDHeader ? "CAST(m.message_id AS TEXT)" : "NULL"

        var conditions: [String] = []
        if hasDeleted {
            conditions.append("COALESCE(m.deleted, 0) = 0")
        }
        var bindMailboxTwice = false
        if mailboxID != nil {
            if let labelTable {
                conditions.append("(m.mailbox = ? OR EXISTS (SELECT 1 FROM \(labelTable.tableName) l WHERE l.\(labelTable.messageColumn) = m.ROWID AND l.\(labelTable.mailboxColumn) = ?))")
                bindMailboxTwice = true
            } else {
                conditions.append("m.mailbox = ?")
            }
        } else if onlyInbox {
            // Strictly query all accounts' INBOX only (supports trailing slash, Chinese Inbox URLs,
            // and Gmail messages whose primary `m.mailbox` is `[Gmail]/All Mail` with an `INBOX` label).
            let directInbox = Self.inboxURLCondition(alias: "mb")
            if let labelTable {
                let labeledInbox = Self.inboxURLCondition(alias: "lmb")
                conditions.append("(\(directInbox) OR EXISTS (SELECT 1 FROM \(labelTable.tableName) l JOIN mailboxes lmb ON lmb.ROWID = l.\(labelTable.mailboxColumn) WHERE l.\(labelTable.messageColumn) = m.ROWID AND \(labeledInbox)))")
            } else {
                conditions.append(directInbox)
            }
        } else if !onlyFlagged {
            // Exclude Junk / Trash / Deleted Messages from tag & cross-mailbox views.
            conditions.append("LOWER(COALESCE(mb.url, '')) NOT LIKE '%/junk%'")
            conditions.append("LOWER(COALESCE(mb.url, '')) NOT LIKE '%/spam%'")
            conditions.append("LOWER(COALESCE(mb.url, '')) NOT LIKE '%/trash%'")
            conditions.append("LOWER(COALESCE(mb.url, '')) NOT LIKE '%deleted%20messages%'")
            conditions.append("LOWER(COALESCE(mb.url, '')) NOT LIKE '%deleted messages%'")
        }
        if onlyUnread {
            conditions.append("COALESCE(m.read, 0) = 0")
        }
        if onlyFlagged {
            conditions.append("COALESCE(m.flagged, 0) != 0")
        }

        let trimmedSearch = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            conditions.append("(COALESCE(s.subject, '') LIKE ? OR COALESCE(a.address, '') LIKE ? OR COALESCE(a.comment, '') LIKE ?)")
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let sql = """
        SELECT m.ROWID,
               \(msgIDExpr),
               COALESCE(s.subject, '(无主题)'),
               COALESCE(a.address, ''),
               COALESCE(a.comment, ''),
               COALESCE(\(dateCol), 0),
               COALESCE(m.read, 0),
               COALESCE(m.flagged, 0),
               COALESCE(m.mailbox, 0),
               COALESCE(mb.url, '')
        FROM messages m
        LEFT JOIN subjects s ON m.subject = s.ROWID
        LEFT JOIN addresses a ON m.sender = a.ROWID
        LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
        \(whereClause)
        ORDER BY \(dateCol) DESC, m.ROWID DESC
        LIMIT ? OFFSET ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailAccessError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var bindIdx: Int32 = 1
        if let mailboxID {
            sqlite3_bind_int64(stmt, bindIdx, mailboxID)
            bindIdx += 1
            if bindMailboxTwice {
                sqlite3_bind_int64(stmt, bindIdx, mailboxID)
                bindIdx += 1
            }
        }
        if !trimmedSearch.isEmpty {
            let pattern = "%\(trimmedSearch)%"
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for _ in 0..<3 {
                sqlite3_bind_text(stmt, bindIdx, pattern, -1, transient)
                bindIdx += 1
            }
        }
        sqlite3_bind_int(stmt, bindIdx, Int32(limit))
        bindIdx += 1
        sqlite3_bind_int(stmt, bindIdx, Int32(max(0, offset)))

        var items: [MailMessageSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let msgIDHeader = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : columnText(stmt, 1)
            let subject = columnText(stmt, 2)
            let senderAddress = columnText(stmt, 3)
            let senderName = columnText(stmt, 4)
            let timestamp = sqlite3_column_double(stmt, 5)
            let isRead = sqlite3_column_int64(stmt, 6) != 0
            let isFlagged = sqlite3_column_int64(stmt, 7) != 0
            let mbID = sqlite3_column_int64(stmt, 8)
            let mbURL = columnText(stmt, 9)

            items.append(
                MailMessageSummary(
                    id: id,
                    messageIDHeader: msgIDHeader,
                    subject: subject,
                    senderAddress: senderAddress,
                    senderName: senderName,
                    dateReceived: Date(timeIntervalSince1970: timestamp),
                    isRead: isRead,
                    isFlagged: isFlagged,
                    mailboxID: mbID,
                    mailboxName: Self.humanizeMailboxURL(mbURL),
                    accountID: Self.extractAccountID(from: mbURL)
                )
            )
        }
        return items
    }

    /// Fetches message summaries for an explicit set of `ROWID`s (used to hydrate FTS5 body search hits),
    /// applying the exact same mailbox / Gmail `labels` / inbox / unread / flagged predicates in SQL.
    /// Pass `maxCount` (e.g. `pageLimit + 1`) to prune rows older than the current top-K cutoff directly in SQL
    /// without ever missing newer inbox hits hidden behind non-inbox matches.
    public func fetchMessages(
        byRowIDs rowIDs: [Int64],
        mailboxID: Int64? = nil,
        onlyInbox: Bool = false,
        onlyUnread: Bool = false,
        onlyFlagged: Bool = false,
        maxCount: Int? = nil
    ) throws -> [MailMessageSummary] {
        guard !rowIDs.isEmpty else { return [] }
        let db = try openReadOnly()
        defer { sqlite3_close(db) }

        let messageColumns = inspectColumns(db: db, table: "messages")
        let labelTable = inspectLabelTable(db: db)
        let hasDeleted = messageColumns.contains("deleted")
        let hasMessageIDHeader = messageColumns.contains("message_id")
        let hasDateReceived = messageColumns.contains("date_received")
        let dateCol = hasDateReceived ? "m.date_received" : "m.date_sent"
        let msgIDExpr = hasMessageIDHeader ? "CAST(m.message_id AS TEXT)" : "NULL"

        // Process arbitrary numbers of body-search ROWID hits in chunks of 500.
        // When `maxCount` is set, keep only the newest `maxCount` rows and push the (date, rowid)
        // cutoff into SQL for subsequent chunks so 50,000 hits never hydrate all 50,000 structs.
        var items: [MailMessageSummary] = []
        var seenIDs: Set<Int64> = []
        let chunkSize = 500
        var start = 0
        while start < rowIDs.count {
            if Task.isCancelled { break }
            let end = min(start + chunkSize, rowIDs.count)
            let chunk = Array(rowIDs[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")

            var conditions: [String] = ["m.ROWID IN (\(placeholders))"]
            if hasDeleted {
                conditions.append("COALESCE(m.deleted, 0) = 0")
            }
            var bindMailboxTwice = false
            if mailboxID != nil {
                if let labelTable {
                    conditions.append("(m.mailbox = ? OR EXISTS (SELECT 1 FROM \(labelTable.tableName) l WHERE l.\(labelTable.messageColumn) = m.ROWID AND l.\(labelTable.mailboxColumn) = ?))")
                    bindMailboxTwice = true
                } else {
                    conditions.append("m.mailbox = ?")
                }
            } else if onlyInbox {
                let directInbox = Self.inboxURLCondition(alias: "mb")
                if let labelTable {
                    let labeledInbox = Self.inboxURLCondition(alias: "lmb")
                    conditions.append("(\(directInbox) OR EXISTS (SELECT 1 FROM \(labelTable.tableName) l JOIN mailboxes lmb ON lmb.ROWID = l.\(labelTable.mailboxColumn) WHERE l.\(labelTable.messageColumn) = m.ROWID AND \(labeledInbox)))")
                } else {
                    conditions.append(directInbox)
                }
            }
            if onlyUnread {
                conditions.append("COALESCE(m.read, 0) = 0")
            }
            if onlyFlagged {
                conditions.append("COALESCE(m.flagged, 0) != 0")
            }

            var cutoffDate: Double?
            var cutoffID: Int64?
            if let maxCount, items.count >= maxCount {
                let last = items[maxCount - 1]
                cutoffDate = last.dateReceived.timeIntervalSince1970
                cutoffID = last.id
                conditions.append("(COALESCE(\(dateCol), 0) > ? OR (COALESCE(\(dateCol), 0) = ? AND m.ROWID > ?))")
            }

            let orderAndLimit = maxCount != nil ? "ORDER BY \(dateCol) DESC, m.ROWID DESC LIMIT ?" : ""
            let sql = """
            SELECT m.ROWID,
                   \(msgIDExpr),
                   COALESCE(s.subject, '(无主题)'),
                   COALESCE(a.address, ''),
                   COALESCE(a.comment, ''),
                   COALESCE(\(dateCol), 0),
                   COALESCE(m.read, 0),
                   COALESCE(m.flagged, 0),
                   COALESCE(m.mailbox, 0),
                   COALESCE(mb.url, '')
            FROM messages m
            LEFT JOIN subjects s ON m.subject = s.ROWID
            LEFT JOIN addresses a ON m.sender = a.ROWID
            LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
            WHERE \(conditions.joined(separator: " AND "))
            \(orderAndLimit);
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MailAccessError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            var bindIdx: Int32 = 1
            for id in chunk {
                sqlite3_bind_int64(stmt, bindIdx, id)
                bindIdx += 1
            }
            if let mailboxID {
                sqlite3_bind_int64(stmt, bindIdx, mailboxID)
                bindIdx += 1
                if bindMailboxTwice {
                    sqlite3_bind_int64(stmt, bindIdx, mailboxID)
                    bindIdx += 1
                }
            }
            if let cutoffDate, let cutoffID {
                sqlite3_bind_double(stmt, bindIdx, cutoffDate)
                bindIdx += 1
                sqlite3_bind_double(stmt, bindIdx, cutoffDate)
                bindIdx += 1
                sqlite3_bind_int64(stmt, bindIdx, cutoffID)
                bindIdx += 1
            }
            if let maxCount {
                sqlite3_bind_int(stmt, bindIdx, Int32(maxCount))
            }

            var addedInChunk = false
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                guard seenIDs.insert(id).inserted else { continue }
                let msgIDHeader = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : columnText(stmt, 1)
                let subject = columnText(stmt, 2)
                let senderAddress = columnText(stmt, 3)
                let senderName = columnText(stmt, 4)
                let timestamp = sqlite3_column_double(stmt, 5)
                let isRead = sqlite3_column_int64(stmt, 6) != 0
                let isFlagged = sqlite3_column_int64(stmt, 7) != 0
                let mbID = sqlite3_column_int64(stmt, 8)
                let mbURL = columnText(stmt, 9)

                items.append(
                    MailMessageSummary(
                        id: id,
                        messageIDHeader: msgIDHeader,
                        subject: subject,
                        senderAddress: senderAddress,
                        senderName: senderName,
                        dateReceived: Date(timeIntervalSince1970: timestamp),
                        isRead: isRead,
                        isFlagged: isFlagged,
                        mailboxID: mbID,
                        mailboxName: Self.humanizeMailboxURL(mbURL),
                        accountID: Self.extractAccountID(from: mbURL)
                    )
                )
                addedInChunk = true
            }

            if addedInChunk, let maxCount {
                items.sort {
                    if $0.dateReceived != $1.dateReceived {
                        return $0.dateReceived > $1.dateReceived
                    }
                    return $0.id > $1.id
                }
                if items.count > maxCount {
                    items.removeSubrange(maxCount...)
                }
            }
            start = end
        }
        items.sort {
            if $0.dateReceived != $1.dateReceived {
                return $0.dateReceived > $1.dateReceived
            }
            return $0.id > $1.id
        }
        return items
    }

    public struct MessagePage: Sendable {
        public let messages: [MailMessageSummary]
        public let hasMore: Bool

        public init(messages: [MailMessageSummary], hasMore: Bool) {
            self.messages = messages
            self.hasMore = hasMore
        }
    }

    /// Fetches a paginated window of messages, seamlessly merging optional FTS5 body-search hits with SQL
    /// subject/sender hits in chronological order so pagination (`hasMore`) works identically whether or not
    /// local body indexing has completed.
    public func fetchMessagePage(
        mailboxID: Int64? = nil,
        onlyInbox: Bool = false,
        onlyUnread: Bool = false,
        onlyFlagged: Bool = false,
        searchQuery: String = "",
        bodyHitIDs: [Int64] = [],
        limit: Int = 200,
        predicate: ((MailMessageSummary) -> Bool)? = nil
    ) throws -> MessagePage {
        let safeLimit = max(1, limit)
        let fetchLimit = safeLimit + 1
        var rows = try fetchMessages(
            mailboxID: mailboxID,
            onlyInbox: onlyInbox,
            onlyUnread: onlyUnread,
            onlyFlagged: onlyFlagged,
            searchQuery: searchQuery,
            limit: fetchLimit
        )
        let sqlHasMore = rows.count > safeLimit

        if !bodyHitIDs.isEmpty && !Task.isCancelled {
            let existingIDs = Set(rows.map(\.id))
            let extraIDs = bodyHitIDs.filter { !existingIDs.contains($0) }
            if !extraIDs.isEmpty {
                // When no post-SQL tag predicate is active, bound hydration strictly to `fetchLimit`
                // so 50,000 body matches never allocate/sort 50,000 summary objects just to show 200.
                let extraRows = try fetchMessages(
                    byRowIDs: extraIDs,
                    mailboxID: mailboxID,
                    onlyInbox: onlyInbox,
                    onlyUnread: onlyUnread,
                    onlyFlagged: onlyFlagged,
                    maxCount: predicate == nil ? fetchLimit : nil
                )
                rows.append(contentsOf: extraRows)
                rows.sort {
                    if $0.dateReceived != $1.dateReceived {
                        return $0.dateReceived > $1.dateReceived
                    }
                    return $0.id > $1.id
                }
            }
        }

        if let predicate {
            let candidates = (sqlHasMore && bodyHitIDs.isEmpty) ? Array(rows.prefix(safeLimit)) : rows
            var filtered = candidates.filter(predicate)
            let hasMore = sqlHasMore || filtered.count > safeLimit
            if filtered.count > safeLimit {
                filtered = Array(filtered.prefix(safeLimit))
            }
            return MessagePage(messages: filtered, hasMore: hasMore)
        }

        let hasMore = sqlHasMore || rows.count > safeLimit
        if rows.count > safeLimit {
            rows = Array(rows.prefix(safeLimit))
        }
        return MessagePage(messages: rows, hasMore: hasMore)
    }

    /// Returns the subset of `candidates` that still exist (and are not deleted) in `Envelope Index`.
    public func existingRowIDs(in candidates: [Int64]) throws -> Set<Int64> {
        guard !candidates.isEmpty else { return [] }
        let db = try openReadOnly()
        defer { sqlite3_close(db) }

        let messageColumns = inspectColumns(db: db, table: "messages")
        let deletedCond = messageColumns.contains("deleted") ? " AND COALESCE(deleted, 0) = 0" : ""

        var present: Set<Int64> = []
        let chunkSize = 500
        var start = 0
        while start < candidates.count {
            let end = min(start + chunkSize, candidates.count)
            let chunk = Array(candidates[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT ROWID FROM messages WHERE ROWID IN (\(placeholders))\(deletedCond);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for (idx, id) in chunk.enumerated() {
                    sqlite3_bind_int64(stmt, Int32(idx + 1), id)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    present.insert(sqlite3_column_int64(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
            start = end
        }
        return present
    }

    /// Pages through all non-deleted, non-junk/trash messages across the entire mailbox history
    /// using O(log N) primary-key cursor pagination (`m.ROWID < beforeRowID ORDER BY m.ROWID DESC`)
    /// so deep pages remain sub-millisecond even with 50,000+ historical emails.
    public func fetchIndexableMessages(beforeRowID: Int64?, limit: Int = 200) throws -> [MailMessageSummary] {
        let db = try openReadOnly()
        defer { sqlite3_close(db) }

        let messageColumns = inspectColumns(db: db, table: "messages")
        let hasDeleted = messageColumns.contains("deleted")
        let hasMessageIDHeader = messageColumns.contains("message_id")
        let hasDateReceived = messageColumns.contains("date_received")
        let dateCol = hasDateReceived ? "m.date_received" : "m.date_sent"
        let msgIDExpr = hasMessageIDHeader ? "CAST(m.message_id AS TEXT)" : "NULL"

        var conditions: [String] = []
        if hasDeleted {
            conditions.append("COALESCE(m.deleted, 0) = 0")
        }
        conditions.append("LOWER(COALESCE(mb.url, '')) NOT LIKE '%/junk%'")
        conditions.append("LOWER(COALESCE(mb.url, '')) NOT LIKE '%/spam%'")
        conditions.append("LOWER(COALESCE(mb.url, '')) NOT LIKE '%/trash%'")
        conditions.append("LOWER(COALESCE(mb.url, '')) NOT LIKE '%deleted%20messages%'")
        conditions.append("LOWER(COALESCE(mb.url, '')) NOT LIKE '%deleted messages%'")
        if beforeRowID != nil {
            conditions.append("m.ROWID < ?")
        }

        let sql = """
        SELECT m.ROWID,
               \(msgIDExpr),
               COALESCE(s.subject, '(无主题)'),
               COALESCE(a.address, ''),
               COALESCE(a.comment, ''),
               COALESCE(\(dateCol), 0),
               COALESCE(m.read, 0),
               COALESCE(m.flagged, 0),
               COALESCE(m.mailbox, 0),
               COALESCE(mb.url, '')
        FROM messages m
        LEFT JOIN subjects s ON m.subject = s.ROWID
        LEFT JOIN addresses a ON m.sender = a.ROWID
        LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY m.ROWID DESC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailAccessError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var bindIdx: Int32 = 1
        if let beforeRowID {
            sqlite3_bind_int64(stmt, bindIdx, beforeRowID)
            bindIdx += 1
        }
        sqlite3_bind_int(stmt, bindIdx, Int32(max(1, limit)))

        var items: [MailMessageSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let msgIDHeader = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : columnText(stmt, 1)
            let subject = columnText(stmt, 2)
            let senderAddress = columnText(stmt, 3)
            let senderName = columnText(stmt, 4)
            let timestamp = sqlite3_column_double(stmt, 5)
            let isRead = sqlite3_column_int64(stmt, 6) != 0
            let isFlagged = sqlite3_column_int64(stmt, 7) != 0
            let mbID = sqlite3_column_int64(stmt, 8)
            let mbURL = columnText(stmt, 9)

            items.append(
                MailMessageSummary(
                    id: id,
                    messageIDHeader: msgIDHeader,
                    subject: subject,
                    senderAddress: senderAddress,
                    senderName: senderName,
                    dateReceived: Date(timeIntervalSince1970: timestamp),
                    isRead: isRead,
                    isFlagged: isFlagged,
                    mailboxID: mbID,
                    mailboxName: Self.humanizeMailboxURL(mbURL),
                    accountID: Self.extractAccountID(from: mbURL)
                )
            )
        }
        return items
    }

    public func fetchIndexableMessages(limit: Int = 200, offset: Int = 0) throws -> [MailMessageSummary] {
        try fetchMessages(
            mailboxID: nil,
            onlyInbox: false,
            onlyUnread: false,
            onlyFlagged: false,
            searchQuery: "",
            limit: limit,
            offset: offset
        )
    }

    /// Returns the maximum `ROWID` across all inbox messages (including Gmail `labels`-linked inbox messages).
    public func fetchMaxInboxRowID() throws -> Int64 {
        let db = try openReadOnly()
        defer { sqlite3_close(db) }

        let messageColumns = inspectColumns(db: db, table: "messages")
        let labelTable = inspectLabelTable(db: db)
        let deletedCond = messageColumns.contains("deleted") ? "COALESCE(m.deleted, 0) = 0 AND " : ""
        let directInbox = Self.inboxURLCondition(alias: "mb")
        let inboxCond: String
        if let labelTable {
            let labeledInbox = Self.inboxURLCondition(alias: "lmb")
            inboxCond = "(\(directInbox) OR EXISTS (SELECT 1 FROM \(labelTable.tableName) l JOIN mailboxes lmb ON lmb.ROWID = l.\(labelTable.mailboxColumn) WHERE l.\(labelTable.messageColumn) = m.ROWID AND \(labeledInbox)))"
        } else {
            inboxCond = directInbox
        }

        let sql = """
        SELECT COALESCE(MAX(m.ROWID), 0)
        FROM messages m
        LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
        WHERE \(deletedCond)\(inboxCond);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailAccessError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    /// Queries newly arrived unread inbox messages strictly with `m.ROWID > afterRowID` (ordered ascending by ROWID).
    public func fetchUnreadInboxMessages(afterRowID: Int64, limit: Int = 100) throws -> [MailMessageSummary] {
        let db = try openReadOnly()
        defer { sqlite3_close(db) }

        let messageColumns = inspectColumns(db: db, table: "messages")
        let labelTable = inspectLabelTable(db: db)
        let hasDeleted = messageColumns.contains("deleted")
        let hasMessageIDHeader = messageColumns.contains("message_id")
        let hasDateReceived = messageColumns.contains("date_received")
        let dateCol = hasDateReceived ? "m.date_received" : "m.date_sent"
        let msgIDExpr = hasMessageIDHeader ? "CAST(m.message_id AS TEXT)" : "NULL"

        var conditions = [
            "m.ROWID > ?",
            "COALESCE(m.read, 0) = 0"
        ]
        if hasDeleted {
            conditions.append("COALESCE(m.deleted, 0) = 0")
        }
        let directInbox = Self.inboxURLCondition(alias: "mb")
        if let labelTable {
            let labeledInbox = Self.inboxURLCondition(alias: "lmb")
            conditions.append("(\(directInbox) OR EXISTS (SELECT 1 FROM \(labelTable.tableName) l JOIN mailboxes lmb ON lmb.ROWID = l.\(labelTable.mailboxColumn) WHERE l.\(labelTable.messageColumn) = m.ROWID AND \(labeledInbox)))")
        } else {
            conditions.append(directInbox)
        }

        let sql = """
        SELECT m.ROWID,
               \(msgIDExpr),
               COALESCE(s.subject, '(无主题)'),
               COALESCE(a.address, ''),
               COALESCE(a.comment, ''),
               COALESCE(\(dateCol), 0),
               COALESCE(m.read, 0),
               COALESCE(m.flagged, 0),
               COALESCE(m.mailbox, 0),
               COALESCE(mb.url, '')
        FROM messages m
        LEFT JOIN subjects s ON m.subject = s.ROWID
        LEFT JOIN addresses a ON m.sender = a.ROWID
        LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY m.ROWID ASC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailAccessError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, afterRowID)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var items: [MailMessageSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let msgIDHeader = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : columnText(stmt, 1)
            let subject = columnText(stmt, 2)
            let senderAddress = columnText(stmt, 3)
            let senderName = columnText(stmt, 4)
            let timestamp = sqlite3_column_double(stmt, 5)
            let isRead = sqlite3_column_int64(stmt, 6) != 0
            let isFlagged = sqlite3_column_int64(stmt, 7) != 0
            let mbID = sqlite3_column_int64(stmt, 8)
            let mbURL = columnText(stmt, 9)

            items.append(
                MailMessageSummary(
                    id: id,
                    messageIDHeader: msgIDHeader,
                    subject: subject,
                    senderAddress: senderAddress,
                    senderName: senderName,
                    dateReceived: Date(timeIntervalSince1970: timestamp),
                    isRead: isRead,
                    isFlagged: isFlagged,
                    mailboxID: mbID,
                    mailboxName: Self.humanizeMailboxURL(mbURL),
                    accountID: Self.extractAccountID(from: mbURL)
                )
            )
        }
        return items
    }

    /// Reads To and CC recipients for a single message from Apple Mail's `recipients` + `addresses` tables.
    public func fetchRecipients(for messageID: Int64) throws -> [MailRecipientInfo] {
        let db = try openReadOnly()
        defer { sqlite3_close(db) }

        let recipientCols = inspectColumns(db: db, table: "recipients")
        guard !recipientCols.isEmpty else { return [] }

        let msgCol = recipientCols.contains("message") ? "message" : (recipientCols.contains("message_id") ? "message_id" : nil)
        let addrCol = recipientCols.contains("address") ? "address" : (recipientCols.contains("address_id") ? "address_id" : nil)
        guard let msgCol, let addrCol else { return [] }

        let hasType = recipientCols.contains("type")
        let hasPosition = recipientCols.contains("position")
        let typeExpr = hasType ? "COALESCE(r.type, 0)" : "0"
        let orderClause = hasPosition
            ? "ORDER BY \(typeExpr) ASC, COALESCE(r.position, 0) ASC, r.ROWID ASC"
            : "ORDER BY \(typeExpr) ASC, r.ROWID ASC"

        let sql = """
        SELECT COALESCE(a.address, ''), COALESCE(a.comment, ''), \(typeExpr)
        FROM recipients r
        JOIN addresses a ON r.\(addrCol) = a.ROWID
        WHERE r.\(msgCol) = ?
        \(orderClause);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailAccessError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, messageID)

        var seen: Set<String> = []
        var results: [MailRecipientInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let address = columnText(stmt, 0).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { continue }
            let name = columnText(stmt, 1).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawType = sqlite3_column_int(stmt, 2)
            // Apple Mail convention: 0 = To, 1 = CC, 2 = BCC
            if rawType == 2 { continue }
            let isCC = (rawType == 1)
            let dedupKey = "\(isCC ? "cc" : "to"):\(address.lowercased())"
            if seen.insert(dedupKey).inserted {
                results.append(MailRecipientInfo(address: address, name: name, isCC: isCC))
            }
        }
        return results
    }

    /// Searches local known contacts in Apple Mail's `addresses` table for fast, private compose autocomplete.
    public func searchContacts(query: String, limit: Int = 8) throws -> [MailContactSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        let db = try openReadOnly()
        defer { sqlite3_close(db) }

        let addressCols = inspectColumns(db: db, table: "addresses")
        guard addressCols.contains("address") else { return [] }
        let commentExpr = addressCols.contains("comment") ? "COALESCE(a.comment, '')" : "''"

        let sql = """
        SELECT a.address,
               MAX(\(commentExpr)) AS display_name,
               COUNT(*) AS freq,
               MAX(a.ROWID) AS latest_id
        FROM addresses a
        WHERE a.address LIKE '%@%'
          AND (LOWER(a.address) LIKE ? OR LOWER(\(commentExpr)) LIKE ?)
        GROUP BY LOWER(a.address)
        ORDER BY
            CASE
                WHEN LOWER(a.address) LIKE ? THEN 0
                WHEN LOWER(MAX(\(commentExpr))) LIKE ? THEN 1
                ELSE 2
            END ASC,
            freq DESC,
            latest_id DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailAccessError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let containsPattern = "%\(trimmed)%"
        let prefixPattern = "\(trimmed)%"
        sqlite3_bind_text(stmt, 1, containsPattern, -1, transient)
        sqlite3_bind_text(stmt, 2, containsPattern, -1, transient)
        sqlite3_bind_text(stmt, 3, prefixPattern, -1, transient)
        sqlite3_bind_text(stmt, 4, prefixPattern, -1, transient)
        sqlite3_bind_int(stmt, 5, Int32(max(1, min(limit, 25))))

        var results: [MailContactSuggestion] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let address = columnText(stmt, 0).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, address.contains("@") else { continue }
            let name = columnText(stmt, 1).trimmingCharacters(in: .whitespacesAndNewlines)
            let freq = Int(sqlite3_column_int(stmt, 2))
            results.append(MailContactSuggestion(address: address, name: name, frequency: max(1, freq)))
        }
        return results
    }

    // MARK: - SQLite Helpers

    private func openReadOnly() throws -> OpaquePointer {
        var db: OpaquePointer?
        let escapedPath = databaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databaseURL.path
        let uri = "file://\(escapedPath)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX

        let rc = sqlite3_open_v2(uri, &db, flags, nil)
        guard rc == SQLITE_OK, let handle = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if let db { sqlite3_close(db) }
            if rc == SQLITE_CANTOPEN || rc == SQLITE_PERM {
                throw MailAccessError.fullDiskAccessRequired(path: databaseURL.path)
            }
            throw MailAccessError.databaseOpenFailed(code: rc, message: msg)
        }
        sqlite3_busy_timeout(handle, 1500)
        return handle
    }

    private func inspectColumns(db: OpaquePointer, table: String) -> Set<String> {
        if table == "messages" {
            schemaLock.lock()
            if let cached = cachedMessageColumns {
                schemaLock.unlock()
                return cached
            }
            schemaLock.unlock()
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var cols: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            cols.insert(columnText(stmt, 1).lowercased())
        }
        if table == "messages", !cols.isEmpty {
            schemaLock.lock()
            cachedMessageColumns = cols
            schemaLock.unlock()
        }
        return cols
    }

    private func inspectLabelTable(db: OpaquePointer) -> LabelTableInfo? {
        schemaLock.lock()
        if cachedLabelTableResolved {
            let result = cachedLabelTable
            schemaLock.unlock()
            return result
        }
        schemaLock.unlock()

        var found: LabelTableInfo?
        for candidate in ["labels", "imap_labels"] {
            let cols = inspectColumns(db: db, table: candidate)
            if cols.isEmpty { continue }
            let msgCol = cols.contains("message_id") ? "message_id" : (cols.contains("message") ? "message" : nil)
            let mbCol = cols.contains("mailbox_id") ? "mailbox_id" : (cols.contains("mailbox") ? "mailbox" : nil)
            if let msgCol, let mbCol {
                found = LabelTableInfo(tableName: candidate, messageColumn: msgCol, mailboxColumn: mbCol)
                break
            }
        }

        schemaLock.lock()
        cachedLabelTable = found
        cachedLabelTableResolved = true
        schemaLock.unlock()
        return found
    }

    private static func inboxURLCondition(alias: String) -> String {
        "(LOWER(RTRIM(COALESCE(\(alias).url, ''), '/')) LIKE '%/inbox' OR COALESCE(\(alias).url, '') LIKE '%/%E6%94%B6%E4%BB%B6%E7%AE%B1%' OR COALESCE(\(alias).url, '') LIKE '%/收件箱%')"
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    static func isInternalUUIDFolder(_ name: String) -> Bool {
        let pattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    public static func extractAccountID(from urlString: String) -> String {
        guard let comps = URLComponents(string: urlString) else { return "local" }
        let scheme = (comps.scheme ?? "").lowercased()
        if scheme == "local" || scheme.isEmpty {
            return "local"
        }
        if let host = comps.host, !host.isEmpty {
            return host.uppercased()
        }
        return "local"
    }

    static func mailboxSortOrder(displayName: String) -> Int {
        switch displayName {
        case "收件箱": return 0
        case "已加星标", "Starred": return 1
        case "重要", "Important": return 2
        case "已发送", "已发邮件": return 3
        case "草稿", "草稿箱": return 4
        case "归档", "所有邮件": return 5
        case "垃圾邮件": return 6
        case "废纸篓", "已删除邮件": return 7
        default: return 10
        }
    }

    static func humanizeMailboxURL(_ urlString: String) -> String {
        guard !urlString.isEmpty else { return "" }
        let decoded = urlString.removingPercentEncoding ?? urlString
        guard let lastComponent = decoded.split(separator: "/").last else { return decoded }
        let name = String(lastComponent)
        switch name.uppercased() {
        case "INBOX":
            return "收件箱"
        case "SENT MESSAGES", "SENT", "SENT MAIL":
            return "已发送"
        case "DRAFTS":
            return "草稿"
        case "DELETED MESSAGES", "TRASH":
            return "废纸篓"
        case "JUNK", "SPAM":
            return "垃圾邮件"
        case "ARCHIVE":
            return "归档"
        case "ALL MAIL":
            return "所有邮件"
        default:
            return name
        }
    }
}
