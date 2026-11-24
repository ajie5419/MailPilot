import Foundation

public struct MailAccountInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let email: String

    public init(id: String, name: String, email: String) {
        self.id = id
        self.name = name
        self.email = email
    }

    public var displayTitle: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        return email.isEmpty ? "邮箱账号" : email
    }
}

public struct AccountCustomization: Codable, Equatable, Sendable {
    public var senderDisplayName: String
    public var sidebarName: String
    public var customIconPath: String?
    public var presetLogoID: String?
    public var sfSymbolName: String?

    public init(
        senderDisplayName: String = "",
        sidebarName: String = "",
        customIconPath: String? = nil,
        presetLogoID: String? = nil,
        sfSymbolName: String? = nil
    ) {
        self.senderDisplayName = senderDisplayName
        self.sidebarName = sidebarName
        self.customIconPath = customIconPath
        self.presetLogoID = presetLogoID
        self.sfSymbolName = sfSymbolName
    }
}

public struct MailboxInfo: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let url: String
    public let accountID: String
    public let displayName: String
    public let unreadCount: Int
    public let sortOrder: Int

    public init(
        id: Int64,
        url: String,
        accountID: String = "local",
        displayName: String,
        unreadCount: Int,
        sortOrder: Int = 10
    ) {
        self.id = id
        self.url = url
        self.accountID = accountID
        self.displayName = displayName
        self.unreadCount = unreadCount
        self.sortOrder = sortOrder
    }
}

public struct MailMessageSummary: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let messageIDHeader: String?
    public let subject: String
    public let senderAddress: String
    public let senderName: String
    public let dateReceived: Date
    public let isRead: Bool
    public let isFlagged: Bool
    public let mailboxID: Int64
    public let mailboxName: String
    public let accountID: String

    public init(
        id: Int64,
        messageIDHeader: String?,
        subject: String,
        senderAddress: String,
        senderName: String,
        dateReceived: Date,
        isRead: Bool,
        isFlagged: Bool,
        mailboxID: Int64,
        mailboxName: String,
        accountID: String = "local"
    ) {
        self.id = id
        self.messageIDHeader = messageIDHeader
        self.subject = subject
        self.senderAddress = senderAddress
        self.senderName = senderName
        self.dateReceived = dateReceived
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.mailboxID = mailboxID
        self.mailboxName = mailboxName
        self.accountID = accountID
    }

    public var displaySender: String {
        let trimmed = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? senderAddress : trimmed
    }
}

public struct MailAttachment: Identifiable, Hashable, Sendable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int
    public let localFileURL: URL?
    public let inlineData: Data?

    public init(
        id: String = UUID().uuidString,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        localFileURL: URL? = nil,
        inlineData: Data? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.localFileURL = localFileURL
        self.inlineData = inlineData
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    public var fileExtension: String {
        (filename as NSString).pathExtension.lowercased()
    }
}

public struct ParsedMailBody: Sendable {
    public let plainText: String
    public let rawHTML: String?
    public let verificationCode: String?
    public let sourcePath: String?
    public let attachments: [MailAttachment]

    public init(
        plainText: String,
        rawHTML: String? = nil,
        verificationCode: String? = nil,
        sourcePath: String? = nil,
        attachments: [MailAttachment] = []
    ) {
        self.plainText = plainText
        self.rawHTML = rawHTML
        self.verificationCode = verificationCode
        self.sourcePath = sourcePath
        self.attachments = attachments
    }
}

public enum MailAccessError: LocalizedError, Sendable {
    case mailDirectoryNotFound
    case fullDiskAccessRequired(path: String)
    case databaseOpenFailed(code: Int32, message: String)
    case queryFailed(message: String)
    case appleScriptFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .mailDirectoryNotFound:
            return "未找到 macOS 邮件数据目录（~/Library/Mail）。请先在系统自带「邮件」App 中登录至少一个邮箱。"
        case .fullDiskAccessRequired(let path):
            return "需要「完全磁盘访问权限」才能只读访问原生邮件索引（\(path)）。"
        case .databaseOpenFailed(let code, let message):
            return "无法只读打开 Envelope Index（错误码 \(code)）：\(message)"
        case .queryFailed(let message):
            return "查询邮件索引失败：\(message)"
        case .appleScriptFailed(let message):
            return "调用系统「邮件」App 执行操作失败：\(message)"
        }
    }
}

public struct AIChatMessage: Identifiable, Sendable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public let content: String
    public let createdAt: Date

    public init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public enum AIAuthMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatGPT = "chatgpt_direct"
    case subscriptionCLI = "subscription_cli"
    case oauthPKCE = "oauth_pkce"
    case apiKey = "api_key"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT 订阅"
        case .subscriptionCLI: return "订阅 CLI（Claude / ChatGPT）"
        case .oauthPKCE: return "浏览器 OAuth 登录"
        case .apiKey: return "API Key / 本地模型"
        }
    }
}

public struct AIConfig: Codable, Sendable, Equatable {
    public var authMode: AIAuthMode
    public var chatGPTModel: String?

    // Mode 1: Subscription CLI
    public var cliProvider: SubscriptionCLIProvider
    public var cliCustomPath: String
    public var cliModelOverride: String

    // Mode 2: OAuth 2.0 PKCE
    public var oauth: OAuthProviderConfig

    // Mode 3: API Key / Local Ollama
    public var baseURL: String
    public var apiKey: String
    public var model: String

    // Shared Privacy Option
    public var maskSensitiveData: Bool

    public init(
        authMode: AIAuthMode = .chatGPT,
        chatGPTModel: String? = nil,
        cliProvider: SubscriptionCLIProvider = .antigravity,
        cliCustomPath: String = "",
        cliModelOverride: String = "",
        oauth: OAuthProviderConfig = OAuthProviderConfig(),
        baseURL: String = "http://localhost:11434/v1",
        apiKey: String = "",
        model: String = "qwen2.5:14b",
        maskSensitiveData: Bool = true
    ) {
        self.authMode = authMode
        self.chatGPTModel = chatGPTModel
        self.cliProvider = cliProvider
        self.cliCustomPath = cliCustomPath
        self.cliModelOverride = cliModelOverride
        self.oauth = oauth
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maskSensitiveData = maskSensitiveData
    }
}
