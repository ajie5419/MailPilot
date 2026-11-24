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
        limit: Int = 150
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
        ORDER BY \(dateCol) DESC
        LIMIT ?;
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

    /// Fetches message summaries for an explicit set of `ROWID`s (used to hydrate FTS5 body search hits).
    public func fetchMessages(byRowIDs rowIDs: [Int64]) throws -> [MailMessageSummary] {
        guard !rowIDs.isEmpty else { return [] }
        let db = try openReadOnly()
        defer { sqlite3_close(db) }

        let messageColumns = inspectColumns(db: db, table: "messages")
        let hasDeleted = messageColumns.contains("deleted")
        let hasMessageIDHeader = messageColumns.contains("message_id")
        let hasDateReceived = messageColumns.contains("date_received")
        let dateCol = hasDateReceived ? "m.date_received" : "m.date_sent"
        let msgIDExpr = hasMessageIDHeader ? "CAST(m.message_id AS TEXT)" : "NULL"

        let capped = Array(rowIDs.prefix(200))
        let placeholders = Array(repeating: "?", count: capped.count).joined(separator: ",")
        let deletedCond = hasDeleted ? "AND COALESCE(m.deleted, 0) = 0" : ""

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
        WHERE m.ROWID IN (\(placeholders)) \(deletedCond)
        ORDER BY \(dateCol) DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailAccessError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (idx, id) in capped.enumerated() {
            sqlite3_bind_int64(stmt, Int32(idx + 1), id)
        }

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
