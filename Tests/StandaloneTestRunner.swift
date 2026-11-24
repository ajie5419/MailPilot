import Foundation
import SQLite3

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    guard actual == expected else {
        fputs("FAIL [\(label)]: expected '\(expected)', got '\(actual)'\n", stderr)
        exit(1)
    }
}

private func assertTrue(_ condition: Bool, _ label: String) {
    guard condition else {
        fputs("FAIL [\(label)]\n", stderr)
        exit(1)
    }
}

@main
struct StandaloneTestRunner {
    static func main() async throws {
        // 1. Plain text .emlx + English OTP extraction
        let rfc822 = """
        From: GitHub <noreply@github.com>
        Subject: Verification
        Content-Type: text/plain; charset=utf-8

        Your verification code is 482910. It expires in 10 minutes.
        """
        let emlxString = "\(rfc822.utf8.count)\n\(rfc822)\n<?xml version=\"1.0\"?><plist></plist>"
        let parsed1 = EmlxParser.parseEmlxData(Data(emlxString.utf8))
        assertTrue(parsed1.plainText.contains("482910"), "plainText contains code")
        assertEqual(parsed1.verificationCode, "482910", "English OTP extraction")

        // 2. Multipart + Base64 + Chinese OTP extraction
        let chineseBody = "您好，本次登录验证码：938271，请勿泄露。"
        let b64 = Data(chineseBody.utf8).base64EncodedString()
        let rawMultipart = """
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
        let parsed2 = EmlxParser.parseEmlxData(Data(rawMultipart.utf8))
        assertTrue(parsed2.plainText.contains("938271"), "base64 Chinese body decoded")
        assertEqual(parsed2.verificationCode, "938271", "Chinese OTP extraction")

        // 3. Privacy masking
        let sensitive = "联系 13812345678 或 alice@example.com，密钥 sk-1234567890abcdef1234"
        let masked = PrivacyMasker.mask(sensitive)
        assertTrue(!masked.contains("13812345678"), "phone masked")
        assertTrue(!masked.contains("alice@example.com"), "email masked")
        assertTrue(!masked.contains("sk-1234567890abcdef1234"), "api key masked")
        assertTrue(masked.contains("[PHONE]") && masked.contains("[EMAIL]") && masked.contains("[API_KEY]"), "placeholders present")

        // 4. Read-only Envelope Index SQLite query
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailPilotTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL = tmpDir.appendingPathComponent("Envelope Index")
        var db: OpaquePointer?
        assertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK, "create temp Envelope Index")
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
        assertEqual(sqlite3_exec(db, schemaSQL, nil, nil, nil), SQLITE_OK, "seed temp Envelope Index")

        let reader = EnvelopeIndexReader(mailVersionURL: tmpDir, databaseURL: dbURL)
        let mailboxes = try reader.fetchMailboxes()
        assertEqual(mailboxes.count, 1, "mailbox count")
        assertEqual(mailboxes[0].displayName, "收件箱", "mailbox humanized name")
        assertEqual(mailboxes[0].unreadCount, 1, "mailbox unread count")

        let unread = try reader.fetchMessages(onlyUnread: true)
        assertEqual(unread.count, 1, "unread filter count")
        assertEqual(unread[0].id, 100, "unread message id")
        assertEqual(unread[0].displaySender, "张总", "sender display name")
        assertTrue(unread[0].isFlagged, "flagged status")

        let searched = try reader.fetchMessages(searchQuery: "评审")
        assertEqual(searched.count, 1, "search filter count")
        assertEqual(searched[0].id, 100, "search message id")

        // 5. OAuth 2.0 PKCE generation, auth URL building, and callback parsing
        let pkce = OAuthSubscriptionManager.generatePKCE()
        assertTrue(pkce.verifier.count >= 43, "PKCE verifier length >= 43")
        assertTrue(!pkce.challenge.contains("+") && !pkce.challenge.contains("/") && !pkce.challenge.contains("="), "PKCE S256 Base64URL")

        let orURL = try OAuthSubscriptionManager.buildAuthorizationURL(
            config: OAuthProviderConfig(kind: .openRouter),
            callbackURL: "http://127.0.0.1:43210/callback",
            codeChallenge: pkce.challenge,
            state: "st123"
        )
        assertTrue(orURL.absoluteString.contains("code_challenge_method=S256"), "OpenRouter auth URL includes S256")
        assertTrue(orURL.absoluteString.contains("callback_url="), "OpenRouter auth URL includes callback_url")

        let parsedQuery = OAuthSubscriptionManager.parseCallbackQuery(from: "GET /callback?code=auth_999&state=st123 HTTP/1.1")
        assertEqual(parsedQuery["code"], "auth_999", "callback code parsed")
        assertEqual(parsedQuery["state"], "st123", "callback state parsed")

        // 6. Subscription CLI search paths and detection
        let searchPaths = SubscriptionCLIBridge.searchPaths()
        assertTrue(searchPaths.contains("/opt/homebrew/bin"), "includes homebrew bin")
        assertTrue(searchPaths.contains { $0.hasSuffix("/.local/bin") }, "includes ~/.local/bin")
        let statuses = SubscriptionCLIBridge.detectAll()
        assertEqual(statuses.count, SubscriptionCLIProvider.allCases.count, "detects all subscription CLI providers")

        // 7. HTML numeric entities & invisible space cleanup
        let encodedHTML = """
        Content-Type: text/html; charset=utf-8

        <div>&#8202;&#24744;&#20851;&#27880;&#30340;&#x4F5C;&#x8005; Francis_BTC &#8202;</div>
        """
        let parsedHTML = EmlxParser.parseEmlxData(Data(encodedHTML.utf8))
        assertTrue(parsedHTML.plainText.contains("您关注的作者 Francis_BTC"), "HTML numeric/hex entities decoded")
        assertTrue(!parsedHTML.plainText.contains("&#"), "no raw HTML entities left")

        // 8. Dynamic Codex models_cache.json parsing
        let mockCache = """
        {
          "models": [
            {"slug": "gpt-6.2-sol", "display_name": "GPT-6.2-Sol", "visibility": "list", "priority": 1},
            {"slug": "internal-hidden", "display_name": "Hidden", "visibility": "hide", "priority": 2},
            {"slug": "gpt-6.2-astra", "display_name": "GPT-6.2-Astra", "visibility": "list", "priority": 3}
          ]
        }
        """
        let parsedModels = ModelCatalogService.parseCodexModelsCache(Data(mockCache.utf8))
        assertEqual(parsedModels.count, 2, "only visible models listed")
        assertEqual(parsedModels[0].id, "gpt-6.2-sol", "priority 1 first")
        assertEqual(parsedModels[1].id, "gpt-6.2-astra", "priority 3 second")

        // 9. Sender brand domain normalization & personal webmail filtering
        assertEqual(SenderDomainHelper.extractBrandDomain(from: "service@intl.paypal.com"), "paypal.com", "paypal subdomain normalized")
        assertEqual(SenderDomainHelper.extractBrandDomain(from: "noreply@mail.tradingview.com"), "tradingview.com", "tradingview normalized")
        assertEqual(SenderDomainHelper.extractBrandDomain(from: "notice@mail.aliyun.com"), "aliyun.com", "aliyun normalized")
        assertEqual(SenderDomainHelper.extractBrandDomain(from: "hi@corp.co.uk"), "corp.co.uk", "multi-part TLD preserved")
        assertEqual(SenderDomainHelper.extractBrandDomain(from: "user@163.com"), nil, "personal 163.com excluded")
        assertEqual(SenderDomainHelper.extractBrandDomain(from: "user@gmail.com"), nil, "personal gmail.com excluded")

        // 10. Smart mail tag classification
        let appleOrderTags = MailTagClassifier.classify(
            subject: "We're processing your order W1639842610 - Order Number W1639842610",
            senderName: "Apple Store",
            senderAddress: "orders@apple.com"
        )
        assertTrue(appleOrderTags.contains(.billing) && appleOrderTags.contains(.orderLogistics), "Apple order gets billing + logistics tags")

        let shipTags = MailTagClassifier.classify(
            subject: "订单已发货通知",
            senderName: "16688",
            senderAddress: "notice@16688.com"
        )
        assertTrue(shipTags.contains(.orderLogistics) && shipTags.contains(.notification), "16688 shipment gets logistics + notification tags")

        let otpTags = MailTagClassifier.classify(
            subject: "您的 PayPal 验证码",
            senderName: "PayPal",
            senderAddress: "service@intl.paypal.com"
        )
        assertTrue(otpTags.contains(.verification), "PayPal OTP gets verification tag")

        let loginAlertTags = MailTagClassifier.classify(
            subject: "Failed Client Login",
            senderName: "LIGHTLAYER",
            senderAddress: "support@lightlayer.net"
        )
        assertTrue(loginAlertTags.contains(.notification), "Failed login gets notification tag")

        let welcomeTags = MailTagClassifier.classify(
            subject: "Client:Welcome to Portal",
            senderName: "LIGHTLAYER",
            senderAddress: "support@lightlayer.net"
        )
        assertTrue(welcomeTags.contains(.notification), "Welcome portal gets notification tag")

        var customSettings = MailTagSettings()
        customSettings.customKeywords[MailSmartTag.billing.rawValue] = "lightlayer"
        let customTagged = MailTagClassifier.classify(
            subject: "Monthly Summary",
            senderName: "LIGHTLAYER",
            senderAddress: "support@lightlayer.net",
            settings: customSettings
        )
        assertTrue(customTagged.contains(.billing), "Custom keyword triggers billing tag")

        // 11. MIME attachment parsing (RFC 2047 Chinese filename + Base64 payload)
        let chineseFileName = "季度报告.pdf"
        let encodedName = "=?UTF-8?B?\(Data(chineseFileName.utf8).base64EncodedString())?="
        let pdfBytes = Data("%PDF-1.4 mock content".utf8)
        let multipartWithAtt = """
        Content-Type: multipart/mixed; boundary="mixbnd"

        --mixbnd
        Content-Type: text/plain; charset=utf-8

        请查收附件。
        --mixbnd
        Content-Type: application/pdf; name="\(encodedName)"
        Content-Disposition: attachment; filename="\(encodedName)"
        Content-Transfer-Encoding: base64

        \(pdfBytes.base64EncodedString())
        --mixbnd--
        """
        let parsedWithAtt = EmlxParser.parseEmlxData(Data(multipartWithAtt.utf8))
        assertEqual(parsedWithAtt.attachments.count, 1, "extracts 1 MIME attachment")
        assertEqual(parsedWithAtt.attachments[0].filename, "季度报告.pdf", "decodes RFC 2047 Chinese filename")
        assertEqual(parsedWithAtt.attachments[0].inlineData, pdfBytes, "decodes attachment bytes accurately")

        // 12. Multi-account mailbox URL extraction
        assertEqual(EnvelopeIndexReader.extractAccountID(from: "imap://9643B503-9CD0-4A11/INBOX"), "9643B503-9CD0-4A11", "extracts IMAP account UUID")
        assertEqual(EnvelopeIndexReader.extractAccountID(from: "ews://ABCD-1234/Sent"), "ABCD-1234", "extracts EWS account UUID")
        assertEqual(EnvelopeIndexReader.extractAccountID(from: "local:///Archive"), "local", "maps local mailbox to local")

        // 13. Inline cid: image replacement in HTML emails
        let pngPayload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let cidEmail = """
        Content-Type: multipart/related; boundary="relbnd"

        --relbnd
        Content-Type: text/html; charset=utf-8

        <p>请看截图：<img src="cid:img001@corp.local" /></p>
        --relbnd
        Content-Type: image/png; name="shot.png"
        Content-Transfer-Encoding: base64
        Content-ID: <img001@corp.local>
        Content-Disposition: inline

        \(pngPayload.base64EncodedString())
        --relbnd--
        """
        let parsedCID = EmlxParser.parseEmlxData(Data(cidEmail.utf8))
        assertTrue(parsedCID.rawHTML?.contains("data:image/png;base64,") == true, "cid image replaced with data URI")
        assertTrue(parsedCID.rawHTML?.contains("cid:") == false, "no unresolved cid reference left")
        assertEqual(parsedCID.attachments.count, 0, "inline cid image not duplicated as attachment")

        // 14. Independent FTS5 local body search index
        let ftsTmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-fts-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: ftsTmpURL) }
        let ftsIndex = BodySearchIndex(databaseURL: ftsTmpURL)
        await ftsIndex.upsertBatch([
            (rowID: 501, subject: "会议纪要", sender: "alice@corp.com", body: "合同编号 HT-2026-8899 已审批通过，请财务安排付款。"),
            (rowID: 502, subject: "Welcome", sender: "team@app.io", body: "Thanks for signing up for our annual plan.")
        ])
        let cnHits = await ftsIndex.searchRowIDs(query: "HT-2026-8899")
        assertEqual(cnHits, [501], "FTS5 finds contract number in body")
        let zhSubHits = await ftsIndex.searchRowIDs(query: "审批通过")
        assertEqual(zhSubHits, [501], "LIKE fallback finds Chinese substring in body")

        // 15. Apple Mail O(1) bucket path derivation for fast .emlx lookup
        let bucket123456 = EmlxParser.bucketRelativePaths(for: 123456)
        assertEqual(bucket123456[0], "3/2/1/Messages/123456.emlx", "6-digit ROWID bucket path")
        let bucket42 = EmlxParser.bucketRelativePaths(for: 42)
        assertEqual(bucket42[0], "Messages/42.emlx", "small ROWID bucket path")

        // 16. MailDirectoryWatcher detects open-fd WAL writes via kqueue vnode
        let watchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: watchDir) }
        let walURL = watchDir.appendingPathComponent("Envelope Index-wal")
        FileManager.default.createFile(atPath: walURL.path, contents: Data("init".utf8))
        let walHandle = try FileHandle(forWritingTo: walURL)
        defer { try? walHandle.close() }

        let semaphore = DispatchSemaphore(value: 0)
        let watcher = MailDirectoryWatcher(directoryURL: watchDir) {
            semaphore.signal()
        }
        defer { watcher.stop() }
        // Append to WAL while keeping file descriptor open (exactly like SQLite WAL mode)
        try walHandle.seekToEnd()
        try walHandle.write(contentsOf: Data("new-mail-wal-frame".utf8))
        let waitResult = semaphore.wait(timeout: .now() + 2.0)
        assertTrue(waitResult == .success, "MailDirectoryWatcher triggers on open-fd WAL write")

        // 17. Gmail multi-label `labels` table support (message in All Mail with INBOX label)
        let dbTmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-env-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbTmpURL) }
        var testDB: OpaquePointer?
        assertEqual(sqlite3_open(dbTmpURL.path, &testDB), SQLITE_OK, "open temp envelope db")
        let setupSQL = """
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, message_id INTEGER, subject INTEGER, sender INTEGER, date_received REAL, read INTEGER, flagged INTEGER, deleted INTEGER, mailbox INTEGER);
        CREATE TABLE labels (message_id INTEGER, mailbox_id INTEGER);
        INSERT INTO mailboxes VALUES (1, 'imap://GMAIL-ACCT/INBOX');
        INSERT INTO mailboxes VALUES (2, 'imap://GMAIL-ACCT/%5BGmail%5D/All%20Mail');
        INSERT INTO subjects VALUES (10, 'New Gmail Arrival');
        INSERT INTO addresses VALUES (20, 'sender@gmail.com', 'Sender');
        INSERT INTO messages VALUES (100, 999, 10, 20, 1700000000, 0, 0, 0, 2);
        INSERT INTO labels VALUES (100, 1);
        """
        assertEqual(sqlite3_exec(testDB, setupSQL, nil, nil, nil), SQLITE_OK, "seed temp envelope db")
        sqlite3_close(testDB)

        let labelReader = EnvelopeIndexReader(mailVersionURL: dbTmpURL.deletingLastPathComponent(), databaseURL: dbTmpURL)
        let fetchedMbs = try labelReader.fetchMailboxes()
        let inboxMb = fetchedMbs.first { $0.id == 1 }
        let allMailMb = fetchedMbs.first { $0.id == 2 }
        assertEqual(inboxMb?.displayName, "收件箱", "INBOX humanized")
        assertEqual(inboxMb?.unreadCount, 1, "Gmail INBOX unread count includes label-linked messages")
        assertEqual(allMailMb?.displayName, "所有邮件", "All Mail humanized")
        let inboxMsgs = try labelReader.fetchMessages(onlyInbox: true, limit: 10)
        assertEqual(inboxMsgs.map(\.id), [100], "onlyInbox includes Gmail message linked via labels")
        let byBoxMsgs = try labelReader.fetchMessages(mailboxID: 1, limit: 10)
        assertEqual(byBoxMsgs.map(\.id), [100], "mailboxID query includes Gmail message linked via labels")

        print("ALL 17 CORE TEST SUITES PASSED")
        try await ChatGPTTests.run()
    }
}
