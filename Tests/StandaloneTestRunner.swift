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
        try await ftsIndex.upsertBatch([
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

        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let watcher = MailDirectoryWatcher(directoryURL: watchDir) {
            continuation.yield(())
        }
        defer { watcher.stop() }
        // Append to WAL while keeping file descriptor open (exactly like SQLite WAL mode)
        try walHandle.seekToEnd()
        try walHandle.write(contentsOf: Data("new-mail-wal-frame".utf8))
        let triggered = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        assertTrue(triggered, "MailDirectoryWatcher triggers on open-fd WAL write")

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

        // 18. AIConfig never persists plaintext apiKey in JSON / UserDefaults (F05)
        let secretCfg = AIConfig(authMode: .apiKey, baseURL: "https://api.deepseek.com/v1", apiKey: "FAKE-AUDIT-KEY")
        let encodedCfgData = try JSONEncoder().encode(secretCfg)
        let encodedCfgText = String(data: encodedCfgData, encoding: .utf8) ?? ""
        assertTrue(!encodedCfgText.contains("FAKE-AUDIT-KEY"), "encoded AIConfig omits plaintext apiKey")
        let legacyJSON = Data(#"{"authMode":"api_key","baseURL":"https://api.openai.com/v1","apiKey":"LEGACY-KEY","model":"gpt-4o-mini","maskSensitiveData":true}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(AIConfig.self, from: legacyJSON)
        assertEqual(decodedLegacy.apiKey, "LEGACY-KEY", "legacy plaintext apiKey still decodes for one-time migration")
        assertTrue(
            AIConfig.apiKeyKeychainAccount(for: "https://api.deepseek.com/v1") != AIConfig.apiKeyKeychainAccount(for: "https://api.openai.com/v1"),
            "API key keychain account isolated per provider host"
        )

        // 19. FTS5 update leaves zero stale old tokens & delete works (F09)
        let ftsUpdateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-fts-upd-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: ftsUpdateURL) }
        let ftsUpd = BodySearchIndex(databaseURL: ftsUpdateURL)
        try await ftsUpd.upsertBatch([(rowID: 1, subject: "S", sender: "a@b.com", body: "olduniquetoken 旧合同内容")])
        try await ftsUpd.upsertBatch([(rowID: 1, subject: "S", sender: "a@b.com", body: "newuniquetoken 新审批内容")])
        assertEqual(await ftsUpd.searchRowIDs(query: "olduniquetoken"), [], "FTS5 removes old token after update")
        assertEqual(await ftsUpd.searchRowIDs(query: "newuniquetoken"), [1], "FTS5 indexes new token after update")
        assertEqual(await ftsUpd.searchRowIDs(query: "新审批内容"), [1], "FTS5 trigram matches Chinese substring")
        try await ftsUpd.deleteRowIDs([1])
        assertEqual(await ftsUpd.searchRowIDs(query: "newuniquetoken"), [], "FTS5 removes token after delete")

        // 20. Gmail multi-label body search hydration via SQL (F08)
        let gmailHydrated = try labelReader.fetchMessages(byRowIDs: [100], onlyInbox: true)
        assertEqual(gmailHydrated.map(\.id), [100], "fetchMessages(byRowIDs:onlyInbox:) keeps Gmail label-linked inbox mail")
        assertEqual(try labelReader.fetchMaxInboxRowID(), 100, "fetchMaxInboxRowID includes label-linked inbox mail")
        assertEqual(try labelReader.fetchUnreadInboxMessages(afterRowID: 50).map(\.id), [100], "fetchUnreadInboxMessages(afterRowID:) finds new Gmail mail")

        // 21. Raw 8bit GB18030 email decodes cleanly without mojibake (F15)
        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbHeader = Data("Content-Type: text/plain; charset=gb18030\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8)
        let gbBody = "你好，测试编码".data(using: gbEncoding)!
        let parsedGB = EmlxParser.parseEmlxData(gbHeader + gbBody)
        assertEqual(parsedGB.plainText, "你好，测试编码", "8bit GB18030 decoded accurately")

        // 22. OAuth form encoding strictly escapes reserved separators (F12)
        assertEqual(OAuthSubscriptionManager.urlEncodeForm("a+b&c=d"), "a%2Bb%26c%3Dd", "OAuth form encoding escapes +, &, =")

        // 23. Attachment regression: raw UTF-8 Chinese filename + byte-exact 8bit binary attachment
        // including internal CRLF (`\r\n`), trailing spaces, and trailing tabs (`\t`)
        let rawBinBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0xFF, 0xFE, 0xC4, 0xE3, 0x20, 0x20, 0x09])
        var attEmailData = Data()
        attEmailData.append(Data("Content-Type: multipart/mixed; boundary=\"attbnd\"\r\n\r\n".utf8))
        attEmailData.append(Data("--attbnd\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n正文内容\r\n".utf8))
        attEmailData.append(Data("--attbnd\r\nContent-Type: application/octet-stream; name=\"合同报告.pdf\"\r\nContent-Disposition: attachment; filename=\"合同报告.pdf\"\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8))
        attEmailData.append(rawBinBytes)
        attEmailData.append(Data("\r\n--attbnd--\r\n".utf8))
        let parsedAttReg = EmlxParser.parseEmlxData(attEmailData)
        assertEqual(parsedAttReg.attachments.count, 1, "8bit attachment extracted")
        assertEqual(parsedAttReg.attachments.first?.filename, "合同报告.pdf", "raw UTF-8 Chinese attachment filename preserved")
        assertEqual(parsedAttReg.attachments.first?.inlineData, rawBinBytes, "8bit attachment preserves CRLF, trailing spaces, and tabs byte-for-byte")

        // 24. Global unbounded FTS5 search + mailbox filter: 101 inbox hits behind 2,200 archive hits must all be returned
        let bigFTSURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-fts-400-\(UUID().uuidString).sqlite")
        let bigEnvURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-env-400-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: bigFTSURL)
            try? FileManager.default.removeItem(at: bigEnvURL)
        }
        let bigFTS = BodySearchIndex(databaseURL: bigFTSURL)
        let padding = String(repeating: "a", count: 32_000)
        var bulkEntries: [(rowID: Int64, subject: String, sender: String, body: String, fileMTime: Double)] = []
        // ROWIDs 1..101 are INBOX; ROWIDs 102..2301 are Archive (higher ROWIDs would crowd out a naive global LIMIT 2000!)
        for i in Int64(1)...Int64(2301) {
            let body = (i == 101) ? "sharedneedle \(padding) TAILMARKER_99999" : "sharedneedle item \(i)"
            bulkEntries.append((rowID: i, subject: "S\(i)", sender: "u@example.com", body: body, fileMTime: 100.0))
        }
        try await bigFTS.upsertBatchWithMTime(bulkEntries)
        let allNeedleHits = await bigFTS.searchRowIDs(query: "sharedneedle", limit: nil)
        assertEqual(allNeedleHits.count, 2301, "unbounded FTS5 search returns all 2,301 hits")

        var bigDB: OpaquePointer?
        assertEqual(sqlite3_open(bigEnvURL.path, &bigDB), SQLITE_OK, "open big temp env db")
        var bigSeedSQL = """
        BEGIN;
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, message_id INTEGER, subject INTEGER, sender INTEGER, date_received REAL, read INTEGER, flagged INTEGER, deleted INTEGER, mailbox INTEGER);
        INSERT INTO mailboxes VALUES (1, 'imap://ACCT/INBOX');
        INSERT INTO mailboxes VALUES (2, 'imap://ACCT/Archive');
        INSERT INTO subjects VALUES (1, 'Test');
        INSERT INTO addresses VALUES (1, 'u@example.com', 'User');
        """
        for i in 1...2301 {
            let mb = i <= 101 ? 1 : 2
            bigSeedSQL += "INSERT INTO messages VALUES (\(i), \(i), 1, 1, \(1700000000 + i), 0, 0, 0, \(mb));\n"
        }
        bigSeedSQL += "COMMIT;"
        assertEqual(sqlite3_exec(bigDB, bigSeedSQL, nil, nil, nil), SQLITE_OK, "seed 2,301 messages")
        sqlite3_close(bigDB)

        let bigReader = EnvelopeIndexReader(mailVersionURL: bigEnvURL.deletingLastPathComponent(), databaseURL: bigEnvURL)
        let inboxOnlyHits = try bigReader.fetchMessages(byRowIDs: allNeedleHits, onlyInbox: true)
        assertEqual(inboxOnlyHits.count, 101, "all 101 inbox hits returned even behind 2,200 archive hits")
        let tailHits = await bigFTS.searchRowIDs(query: "TAILMARKER_99999")
        assertEqual(tailHits, [101], "long email tail beyond 32,000 chars is searchable")
        let versions = await bigFTS.indexedVersions(in: [101])
        assertEqual(versions[101], 100.0, "indexedVersions returns stored file_mtime")

        // 25. Custom OAuth Keychain accounts are isolated across BOTH different hosts AND different tenants on the SAME host
        let oauthTenantA = OAuthProviderConfig(
            kind: .customPKCE,
            authorizationURL: "https://login.microsoftonline.com/tenant-a/oauth2/v2.0/authorize",
            tokenURL: "https://login.microsoftonline.com/tenant-a/oauth2/v2.0/token",
            clientID: "shared-app-client",
            apiBaseURL: "https://api.corp.io/v1"
        )
        let oauthTenantB = OAuthProviderConfig(
            kind: .customPKCE,
            authorizationURL: "https://login.microsoftonline.com/tenant-b/oauth2/v2.0/authorize",
            tokenURL: "https://login.microsoftonline.com/tenant-b/oauth2/v2.0/token",
            clientID: "shared-app-client",
            apiBaseURL: "https://api.corp.io/v1"
        )
        assertTrue(
            OAuthSubscriptionManager.keychainAccount(for: oauthTenantA) != OAuthSubscriptionManager.keychainAccount(for: oauthTenantB),
            "custom OAuth keychain accounts isolated across different tenants on the same host"
        )

        // 26. Quoted-printable CRLF soft line break regression (`hello=\r\nworld` -> `helloworld`)
        let qpCRLF = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nhello=\r\nworld\r\nhttps://example.com/verify?token=3Dabc=\r\ndef&ok=3D1\r\n=E4=BD=\r\n=A0=E5=A5=BD\r\npadded= \t\r\njoined"
        let parsedQPCRLF = EmlxParser.parseEmlxData(Data(qpCRLF.utf8))
        assertTrue(parsedQPCRLF.plainText.contains("helloworld"), "QP CRLF soft line break unfolds hello=\\r\\nworld to helloworld")
        assertTrue(!parsedQPCRLF.plainText.contains("hello="), "QP CRLF soft line break leaves no trailing '='")
        assertTrue(parsedQPCRLF.plainText.contains("https://example.com/verify?token=abcdef&ok=1"), "QP CRLF soft line break preserves split URLs")
        assertTrue(parsedQPCRLF.plainText.contains("你好"), "QP CRLF soft line break across multi-byte UTF-8 sequence decodes cleanly")
        assertTrue(parsedQPCRLF.plainText.contains("paddedjoined"), "QP transport-padded soft line break unfolds cleanly")

        let qpHTML = "Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n<a href=3D\"https://example.com/a=\r\nb\">hello=\r\nworld</a>"
        let parsedQPHTML = EmlxParser.parseEmlxData(Data(qpHTML.utf8))
        assertEqual(parsedQPHTML.plainText, "helloworld", "QP CRLF HTML plainText unfolds cleanly")
        assertTrue(parsedQPHTML.rawHTML?.contains("href=\"https://example.com/ab\"") == true, "QP CRLF HTML link unfolds cleanly")

        // 27. Search pagination without body index: 2,100 subject hits must paginate cleanly past first 200
        let pagedEnvURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-env-search-page-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: pagedEnvURL) }
        var pagedDB: OpaquePointer?
        assertEqual(sqlite3_open(pagedEnvURL.path, &pagedDB), SQLITE_OK, "open paged search db")
        var pagedSeedSQL = """
        BEGIN;
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, message_id INTEGER, subject INTEGER, sender INTEGER, date_received REAL, read INTEGER, flagged INTEGER, deleted INTEGER, mailbox INTEGER);
        INSERT INTO mailboxes VALUES (1, 'imap://ACCT/INBOX');
        INSERT INTO subjects VALUES (1, 'Quarterly Report Batch');
        INSERT INTO subjects VALUES (2, 'Unrelated Notice');
        INSERT INTO addresses VALUES (1, 'u@example.com', 'User');
        """
        for i in 1...2100 {
            pagedSeedSQL += "INSERT INTO messages VALUES (\(i), \(i), 1, 1, \(1700000000 + i), 0, 0, 0, 1);\n"
        }
        // Add 1 body-only candidate with newer timestamp to test chronological merged pagination as well
        pagedSeedSQL += "INSERT INTO messages VALUES (9001, 9001, 2, 1, \(1700000000 + 3000), 0, 0, 0, 1);\n"
        pagedSeedSQL += "COMMIT;"
        assertEqual(sqlite3_exec(pagedDB, pagedSeedSQL, nil, nil, nil), SQLITE_OK, "seed 2,100 subject hits")
        sqlite3_close(pagedDB)

        let pagedReader = EnvelopeIndexReader(mailVersionURL: pagedEnvURL.deletingLastPathComponent(), databaseURL: pagedEnvURL)
        // Body index is empty (`bodyHitIDs: []`)
        let searchPage1 = try pagedReader.fetchMessagePage(onlyInbox: true, searchQuery: "Quarterly Report", bodyHitIDs: [], limit: 200)
        assertEqual(searchPage1.messages.count, 200, "search page 1 returns first 200 of 2,100 title hits")
        assertTrue(searchPage1.hasMore, "search page 1 reports hasMore = true when 2,100 title hits exist without body index")
        let searchPage2 = try pagedReader.fetchMessagePage(onlyInbox: true, searchQuery: "Quarterly Report", bodyHitIDs: [], limit: 400)
        assertEqual(searchPage2.messages.count, 400, "search page 2 loads next page to 400 hits")
        assertTrue(searchPage2.hasMore, "search page 2 still has more pages")
        let searchPageFinal = try pagedReader.fetchMessagePage(onlyInbox: true, searchQuery: "Quarterly Report", bodyHitIDs: [], limit: 2200)
        assertEqual(searchPageFinal.messages.count, 2100, "final search page loads all 2,100 title hits")
        assertTrue(!searchPageFinal.hasMore, "final search page reports hasMore = false")
        // Merged subject + body hit pagination preserves exact newest-first ordering and pagination
        let mergedPage1 = try pagedReader.fetchMessagePage(onlyInbox: true, searchQuery: "Quarterly Report", bodyHitIDs: [9001], limit: 200)
        assertEqual(mergedPage1.messages.count, 200, "merged search page 1 stays capped at 200")
        assertEqual(mergedPage1.messages.first?.id, 9001, "newest body-only hit ranks first in merged search page 1")
        assertTrue(mergedPage1.hasMore, "merged search page 1 reports hasMore = true")

        // 28. OAuth Keychain isolation preserves case-sensitive paths (`/Tenant/` vs `/tenant/`), query params, and scheme/host normalization
        let oauthUpperTenant = OAuthProviderConfig(
            kind: .customPKCE,
            authorizationURL: "https://idp.example.com/Tenant/oauth2/authorize",
            tokenURL: "https://idp.example.com/Tenant/oauth2/token",
            clientID: "shared-client",
            apiBaseURL: "https://api.example.com/Tenant/v1"
        )
        let oauthLowerTenant = OAuthProviderConfig(
            kind: .customPKCE,
            authorizationURL: "https://idp.example.com/tenant/oauth2/authorize",
            tokenURL: "https://idp.example.com/tenant/oauth2/token",
            clientID: "shared-client",
            apiBaseURL: "https://api.example.com/tenant/v1"
        )
        let oauthUpperHostSamePath = OAuthProviderConfig(
            kind: .customPKCE,
            authorizationURL: "HTTPS://IDP.EXAMPLE.COM:443/Tenant/oauth2/authorize",
            tokenURL: "https://IDP.example.com/Tenant/oauth2/token",
            clientID: "shared-client",
            apiBaseURL: "https://API.example.com/Tenant/v1"
        )
        let oauthTrailingSlash = OAuthProviderConfig(
            kind: .customPKCE,
            authorizationURL: "https://idp.example.com/Tenant/oauth2/authorize",
            tokenURL: "https://idp.example.com/Tenant/oauth2/token/",
            clientID: "shared-client",
            apiBaseURL: "https://api.example.com/Tenant/v1"
        )
        assertTrue(
            OAuthSubscriptionManager.keychainAccount(for: oauthUpperTenant) != OAuthSubscriptionManager.keychainAccount(for: oauthLowerTenant),
            "OAuth keychain account distinguishes /Tenant/ from /tenant/ paths"
        )
        assertTrue(
            OAuthSubscriptionManager.keychainAccount(for: oauthUpperTenant) != OAuthSubscriptionManager.keychainAccount(for: oauthTrailingSlash),
            "OAuth keychain account distinguishes /token from /token/ (trailing slash preserved per RFC 3986)"
        )
        assertEqual(
            OAuthSubscriptionManager.keychainAccount(for: oauthUpperTenant),
            OAuthSubscriptionManager.keychainAccount(for: oauthUpperHostSamePath),
            "OAuth keychain account still normalizes case-insensitive scheme/host and default port"
        )
        let oauthQueryA = OAuthProviderConfig(
            kind: .customPKCE,
            authorizationURL: "https://idp.example.com/oauth2/authorize?tenant=TenantA",
            tokenURL: "https://idp.example.com/oauth2/token?tenant=TenantA",
            clientID: "shared-client",
            apiBaseURL: "https://api.example.com/v1"
        )
        let oauthQueryB = OAuthProviderConfig(
            kind: .customPKCE,
            authorizationURL: "https://idp.example.com/oauth2/authorize?tenant=tenantA",
            tokenURL: "https://idp.example.com/oauth2/token?tenant=tenantA",
            clientID: "shared-client",
            apiBaseURL: "https://api.example.com/v1"
        )
        assertTrue(
            OAuthSubscriptionManager.keychainAccount(for: oauthQueryA) != OAuthSubscriptionManager.keychainAccount(for: oauthQueryB),
            "OAuth keychain account preserves query parameters and case"
        )
        assertEqual(
            OAuthSubscriptionManager.keychainAccount(for: OAuthProviderConfig(kind: .openRouter)),
            "oauth-token-openrouter",
            "Default OpenRouter config preserves legacy keychain account identifier"
        )

        // 29. Low-memory indexing path: checks mtime before reading and skips unchanged .emlx
        let idxMailRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-idx-\(UUID().uuidString)", isDirectory: true)
        let idxMsgDir = idxMailRoot.appendingPathComponent("INBOX.mbox/Data/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: idxMsgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: idxMailRoot) }
        let idxEmlxURL = idxMsgDir.appendingPathComponent("42.emlx")
        let idxRFC822 = "Content-Type: text/plain; charset=utf-8\r\n\r\nIndexed plain text body."
        try Data("\(idxRFC822.utf8.count)\n\(idxRFC822)\n".utf8).write(to: idxEmlxURL)

        let idxParser = EmlxParser(mailRootURL: idxMailRoot)
        let firstIdx = await idxParser.loadPlainTextForIndexing(for: 42, cachedMTime: nil)
        var capturedMTime: Double = 0
        if case let .parsed(text, _, mtime) = firstIdx {
            assertEqual(text, "Indexed plain text body.", "plainTextOnly extracts text accurately")
            capturedMTime = mtime
        } else {
            assertTrue(false, "first loadPlainTextForIndexing should parse")
        }
        let secondIdx = await idxParser.loadPlainTextForIndexing(for: 42, cachedMTime: capturedMTime)
        if case .unchanged = secondIdx {
            assertTrue(true, "unchanged mtime skips reading .emlx")
        } else {
            assertTrue(false, "unchanged mtime should return .unchanged")
        }

        // 30. Large attachment lazy parsing & on-demand decoding (zero upfront attachment decode on file-backed .emlx)
        let bigAttRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-bigatt-\(UUID().uuidString)", isDirectory: true)
        let bigAttDir = bigAttRoot.appendingPathComponent("INBOX.mbox/Data/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: bigAttDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bigAttRoot) }
        let bigPayload = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 & 0xFF) })
        let bigBase64 = bigPayload.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        var bigMime = Data()
        bigMime.append(Data("Content-Type: multipart/mixed; boundary=\"bigbnd\"\r\n\r\n".utf8))
        bigMime.append(Data("--bigbnd\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nShort 53-byte body for lazy large-attachment testing!\r\n".utf8))
        bigMime.append(Data("--bigbnd\r\nContent-Type: application/pdf; name=\"report.pdf\"\r\nContent-Disposition: attachment; filename=\"report.pdf\"\r\nContent-Transfer-Encoding: base64\r\n\r\n".utf8))
        bigMime.append(Data(bigBase64.utf8))
        bigMime.append(Data("\r\n--bigbnd--\r\n".utf8))
        var bigEmlx = Data("\(bigMime.count)\n".utf8)
        bigEmlx.append(bigMime)
        let bigEmlxURL = bigAttDir.appendingPathComponent("77.emlx")
        try bigEmlx.write(to: bigEmlxURL)

        let bigAttParser = EmlxParser(mailRootURL: bigAttRoot)
        let lazyBody = await bigAttParser.loadBody(for: 77)
        assertEqual(lazyBody.plainText, "Short 53-byte body for lazy large-attachment testing!", "lazy parse extracts plain text accurately")
        assertEqual(lazyBody.attachments.count, 1, "lazy parse discovers 1 attachment")
        assertTrue(lazyBody.attachments[0].inlineData == nil, "file-backed attachment stays lazy (inlineData == nil)")
        assertTrue(lazyBody.attachments[0].sourceByteRange != nil, "lazy attachment records exact byte range")
        let decodedOnDemand = EmlxParser.decodeAttachmentData(lazyBody.attachments[0])
        assertEqual(decodedOnDemand, bigPayload, "on-demand decodeAttachmentData reproduces exact 2 MiB attachment bytes")
        if case let .parsed(indexedText, indexedAttNames, _) = await bigAttParser.loadPlainTextForIndexing(for: 77, cachedMTime: nil) {
            assertEqual(indexedText, "Short 53-byte body for lazy large-attachment testing!", "plain-text indexing extracts body cleanly")
            assertEqual(indexedAttNames, ["report.pdf"], "plain-text indexing collects large attachment filename without decoding payload")
        } else {
            assertTrue(false, "loadPlainTextForIndexing should parse big attachment email")
        }

        // 31. Keyset cursor pagination (`fetchIndexableMessages(beforeRowID:limit:)`) scans all rows with zero gaps/duplicates
        let keysetDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-keyset-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: keysetDBURL) }
        var keysetDB: OpaquePointer?
        assertEqual(sqlite3_open(keysetDBURL.path, &keysetDB), SQLITE_OK, "open keyset db")
        var keysetSQL = """
        BEGIN;
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, message_id INTEGER, subject INTEGER, sender INTEGER, date_received REAL, read INTEGER, flagged INTEGER, deleted INTEGER, mailbox INTEGER);
        INSERT INTO mailboxes VALUES (1, 'imap://ACCT/INBOX');
        INSERT INTO mailboxes VALUES (2, 'imap://ACCT/Archive');
        INSERT INTO subjects VALUES (1, 'History');
        INSERT INTO addresses VALUES (1, 'u@example.com', 'User');
        """
        for i in 1...1050 {
            let mb = (i % 5 == 0) ? 1 : 2
            // Intentionally give an older ROWID (10) a very recent timestamp to test bounded top-K cutoff accuracy!
            let ts = (i == 10) ? (1700000000 + 99999) : (1700000000 + i)
            keysetSQL += "INSERT INTO messages VALUES (\(i), \(i), 1, 1, \(ts), 0, 0, 0, \(mb));\n"
        }
        keysetSQL += "COMMIT;"
        assertEqual(sqlite3_exec(keysetDB, keysetSQL, nil, nil, nil), SQLITE_OK, "seed 1,050 rows")
        sqlite3_close(keysetDB)

        let keysetReader = EnvelopeIndexReader(mailVersionURL: keysetDBURL.deletingLastPathComponent(), databaseURL: keysetDBURL)
        var collectedIDs: [Int64] = []
        var cursor: Int64? = nil
        while true {
            let page = try keysetReader.fetchIndexableMessages(beforeRowID: cursor, limit: 200)
            if page.isEmpty { break }
            collectedIDs.append(contentsOf: page.map(\.id))
            cursor = page.last?.id
            if page.count < 200 { break }
        }
        assertEqual(collectedIDs.count, 1050, "keyset pagination visits all 1,050 rows")
        assertEqual(Set(collectedIDs).count, 1050, "keyset pagination yields zero duplicates")
        assertEqual(collectedIDs.first, 1050, "keyset starts at highest ROWID")
        assertEqual(collectedIDs.last, 1, "keyset finishes at lowest ROWID")

        // 32. Bounded top-K search hydration keeps newer inbox hit even at low ROWID without hydrating all hits
        let allHitIDs = (1...1050).reversed().map { Int64($0) }
        let boundedPage = try keysetReader.fetchMessagePage(onlyInbox: true, searchQuery: "NoTitleMatch", bodyHitIDs: allHitIDs, limit: 50)
        assertEqual(boundedPage.messages.count, 50, "bounded top-K returns exact page size 50")
        assertTrue(boundedPage.hasMore, "bounded top-K reports hasMore = true for 210 inbox hits")
        assertEqual(boundedPage.messages.first?.id, 10, "bounded top-K still finds newest-dated inbox hit at low ROWID=10")

        // 33. BodySearchIndex surfaces SQLite write errors and rolls back failed batches atomically
        let invalidDBDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-invalid-fts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDBDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: invalidDBDir) }
        let brokenIndex = BodySearchIndex(databaseURL: invalidDBDir)
        var threwOpenError = false
        do {
            try await brokenIndex.upsertBatch([(rowID: 1, subject: "S", sender: "a@b.com", body: "content")])
        } catch let err as BodySearchIndexError {
            if case .openFailed = err {
                threwOpenError = true
            }
        }
        assertTrue(threwOpenError, "opening directory as BodySearchIndex throws BodySearchIndexError.openFailed")

        let rollbackFTSURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-fts-rollback-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: rollbackFTSURL) }
        let rollbackIndex = BodySearchIndex(databaseURL: rollbackFTSURL)
        try await rollbackIndex.upsertBatch([(rowID: 1, subject: "Keep", sender: "a@b.com", body: "initial_keep_token")])
        var faultDB: OpaquePointer?
        assertEqual(sqlite3_open(rollbackFTSURL.path, &faultDB), SQLITE_OK, "open rollback db for fault trigger")
        assertEqual(
            sqlite3_exec(
                faultDB,
                "CREATE TRIGGER fail_row_3 BEFORE INSERT ON indexed_rows WHEN new.row_id = 3 BEGIN SELECT RAISE(ABORT, 'simulated write fault'); END;",
                nil, nil, nil
            ),
            SQLITE_OK,
            "install fault trigger"
        )
        sqlite3_close(faultDB)

        var threwWriteError = false
        do {
            try await rollbackIndex.upsertBatch([
                (rowID: 2, subject: "Partial", sender: "a@b.com", body: "partial_should_rollback"),
                (rowID: 3, subject: "Boom", sender: "a@b.com", body: "fault_trigger_row")
            ])
        } catch let err as BodySearchIndexError {
            if case .sqliteError = err {
                threwWriteError = true
            }
        }
        assertTrue(threwWriteError, "mid-batch SQLite failure throws BodySearchIndexError.sqliteError")
        assertEqual(await rollbackIndex.allIndexedRowIDs(), [1], "failed batch rolls back row 2 atomically and preserves row 1")
        assertEqual(await rollbackIndex.searchRowIDs(query: "partial_should_rollback"), [], "rolled-back row leaves no FTS tokens")

        var recoverDB: OpaquePointer?
        assertEqual(sqlite3_open(rollbackFTSURL.path, &recoverDB), SQLITE_OK, "open rollback db to remove fault trigger")
        assertEqual(sqlite3_exec(recoverDB, "DROP TRIGGER fail_row_3;", nil, nil, nil), SQLITE_OK, "drop fault trigger")
        sqlite3_close(recoverDB)
        try await rollbackIndex.upsertBatch([
            (rowID: 2, subject: "Recovered", sender: "a@b.com", body: "partial_should_rollback"),
            (rowID: 3, subject: "Recovered3", sender: "a@b.com", body: "recovered_row_3")
        ])
        assertEqual(await rollbackIndex.totalIndexedCount(), 3, "retry after rollback commits full batch cleanly")

        // 34. AIService context budget filters error/blank messages and trims older history deterministically
        let noisyHistory: [AIChatMessage] = [
            AIChatMessage(role: .user, content: "m1_oldest"),
            AIChatMessage(role: .assistant, content: "   \n  "),
            AIChatMessage(role: .assistant, content: "请求失败：网络超时", isError: true),
            AIChatMessage(role: .assistant, content: "m2_reply"),
            AIChatMessage(role: .user, content: "m3_question"),
            AIChatMessage(role: .assistant, content: "m4_newest")
        ]
        let countTrimmed = AIService.prepareHistory(
            noisyHistory,
            budget: AIService.ContextBudget(maxHistoryMessages: 2, maxHistoryChars: 1000, maxMessageChars: 500)
        )
        assertEqual(countTrimmed.messages.map(\.content), ["m3_question", "m4_newest"], "prepareHistory keeps newest 2 valid messages in chronological order")
        assertEqual(countTrimmed.droppedCount, 2, "prepareHistory counts only omitted valid messages (excluding error/blank)")

        let charTrimmed = AIService.prepareHistory(
            [
                AIChatMessage(role: .user, content: String(repeating: "a", count: 30)),
                AIChatMessage(role: .assistant, content: String(repeating: "b", count: 30)),
                AIChatMessage(role: .user, content: String(repeating: "c", count: 30))
            ],
            budget: AIService.ContextBudget(maxHistoryMessages: 10, maxHistoryChars: 65, maxMessageChars: 100)
        )
        assertEqual(charTrimmed.messages.count, 2, "prepareHistory enforces total character budget")
        assertEqual(charTrimmed.droppedCount, 1, "prepareHistory reports 1 dropped message under char budget")
        assertEqual(charTrimmed.messages.first?.content, String(repeating: "b", count: 30), "prepareHistory keeps contiguous newest tail")

        let clippedSingle = AIService.prepareHistory(
            [AIChatMessage(role: .assistant, content: String(repeating: "x", count: 120))],
            budget: AIService.ContextBudget(maxHistoryMessages: 5, maxHistoryChars: 50, maxMessageChars: 80)
        )
        assertEqual(clippedSingle.messages.count, 1, "oversized newest message is clipped instead of dropping all history")
        assertTrue((clippedSingle.messages.first?.content.count ?? 999) <= 50, "oversized newest message fits within maxHistoryChars")

        // 35. Compose attachment script generation, error parsing, and pre-flight file validation
        let sampleAttachURL = URL(fileURLWithPath: "/tmp/mailpilot-sample-report.pdf")
        let generatedScript = MailAppleScriptBridge.buildComposeScript(
            from: "me@example.com",
            to: ["dest@example.com"],
            cc: [],
            subject: "带附件测试",
            body: "",
            attachmentURLs: [sampleAttachURL],
            shouldSend: true
        )
        assertTrue(generatedScript.contains("content:\"\\n\""), "empty body with attachments injects newline so last paragraph exists")
        assertTrue(generatedScript.contains("set attachAlias0 to (POSIX file \"/tmp/mailpilot-sample-report.pdf\") as alias"), "POSIX alias resolves outside tell Mail block")
        assertTrue(generatedScript.contains("tell content of newMsg"), "attachment is added to content of newMsg")
        assertTrue(generatedScript.contains("return \"ATTACH_FAILED:0:\" & errMsg"), "per-attachment error includes exact index")

        let parsedAttachErr = MailAppleScriptBridge.parseAttachFailure("ATTACH_FAILED:2:Mail got an error: Can't make alias")
        assertEqual(parsedAttachErr?.index, 2, "parseAttachFailure extracts exact attachment index")
        assertEqual(parsedAttachErr?.reason, "Mail got an error: Can't make alias", "parseAttachFailure preserves colons in error reason")
        assertTrue(MailAppleScriptBridge.parseAttachFailure("OK") == nil, "parseAttachFailure ignores OK response")

        let missingAttachURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-nonexistent-\(UUID().uuidString).pdf")
        var caughtMissingAttach = false
        do {
            try await MailAppleScriptBridge.sendMessage(
                from: nil,
                to: ["dest@example.com"],
                cc: [],
                subject: "Missing test",
                body: "hello",
                attachmentURLs: [missingAttachURL]
            )
        } catch let err as MailComposeAttachmentError {
            if case .fileMissing(let idx, let filename) = err {
                caughtMissingAttach = (idx == 0 && filename == missingAttachURL.lastPathComponent)
            }
        }
        assertTrue(caughtMissingAttach, "sendMessage fails fast with MailComposeAttachmentError.fileMissing before calling Mail.app")

        let dirAttachURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-dir-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dirAttachURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirAttachURL) }
        var caughtDirAttach = false
        do {
            try await MailAppleScriptBridge.saveDraft(
                from: nil,
                to: [],
                cc: [],
                subject: "Dir test",
                body: "",
                attachmentURLs: [dirAttachURL]
            )
        } catch let err as MailComposeAttachmentError {
            if case .isDirectory(let idx, let filename) = err {
                caughtDirAttach = (idx == 0 && filename == dirAttachURL.lastPathComponent)
            }
        }
        assertTrue(caughtDirAttach, "saveDraft rejects directory attachment with MailComposeAttachmentError.isDirectory")

        // 36. MailDirectoryWatcher detects writes and atomic replacements to Envelope Index-wal
        let fallbackWatchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-watch-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fallbackWatchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fallbackWatchDir) }
        let fakeDB = fallbackWatchDir.appendingPathComponent("Envelope Index")
        let fakeWAL = fallbackWatchDir.appendingPathComponent("Envelope Index-wal")
        try Data("init".utf8).write(to: fakeDB)
        try Data("wal0".utf8).write(to: fakeWAL)

        final class CounterBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() {
                lock.lock()
                value += 1
                lock.unlock()
            }
            func current() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
        let hitCounter = CounterBox()
        let fallbackWatcher = MailDirectoryWatcher(directoryURL: fallbackWatchDir) {
            hitCounter.increment()
        }
        defer { fallbackWatcher.stop() }
        try await Task.sleep(for: .milliseconds(150))
        try Data("wal1-new-mail-commit".utf8).write(to: fakeWAL)
        let waitDeadline = Date().addingTimeInterval(3.0)
        while hitCounter.current() == 0 && Date() < waitDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        assertTrue(hitCounter.current() > 0, "MailDirectoryWatcher fires on Envelope Index-wal write")

        // 37. EnvelopeIndexReader fetchRecipients (To/CC/dedup) & local contact search autocomplete
        let contactDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-contacts-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: contactDBURL) }
        var contactDB: OpaquePointer?
        assertEqual(sqlite3_open(contactDBURL.path, &contactDB), SQLITE_OK, "create synthetic contacts Envelope Index")
        let contactSchema = """
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        INSERT INTO addresses (ROWID, address, comment) VALUES
            (1, 'alice@company.com', 'Alice Chen'),
            (2, 'bob@company.com', 'Bob Wang'),
            (3, 'carol@partner.io', '张敏 Carol'),
            (4, 'secret@company.com', 'Hidden BCC'),
            (5, 'ALICE@company.com', 'Alice Chen'),
            (6, 'not-an-email', 'Invalid Entry');
        INSERT INTO recipients (ROWID, message, address, type, position) VALUES
            (1, 100, 1, 0, 0),
            (2, 100, 5, 0, 1),
            (3, 100, 2, 1, 0),
            (4, 100, 3, 1, 1),
            (5, 100, 4, 2, 0);
        """
        assertEqual(sqlite3_exec(contactDB, contactSchema, nil, nil, nil), SQLITE_OK, "seed recipients & addresses")
        sqlite3_close(contactDB)

        let contactReader = EnvelopeIndexReader(mailVersionURL: contactDBURL.deletingLastPathComponent(), databaseURL: contactDBURL)
        let fetchedRecipients = try contactReader.fetchRecipients(for: 100)
        assertEqual(fetchedRecipients.count, 3, "fetchRecipients returns deduplicated To + CC and omits BCC")
        assertEqual(fetchedRecipients[0].address, "alice@company.com", "first recipient is To Alice")
        assertTrue(!fetchedRecipients[0].isCC, "Alice is To recipient")
        assertEqual(fetchedRecipients[1].address, "bob@company.com", "second recipient is CC Bob")
        assertTrue(fetchedRecipients[1].isCC, "Bob is CC recipient")
        assertEqual(fetchedRecipients[2].address, "carol@partner.io", "third recipient is CC Carol")

        let byPrefix = try contactReader.searchContacts(query: "ali", limit: 5)
        assertEqual(byPrefix.count, 1, "searchContacts deduplicates case-insensitive duplicate addresses")
        assertEqual(byPrefix.first?.address.lowercased(), "alice@company.com", "searchContacts matches email prefix")
        assertEqual(byPrefix.first?.frequency, 2, "searchContacts aggregates frequency across duplicate address rows")

        let byChineseName = try contactReader.searchContacts(query: "张敏", limit: 5)
        assertEqual(byChineseName.first?.address, "carol@partner.io", "searchContacts matches Chinese display name")

        // 38. BCC AppleScript generation & AccountCustomization backward-compatible signature decoding
        let bccScript = MailAppleScriptBridge.buildComposeScript(
            from: "me@example.com",
            to: ["alice@company.com"],
            cc: ["bob@company.com"],
            bcc: ["audit@company.com"],
            subject: "BCC Test",
            body: "hello",
            attachmentURLs: [],
            shouldSend: true
        )
        assertTrue(bccScript.contains("make new bcc recipient at end of bcc recipients with properties {address:\"audit@company.com\"}"), "buildComposeScript emits bcc recipient")

        let legacyCustomJSON = Data(#"{"senderDisplayName":"Jay","sidebarName":"Work"}"#.utf8)
        let decodedLegacyCustom = try JSONDecoder().decode(AccountCustomization.self, from: legacyCustomJSON)
        assertEqual(decodedLegacyCustom.senderDisplayName, "Jay", "legacy AccountCustomization keeps senderDisplayName")
        assertEqual(decodedLegacyCustom.signature, "", "legacy AccountCustomization defaults signature to empty string")

        // 39. AttachmentTextExtractor extracts CSV/HTML/RTF text, enforces budgets, and skips unsupported formats
        let csvData = Data("项目,金额,日期\n差旅报销,1280.50,2026-11-20\n".utf8)
        let csvRes = AttachmentTextExtractor.extract(data: csvData, filename: "报销单.csv", mimeType: "text/csv")
        if case .extracted(let extracted) = csvRes {
            assertTrue(extracted.text.contains("1280.50"), "AttachmentTextExtractor decodes CSV text accurately")
            assertEqual(extracted.method, "表格文本", "CSV uses 表格文本 method label")
            assertTrue(!extracted.wasTruncated, "short CSV is not truncated")
        } else {
            assertTrue(false, "CSV extraction should succeed")
        }

        let longTextData = Data(String(repeating: "A", count: 900).utf8)
        let clippedRes = AttachmentTextExtractor.extract(data: longTextData, filename: "notes.txt", maxChars: 200)
        if case .extracted(let extracted) = clippedRes {
            assertEqual(extracted.text.count, 200, "AttachmentTextExtractor enforces maxChars budget")
            assertTrue(extracted.wasTruncated, "clipped text marks wasTruncated = true")
        } else {
            assertTrue(false, "TXT extraction should succeed")
        }

        let zipRes = AttachmentTextExtractor.extract(data: Data([0x50, 0x4B, 0x03, 0x04]), filename: "archive.zip")
        if case .skipped(let name, _) = zipRes {
            assertEqual(name, "archive.zip", "unsupported binary archive is skipped cleanly")
        } else {
            assertTrue(false, "ZIP archive should be skipped")
        }

        // 40. EmlxParser.parseForIndexing collects attachment names & BodySearchIndex indexes them + has_attachments + snippets
        let attachIdxEmlx = """
        999
        From: billing@vendor.com
        Subject: Monthly Statement
        Content-Type: multipart/mixed; boundary="mix-idx"

        --mix-idx
        Content-Type: text/plain; charset="utf-8"

        Please review the attached invoice summary.
        --mix-idx
        Content-Type: application/pdf; name="Q4_Invoice_2026.pdf"
        Content-Disposition: attachment; filename="Q4_Invoice_2026.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --mix-idx--
        """
        let indexedParsed = EmlxParser.parseForIndexing(Data(attachIdxEmlx.utf8))
        assertTrue(indexedParsed.plainText.contains("attached invoice summary"), "parseForIndexing keeps plain text")
        assertEqual(indexedParsed.attachmentNames, ["Q4_Invoice_2026.pdf"], "parseForIndexing collects MIME attachment filename")

        let attachFTSURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-fts-attach-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: attachFTSURL) }
        let attachFTS = BodySearchIndex(databaseURL: attachFTSURL)
        try await attachFTS.upsertBatchWithMetadata([
            (rowID: 701, subject: "Monthly Statement", sender: "billing@vendor.com", body: "\(indexedParsed.plainText)\n[附件] Q4_Invoice_2026.pdf", fileMTime: 100.0, hasAttachments: true),
            (rowID: 702, subject: "Plain Greeting", sender: "friend@example.com", body: "Just saying hello", fileMTime: 100.0, hasAttachments: false)
        ])
        let attSearchHits = await attachFTS.searchRowIDs(query: "Q4_Invoice_2026")
        assertEqual(attSearchHits, [701], "BodySearchIndex finds message by indexed attachment filename")
        let withAttIDs = await attachFTS.fetchRowIDsWithAttachments()
        assertEqual(withAttIDs, Set([701]), "fetchRowIDsWithAttachments returns only rows flagged with attachments")
        let snippets = await attachFTS.fetchSnippets(for: [701, 702], maxChars: 120)
        assertTrue(snippets[701]?.contains("Q4_Invoice_2026.pdf") == true, "fetchSnippets returns bounded body excerpt")

        // 41. EnvelopeIndexReader date-range and native attachment-table filters
        let filterDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-filter-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: filterDBURL) }
        var filterDB: OpaquePointer?
        assertEqual(sqlite3_open(filterDBURL.path, &filterDB), SQLITE_OK, "create synthetic filter db")
        let nowTS = Date().timeIntervalSince1970
        let oldTS = nowTS - 40 * 86400
        let filterSQL = """
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, date_received REAL, read INTEGER, flagged INTEGER, deleted INTEGER, mailbox INTEGER);
        CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY, message INTEGER, name TEXT);
        INSERT INTO mailboxes VALUES (1, 'imap://ACCT1/INBOX');
        INSERT INTO subjects VALUES (1, 'Recent With PDF'), (2, 'Recent Plain'), (3, 'Old With PDF');
        INSERT INTO addresses VALUES (1, 'ops@company.com', 'Ops');
        INSERT INTO messages VALUES
            (1, 1, 1, \(nowTS - 3600), 0, 0, 0, 1),
            (2, 2, 1, \(nowTS - 1800), 1, 0, 0, 1),
            (3, 3, 1, \(oldTS), 0, 0, 0, 1);
        INSERT INTO attachments VALUES (1, 1, 'recent.pdf'), (2, 3, 'old.pdf');
        """
        assertEqual(sqlite3_exec(filterDB, filterSQL, nil, nil, nil), SQLITE_OK, "seed filter db")
        sqlite3_close(filterDB)

        let filterReader = EnvelopeIndexReader(mailVersionURL: filterDBURL.deletingLastPathComponent(), databaseURL: filterDBURL)
        let recentCutoff = Date().addingTimeInterval(-7 * 86400)
        let recentPage = try filterReader.fetchMessagePage(onlyInbox: true, sinceDate: recentCutoff, limit: 50)
        assertEqual(Set(recentPage.messages.map(\.id)), Set([1, 2]), "sinceDate filters out 40-day-old email")
        let recentAttPage = try filterReader.fetchMessagePage(onlyInbox: true, onlyWithAttachments: true, sinceDate: recentCutoff, limit: 50)
        assertEqual(recentAttPage.messages.map(\.id), [1], "combined sinceDate + onlyWithAttachments matches only row 1")

        // 42. MailTagClassifier UTF-8 fast path preserves exact Unicode canonical equivalence & grapheme boundaries
        var unicodeSettings = MailTagSettings()
        unicodeSettings.customKeywords[MailSmartTag.meeting.rawValue] = "café, ガ"
        unicodeSettings.customKeywords[MailSmartTag.billing.rawValue] = "i"
        let preparedUnicode = MailTagClassifier.PreparedRules(settings: unicodeSettings)
        assertTrue(
            MailTagClassifier.classify(subject: "Cafe\u{0301} sync", senderName: "Team", senderAddress: "a@b.com", prepared: preparedUnicode).contains(.meeting),
            "NFD Cafe\\u{0301} matches NFC custom keyword café"
        )
        assertTrue(
            MailTagClassifier.classify(subject: "カ\u{3099}イド", senderName: "Team", senderAddress: "a@b.com", prepared: preparedUnicode).contains(.meeting),
            "NFD Katakana voiced mark matches precomposed ガ"
        )
        assertTrue(
            !MailTagClassifier.classify(subject: "OTP\u{0301} test", senderName: "Bob", senderAddress: "bob@example.com", prepared: preparedUnicode).contains(.verification),
            "Combining accent on P in OTP\\u{0301} does not false-match ASCII otp"
        )
        assertTrue(
            !MailTagClassifier.classify(subject: "İ", senderName: "Bob", senderAddress: "bob@example.com", prepared: preparedUnicode).contains(.billing),
            "Turkish dotted İ does not false-match ASCII custom keyword i"
        )
        assertTrue(
            MailTagClassifier.classify(subject: "发票与账单提醒", senderName: "Stripe", senderAddress: "billing@stripe.com", prepared: preparedUnicode).contains(.billing),
            "CJK + ASCII fast path matches built-in billing keywords"
        )

        print("ALL 42 CORE TEST SUITES PASSED")
        try await ChatGPTTests.run()
    }
}
