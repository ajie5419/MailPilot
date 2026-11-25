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
    public var signature: String
    public var customIconPath: String?
    public var presetLogoID: String?
    public var sfSymbolName: String?

    private enum CodingKeys: String, CodingKey {
        case senderDisplayName, sidebarName, signature, customIconPath, presetLogoID, sfSymbolName
    }

    public init(
        senderDisplayName: String = "",
        sidebarName: String = "",
        signature: String = "",
        customIconPath: String? = nil,
        presetLogoID: String? = nil,
        sfSymbolName: String? = nil
    ) {
        self.senderDisplayName = senderDisplayName
        self.sidebarName = sidebarName
        self.signature = signature
        self.customIconPath = customIconPath
        self.presetLogoID = presetLogoID
        self.sfSymbolName = sfSymbolName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.senderDisplayName = try c.decodeIfPresent(String.self, forKey: .senderDisplayName) ?? ""
        self.sidebarName = try c.decodeIfPresent(String.self, forKey: .sidebarName) ?? ""
        self.signature = try c.decodeIfPresent(String.self, forKey: .signature) ?? ""
        self.customIconPath = try c.decodeIfPresent(String.self, forKey: .customIconPath)
        self.presetLogoID = try c.decodeIfPresent(String.self, forKey: .presetLogoID)
        self.sfSymbolName = try c.decodeIfPresent(String.self, forKey: .sfSymbolName)
    }
}

public struct MailRecipientInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let address: String
    public let name: String
    public let isCC: Bool

    public init(address: String, name: String = "", isCC: Bool = false) {
        self.address = address
        self.name = name
        self.isCC = isCC
        self.id = "\(isCC ? "cc" : "to"):\(address.lowercased())"
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? address : trimmed
    }

    public var formattedDisplay: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare(address) == .orderedSame {
            return address
        }
        if let atIndex = address.firstIndex(of: "@"),
           trimmed.caseInsensitiveCompare(String(address[..<atIndex])) == .orderedSame {
            return address
        }
        return "\(trimmed) <\(address)>"
    }
}

public struct MailContactSuggestion: Identifiable, Hashable, Sendable {
    public var id: String { address.lowercased() }
    public let address: String
    public let name: String
    public let frequency: Int

    public init(address: String, name: String = "", frequency: Int = 1) {
        self.address = address
        self.name = name
        self.frequency = frequency
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? address : trimmed
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
    public let sourceEmlxPath: String?
    public let sourceByteRange: Range<Int>?
    public let sourceTransferEncoding: String?

    public init(
        id: String = UUID().uuidString,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        localFileURL: URL? = nil,
        inlineData: Data? = nil,
        sourceEmlxPath: String? = nil,
        sourceByteRange: Range<Int>? = nil,
        sourceTransferEncoding: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.localFileURL = localFileURL
        self.inlineData = inlineData
        self.sourceEmlxPath = sourceEmlxPath
        self.sourceByteRange = sourceByteRange
        self.sourceTransferEncoding = sourceTransferEncoding
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    public var fileExtension: String {
        (filename as NSString).pathExtension.lowercased()
    }
}

public enum MailBodyLoadStatus: String, Sendable, Equatable {
    case ready
    case missing
    case failed
}

public struct ParsedMailBody: Sendable {
    public let plainText: String
    public let rawHTML: String?
    public let verificationCode: String?
    public let sourcePath: String?
    public let sourceModifiedAt: Date?
    public let attachments: [MailAttachment]
    public let loadStatus: MailBodyLoadStatus

    public init(
        plainText: String,
        rawHTML: String? = nil,
        verificationCode: String? = nil,
        sourcePath: String? = nil,
        sourceModifiedAt: Date? = nil,
        attachments: [MailAttachment] = [],
        loadStatus: MailBodyLoadStatus = .ready
    ) {
        self.plainText = plainText
        self.rawHTML = rawHTML
        self.verificationCode = verificationCode
        self.sourcePath = sourcePath
        self.sourceModifiedAt = sourceModifiedAt
        self.attachments = attachments
        self.loadStatus = loadStatus
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
    public let isError: Bool

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        isError: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isError = isError
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

    private enum CodingKeys: String, CodingKey {
        case authMode, chatGPTModel, cliProvider, cliCustomPath, cliModelOverride, oauth, baseURL, apiKey, model, maskSensitiveData
    }

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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.authMode = try c.decodeIfPresent(AIAuthMode.self, forKey: .authMode) ?? .chatGPT
        self.chatGPTModel = try c.decodeIfPresent(String.self, forKey: .chatGPTModel)
        self.cliProvider = try c.decodeIfPresent(SubscriptionCLIProvider.self, forKey: .cliProvider) ?? .antigravity
        self.cliCustomPath = try c.decodeIfPresent(String.self, forKey: .cliCustomPath) ?? ""
        self.cliModelOverride = try c.decodeIfPresent(String.self, forKey: .cliModelOverride) ?? ""
        self.oauth = try c.decodeIfPresent(OAuthProviderConfig.self, forKey: .oauth) ?? OAuthProviderConfig()
        self.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? "http://localhost:11434/v1"
        // Legacy plaintext `apiKey` is decoded only to support one-time migration into Keychain.
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? "qwen2.5:14b"
        self.maskSensitiveData = try c.decodeIfPresent(Bool.self, forKey: .maskSensitiveData) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(authMode, forKey: .authMode)
        try c.encodeIfPresent(chatGPTModel, forKey: .chatGPTModel)
        try c.encode(cliProvider, forKey: .cliProvider)
        try c.encode(cliCustomPath, forKey: .cliCustomPath)
        try c.encode(cliModelOverride, forKey: .cliModelOverride)
        try c.encode(oauth, forKey: .oauth)
        try c.encode(baseURL, forKey: .baseURL)
        // Never persist plaintext API keys into UserDefaults / JSON preferences.
        try c.encode(model, forKey: .model)
        try c.encode(maskSensitiveData, forKey: .maskSensitiveData)
    }

    /// Keychain account identifier scoped to the API endpoint host so switching providers never leaks keys across hosts.
    public static func apiKeyKeychainAccount(for baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            if let port = url.port {
                return "api-key-\(host)-\(port)"
            }
            return "api-key-\(host)"
        }
        return "api-key-default"
    }
}
