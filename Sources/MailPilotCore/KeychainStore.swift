import Foundation
import Security

public struct OAuthTokenBundle: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let accountLabel: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        accountLabel: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountLabel = accountLabel
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60)
    }
}

/// Stores OAuth tokens and secrets in macOS Keychain rather than plaintext UserDefaults.
public enum KeychainStore {
    private static let serviceName = "com.mailpilot.app.ai-auth"

    public static func save(_ data: Data, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        // Preserve the old credential if an update fails (important for rotating refresh tokens).
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.osStatus(updateStatus) }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
    }

    public static func load(account: String) -> Data? {
        try? loadChecked(account: account)
    }

    public static func loadChecked(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        return result as? Data
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func saveToken(_ bundle: OAuthTokenBundle, account: String) throws {
        let data = try JSONEncoder().encode(bundle)
        try save(data, account: account)
    }

    public static func loadToken(account: String) -> OAuthTokenBundle? {
        guard let data = load(account: account) else { return nil }
        return try? JSONDecoder().decode(OAuthTokenBundle.self, from: data)
    }
}

public enum KeychainError: LocalizedError, Sendable {
    case osStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            return "macOS 钥匙串操作失败（状态码 \(status)）"
        }
    }
}
