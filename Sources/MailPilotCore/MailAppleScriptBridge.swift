import Foundation

/// Delegates all write actions (read/flag/draft/check mail) to Apple Mail via AppleScript
/// so Mail.app remains the sole writer of `Envelope Index` and handles server sync safely.
public enum MailAppleScriptBridge {
    /// Triggers Mail.app to check for new mail immediately.
    public static func triggerCheckForNewMail() async throws {
        let script = """
        tell application "Mail"
            check for new mail
        end tell
        """
        _ = try await runAppleScript(script)
    }

    /// Marks a message as read/unread in Mail.app by matching its numeric ROWID (`id`).
    /// Checks `inbox` first for instant response before scanning other mailboxes.
    public static func setReadStatus(rowID: Int64, isRead: Bool) async throws {
        let boolLiteral = isRead ? "true" : "false"
        let script = """
        tell application "Mail"
            try
                set inboxMsgs to (every message of inbox whose id is \(rowID))
                if (count of inboxMsgs) > 0 then
                    set read status of (item 1 of inboxMsgs) to \(boolLiteral)
                    return "OK"
                end if
            end try
            repeat with acct in accounts
                repeat with mb in mailboxes of acct
                    try
                        set targetMsgs to (every message of mb whose id is \(rowID))
                        if (count of targetMsgs) > 0 then
                            set read status of (item 1 of targetMsgs) to \(boolLiteral)
                            return "OK"
                        end if
                    end try
                end repeat
            end repeat
            return "NOT_FOUND"
        end tell
        """
        let result = try await runAppleScript(script)
        if result == "NOT_FOUND" {
            throw MailAccessError.appleScriptFailed(message: "未在 Mail.app 中找到该邮件")
        }
    }

    /// Toggles flagged status in Mail.app by matching its numeric ROWID (`id`).
    public static func setFlaggedStatus(rowID: Int64, isFlagged: Bool) async throws {
        let boolLiteral = isFlagged ? "true" : "false"
        let script = """
        tell application "Mail"
            try
                set inboxMsgs to (every message of inbox whose id is \(rowID))
                if (count of inboxMsgs) > 0 then
                    set flagged status of (item 1 of inboxMsgs) to \(boolLiteral)
                    return "OK"
                end if
            end try
            repeat with acct in accounts
                repeat with mb in mailboxes of acct
                    try
                        set targetMsgs to (every message of mb whose id is \(rowID))
                        if (count of targetMsgs) > 0 then
                            set flagged status of (item 1 of targetMsgs) to \(boolLiteral)
                            return "OK"
                        end if
                    end try
                end repeat
            end repeat
            return "NOT_FOUND"
        end tell
        """
        let result = try await runAppleScript(script)
        if result == "NOT_FOUND" {
            throw MailAccessError.appleScriptFailed(message: "未在 Mail.app 中找到该邮件")
        }
    }

    /// Opens the original email in Mail.app.
    public static func openInMailApp(rowID: Int64) async throws {
        let script = """
        tell application "Mail"
            activate
            try
                set inboxMsgs to (every message of inbox whose id is \(rowID))
                if (count of inboxMsgs) > 0 then
                    open (item 1 of inboxMsgs)
                    return "OK"
                end if
            end try
            repeat with acct in accounts
                repeat with mb in mailboxes of acct
                    try
                        set targetMsgs to (every message of mb whose id is \(rowID))
                        if (count of targetMsgs) > 0 then
                            open (item 1 of targetMsgs)
                            return "OK"
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
        _ = try await runAppleScript(script)
    }

    /// Creates a draft reply in Mail.app and brings it to front for human review before sending.
    public static func createDraft(to recipient: String, subject: String, body: String) async throws {
        let escapedTo = escapeAppleScriptString(recipient)
        let replySubject = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
        let escapedSubject = escapeAppleScriptString(replySubject)
        let escapedBody = escapeAppleScriptString(body)

        let script = """
        tell application "Mail"
            activate
            set newMsg to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedBody)", visible:true}
            tell newMsg
                make new to recipient at end of to recipients with properties {address:"\(escapedTo)"}
            end tell
        end tell
        """
        _ = try await runAppleScript(script)
    }

    /// Fetches all accounts (id UUID, display name, primary email) from macOS Mail.app
    /// so sidebar mailboxes can be grouped cleanly per account.
    /// Falls back to `user name of acct` for Exchange/Outlook accounts whose `email addresses` list may be empty.
    public static func fetchAccounts() async -> [MailAccountInfo] {
        let script = """
        tell application "Mail"
            set outList to {}
            repeat with acct in accounts
                try
                    set acctID to (id of acct as text)
                    set acctName to (name of acct as text)
                    set primaryEmail to ""
                    try
                        set addrs to email addresses of acct
                        if (count of addrs) > 0 then
                            set primaryEmail to (item 1 of addrs as text)
                        end if
                    end try
                    if primaryEmail is "" then
                        try
                            set uName to (user name of acct as text)
                            if uName contains "@" then
                                set primaryEmail to uName
                            end if
                        end try
                    end if
                    set end of outList to (acctID & tab & acctName & tab & primaryEmail)
                end try
            end repeat
            set AppleScript's text item delimiters to linefeed
            return outList as text
        end tell
        """
        guard let output = try? await runAppleScript(script) else { return [] }
        var accounts: [MailAccountInfo] = []
        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            let id = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let name = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let email = parts.count >= 3 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !id.isEmpty {
                accounts.append(MailAccountInfo(id: id, name: name, email: email))
            }
        }
        return accounts
    }

    /// Fetches all sender email addresses configured in macOS Mail.app.
    public static func fetchAccountEmails() async -> [String] {
        let script = """
        tell application "Mail"
            set outList to {}
            repeat with acct in accounts
                try
                    repeat with addr in email addresses of acct
                        set end of outList to (addr as text)
                    end repeat
                end try
            end repeat
            set AppleScript's text item delimiters to linefeed
            return outList as text
        end tell
        """
        guard let output = try? await runAppleScript(script) else { return [] }
        var seen: Set<String> = []
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains("@") && seen.insert($0.lowercased()).inserted }
    }

    /// Sends an email directly via macOS Mail.app in the background without switching apps.
    public static func sendMessage(
        from senderEmail: String?,
        to recipients: [String],
        cc ccRecipients: [String],
        subject: String,
        body: String,
        attachmentURLs: [URL]
    ) async throws {
        try await composeAndDispatch(
            from: senderEmail,
            to: recipients,
            cc: ccRecipients,
            subject: subject,
            body: body,
            attachmentURLs: attachmentURLs,
            shouldSend: true
        )
    }

    /// Saves an outgoing message as a draft in macOS Mail.app without leaving MailPilot.
    public static func saveDraft(
        from senderEmail: String?,
        to recipients: [String],
        cc ccRecipients: [String],
        subject: String,
        body: String,
        attachmentURLs: [URL]
    ) async throws {
        try await composeAndDispatch(
            from: senderEmail,
            to: recipients,
            cc: ccRecipients,
            subject: subject,
            body: body,
            attachmentURLs: attachmentURLs,
            shouldSend: false
        )
    }

    /// Moves a message to Trash in macOS Mail.app.
    public static func deleteMessage(rowID: Int64) async throws {
        let script = """
        tell application "Mail"
            try
                set inboxMsgs to (every message of inbox whose id is \(rowID))
                if (count of inboxMsgs) > 0 then
                    delete (item 1 of inboxMsgs)
                    return "OK"
                end if
            end try
            repeat with acct in accounts
                repeat with mb in mailboxes of acct
                    try
                        set targetMsgs to (every message of mb whose id is \(rowID))
                        if (count of targetMsgs) > 0 then
                            delete (item 1 of targetMsgs)
                            return "OK"
                        end if
                    end try
                end repeat
            end repeat
            return "NOT_FOUND"
        end tell
        """
        let result = try await runAppleScript(script)
        if result == "NOT_FOUND" {
            throw MailAccessError.appleScriptFailed(message: "未在 Mail.app 中找到该邮件")
        }
    }

    /// Moves a message to the account's Archive / All Mail mailbox in macOS Mail.app.
    /// Fast path checks `inbox` first so consecutive archive clicks complete in milliseconds.
    public static func archiveMessage(rowID: Int64) async throws {
        let script = """
        tell application "Mail"
            set targetMsg to missing value
            set targetAcct to missing value
            try
                set inboxMsgs to (every message of inbox whose id is \(rowID))
                if (count of inboxMsgs) > 0 then
                    set targetMsg to item 1 of inboxMsgs
                    set targetAcct to account of mailbox of targetMsg
                end if
            end try

            if targetMsg is missing value then
                repeat with acct in accounts
                    repeat with mb in mailboxes of acct
                        try
                            set foundMsgs to (every message of mb whose id is \(rowID))
                            if (count of foundMsgs) > 0 then
                                set targetMsg to item 1 of foundMsgs
                                set targetAcct to acct
                                exit repeat
                            end if
                        end try
                    end repeat
                    if targetMsg is not missing value then exit repeat
                end repeat
            end if

            if targetMsg is missing value then
                return "NOT_FOUND"
            end if

            set archiveBox to missing value
            repeat with mb in mailboxes of targetAcct
                set mbName to name of mb
                if mbName is "Archive" or mbName is "All Mail" or mbName is "归档" or mbName is "所有邮件" then
                    set archiveBox to mb
                    exit repeat
                end if
            end repeat

            if archiveBox is missing value then
                return "NO_ARCHIVE"
            end if

            move targetMsg to archiveBox
            return "OK"
        end tell
        """
        let result = try await runAppleScript(script)
        if result == "NO_ARCHIVE" {
            throw MailAccessError.appleScriptFailed(message: "该邮箱账号未配置「归档」文件夹，无法自动归档")
        }
        if result == "NOT_FOUND" {
            throw MailAccessError.appleScriptFailed(message: "未在 Mail.app 中找到该邮件")
        }
    }

    private static func composeAndDispatch(
        from senderEmail: String?,
        to recipients: [String],
        cc ccRecipients: [String],
        subject: String,
        body: String,
        attachmentURLs: [URL],
        shouldSend: Bool
    ) async throws {
        let escapedSubject = escapeAppleScriptString(subject)
        let escapedBody = escapeAppleScriptString(body)

        var props = ["subject:\"\(escapedSubject)\"", "content:\"\(escapedBody)\"", "visible:false"]
        if let sender = senderEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
            props.append("sender:\"\(escapeAppleScriptString(sender))\"")
        }

        var recipientLines: [String] = []
        for addr in recipients {
            let clean = addr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                recipientLines.append("make new to recipient at end of to recipients with properties {address:\"\(escapeAppleScriptString(clean))\"}")
            }
        }
        for addr in ccRecipients {
            let clean = addr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                recipientLines.append("make new cc recipient at end of cc recipients with properties {address:\"\(escapeAppleScriptString(clean))\"}")
            }
        }
        for url in attachmentURLs {
            let escapedPath = escapeAppleScriptString(url.path)
            recipientLines.append("make new attachment with properties {file name:POSIX file \"\(escapedPath)\"} at after the last paragraph")
        }

        let innerBlock = recipientLines.joined(separator: "\n        ")
        let finalAction: String
        if shouldSend {
            finalAction = """
                set didSend to send newMsg
                if didSend is not true then
                    return "SEND_FAILED"
                end if
            """
        } else {
            finalAction = "    save newMsg"
        }

        let script = """
        tell application "Mail"
            set newMsg to make new outgoing message with properties {\(props.joined(separator: ", "))}
            tell newMsg
                \(innerBlock)
            end tell
        \(finalAction)
            return "OK"
        end tell
        """
        let result = try await runAppleScript(script)
        if shouldSend && result != "OK" {
            throw MailAccessError.appleScriptFailed(message: "系统 Mail.app 未确认发送成功（状态：\(result.isEmpty ? "未知" : result)），已保留草稿")
        }
    }

    // MARK: - Execution (Serialized to prevent concurrent osascript storms against Mail.app)

    private static let scriptQueue = DispatchQueue(label: "com.mailpilot.applescript.serial", qos: .userInitiated)

    private static func runAppleScript(_ source: String, timeoutSeconds: TimeInterval = 30) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            scriptQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                // Pass AppleScript via stdin to avoid ARG_MAX limits on long email bodies.
                process.arguments = ["-"]

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let ioGroup = DispatchGroup()
                var outData = Data()
                var errData = Data()

                do {
                    try process.run()
                    if let scriptBytes = source.data(using: .utf8) {
                        stdinPipe.fileHandleForWriting.write(scriptBytes)
                    }
                    try? stdinPipe.fileHandleForWriting.close()

                    // Drain stdout and stderr concurrently to avoid pipe-buffer deadlock.
                    ioGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        ioGroup.leave()
                    }
                    ioGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        ioGroup.leave()
                    }

                    let exitSem = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in exitSem.signal() }
                    let waitResult = exitSem.wait(timeout: .now() + timeoutSeconds)
                    if waitResult == .timedOut {
                        process.terminate()
                        _ = exitSem.wait(timeout: .now() + 2)
                        continuation.resume(throwing: MailAccessError.appleScriptFailed(message: "Mail.app 响应超时（\(Int(timeoutSeconds)) 秒），操作已中止"))
                        return
                    }
                    ioGroup.wait()

                    if process.terminationStatus == 0 {
                        let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.resume(returning: output)
                    } else {
                        let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                            ?? "osascript exited with status \(process.terminationStatus)"
                        continuation.resume(throwing: MailAccessError.appleScriptFailed(message: errMsg))
                    }
                } catch {
                    continuation.resume(throwing: MailAccessError.appleScriptFailed(message: error.localizedDescription))
                }
            }
        }
    }

    static func escapeAppleScriptString(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
