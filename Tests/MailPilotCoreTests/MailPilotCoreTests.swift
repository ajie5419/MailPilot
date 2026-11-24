import Foundation
import SQLite3
import XCTest
@testable import MailPilotCore

final class MailPilotCoreTests: XCTestCase {
    func testEmlxPlainTextAndVerificationCodeExtraction() {
        let rfc822 = """
        From: GitHub <noreply@github.com>
        Subject: Verification
        Content-Type: text/plain; charset=utf-8

        Your verification code is 482910. It expires in 10 minutes.
        """
        let emlxString = "\(rfc822.utf8.count)\n\(rfc822)\n<?xml version=\"1.0\"?><plist></plist>"
        let parsed = EmlxParser.parseEmlxData(Data(emlxString.utf8))

        XCTAssertTrue(parsed.plainText.contains("482910"))
        XCTAssertEqual(parsed.verificationCode, "482910")
    }

    func testChineseVerificationCodeAndMultipartBase64() {
        let chineseBody = "您好，本次登录验证码：938271，请勿泄露。"
        let b64 = Data(chineseBody.utf8).base64EncodedString()
        let raw = """
        Content-Type: multipart/alternative; boundary="bnd123"

        --bnd123
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        \(b64)
        --bnd123
        Content-Type: text/html; charset=utf-8

        <p>HTML fallback</p>
        --bnd123--
        """
        let parsed = EmlxParser.parseEmlxData(Data(raw.utf8))
        XCTAssertTrue(parsed.plainText.contains("938271"))
        XCTAssertEqual(parsed.verificationCode, "938271")
    }

    func testPrivacyMasker() {
        let input = "联系 13812345678 或 alice@example.com，密钥 sk-1234567890abcdef1234"
        let masked = PrivacyMasker.mask(input)
        XCTAssertFalse(masked.contains("13812345678"))
        XCTAssertFalse(masked.contains("alice@example.com"))
        XCTAssertFalse(masked.contains("sk-1234567890abcdef1234"))
        XCTAssertTrue(masked.contains("[PHONE]"))
        XCTAssertTrue(masked.contains("[EMAIL]"))
        XCTAssertTrue(masked.contains("[API_KEY]"))
    }

    func testEnvelopeIndexReadOnlyQuery() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailPilotTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL = tmpDir.appendingPathComponent("Envelope Index")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let schemaSQL = """
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE messages (
            ROWID INTEGER PRIMARY KEY,
            message_id TEXT,
            subject INTEGER,
            sender INTEGER,
            date_received REAL,
            read INTEGER,
            flagged INTEGER,
            deleted INTEGER,
            mailbox INTEGER
        );
        INSERT INTO mailboxes VALUES (1, 'imap://acc/INBOX');
        INSERT INTO subjects VALUES (10, '季度评审会议通知');
        INSERT INTO subjects VALUES (11, '已读测试邮件');
        INSERT INTO addresses VALUES (20, 'boss@company.com', '张总');
        INSERT INTO messages VALUES (100, 'm-1', 10, 20, 1732300000, 0, 1, 0, 1);
        INSERT INTO messages VALUES (101, 'm-2', 11, 20, 1732200000, 1, 0, 0, 1);
        """
        XCTAssertEqual(sqlite3_exec(db, schemaSQL, nil, nil, nil), SQLITE_OK)

        let reader = EnvelopeIndexReader(mailVersionURL: tmpDir, databaseURL: dbURL)
        let mailboxes = try reader.fetchMailboxes()
        XCTAssertEqual(mailboxes.count, 1)
        XCTAssertEqual(mailboxes[0].displayName, "收件箱")
        XCTAssertEqual(mailboxes[0].unreadCount, 1)

        let unread = try reader.fetchMessages(onlyUnread: true)
        XCTAssertEqual(unread.count, 1)
        XCTAssertEqual(unread[0].id, 100)
        XCTAssertEqual(unread[0].subject, "季度评审会议通知")
        XCTAssertEqual(unread[0].displaySender, "张总")
        XCTAssertTrue(unread[0].isFlagged)

        let searched = try reader.fetchMessages(searchQuery: "评审")
        XCTAssertEqual(searched.count, 1)
        XCTAssertEqual(searched[0].id, 100)
    }

    func testBodySearchIndexRollbackOnWriteError() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailPilotRollback-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let index = BodySearchIndex(databaseURL: dbURL)
        try await index.upsertBatch([(rowID: 1, subject: "Keep", sender: "a@b.com", body: "initial_token")])

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TRIGGER fail_row_3 BEFORE INSERT ON indexed_rows WHEN new.row_id = 3 BEGIN SELECT RAISE(ABORT, 'fault'); END;",
                nil, nil, nil
            ),
            SQLITE_OK
        )
        sqlite3_close(db)

        do {
            try await index.upsertBatch([
                (rowID: 2, subject: "Partial", sender: "a@b.com", body: "should_rollback"),
                (rowID: 3, subject: "Fail", sender: "a@b.com", body: "boom")
            ])
            XCTFail("Expected BodySearchIndexError.sqliteError")
        } catch let error as BodySearchIndexError {
            if case .sqliteError = error {
                // expected
            } else {
                XCTFail("Unexpected error variant: \(error)")
            }
        }

        let remaining = await index.allIndexedRowIDs()
        XCTAssertEqual(remaining, [1])
    }

    func testAIServicePrepareHistoryBudget() {
        let history: [AIChatMessage] = [
            AIChatMessage(role: .user, content: "old"),
            AIChatMessage(role: .assistant, content: "请求失败：timeout", isError: true),
            AIChatMessage(role: .assistant, content: "   "),
            AIChatMessage(role: .assistant, content: "mid"),
            AIChatMessage(role: .user, content: "latest")
        ]
        let prepared = AIService.prepareHistory(
            history,
            budget: AIService.ContextBudget(maxHistoryMessages: 2, maxHistoryChars: 100, maxMessageChars: 50)
        )
        XCTAssertEqual(prepared.messages.map(\.content), ["mid", "latest"])
        XCTAssertEqual(prepared.droppedCount, 1)
    }
}
