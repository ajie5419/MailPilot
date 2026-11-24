import Foundation

/// Extracts and normalizes a sender's registrable brand domain for logo lookup,
/// excluding personal webmail providers so individuals keep their initial avatars.
public enum SenderDomainHelper {
    private static let personalEmailDomains: Set<String> = [
        "gmail.com", "googlemail.com",
        "icloud.com", "me.com", "mac.com",
        "outlook.com", "hotmail.com", "live.com", "msn.com",
        "yahoo.com", "yahoo.co.jp", "ymail.com",
        "163.com", "126.com", "yeah.net", "vip.163.com",
        "qq.com", "foxmail.com", "vip.qq.com",
        "sina.com", "sina.cn", "sohu.com", "aliyun.com.personal",
        "proton.me", "protonmail.com", "pm.me",
        "fastmail.com", "zoho.com", "aol.com"
    ]

    private static let multiPartTLDs: Set<String> = [
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "co.uk", "org.uk", "ac.uk",
        "co.jp", "ne.jp", "or.jp",
        "com.hk", "com.tw", "com.sg", "com.au", "co.kr"
    ]

    /// Returns the normalized root domain (e.g. `service@intl.paypal.com` -> `paypal.com`),
    /// or `nil` for personal free-mail addresses.
    public static func extractBrandDomain(from email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let atIdx = trimmed.lastIndex(of: "@") else { return nil }
        let rawHost = String(trimmed[trimmed.index(after: atIdx)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "> "))
        guard rawHost.contains("."), !rawHost.contains(" ") else { return nil }

        let root = registrableDomain(from: rawHost)
        if personalEmailDomains.contains(rawHost) || personalEmailDomains.contains(root) {
            return nil
        }
        return root
    }

    private static func registrableDomain(from host: String) -> String {
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return host }

        let lastTwo = "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
        if multiPartTLDs.contains(lastTwo), parts.count >= 3 {
            return "\(parts[parts.count - 3]).\(lastTwo)"
        }
        return lastTwo
    }
}
