import Foundation

public enum MailSmartTag: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case verification = "验证码"
    case billing = "账单"
    case orderLogistics = "订单与物流"
    case meeting = "会议"
    case promotion = "推广"
    case notification = "通知"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .verification: return "key.fill"
        case .billing: return "doc.text"
        case .orderLogistics: return "box.truck"
        case .meeting: return "calendar"
        case .promotion: return "tag"
        case .notification: return "bell"
        }
    }

    public var descriptionText: String {
        switch self {
        case .verification: return "登录验证码、动态码、Passcode、2FA"
        case .billing: return "发票、收据、扣款、续费、退款、银行卡变动"
        case .orderLogistics: return "订单确认、发货通知、快递物流、包裹派送"
        case .meeting: return "会议邀请、纪要、评审、Teams / Zoom 日程"
        case .promotion: return "营销活动、折扣促销、订阅周刊"
        case .notification: return "账户激活、登录告警、欢迎邮件、工单与系统提醒"
        }
    }
}

public struct MailTagSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var enabledTagIDs: Set<String>
    /// Optional comma-separated user keywords per tag rawValue.
    public var customKeywords: [String: String]

    public init(
        isEnabled: Bool = true,
        enabledTagIDs: Set<String> = Set(MailSmartTag.allCases.map(\.rawValue)),
        customKeywords: [String: String] = [:]
    ) {
        self.isEnabled = isEnabled
        self.enabledTagIDs = enabledTagIDs
        self.customKeywords = customKeywords
    }

    public func isTagEnabled(_ tag: MailSmartTag) -> Bool {
        enabledTagIDs.contains(tag.rawValue)
    }

    public func customKeywordList(for tag: MailSmartTag) -> [String] {
        guard let raw = customKeywords[tag.rawValue] else { return [] }
        return raw
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}

/// Zero-latency local classifier that assigns up to 2 semantic tags per email
/// based on subject, sender name, sender address, and user-configured rules.
public enum MailTagClassifier {
    public static func classify(
        _ message: MailMessageSummary,
        settings: MailTagSettings = MailTagSettings()
    ) -> [MailSmartTag] {
        classify(
            subject: message.subject,
            senderName: message.senderName,
            senderAddress: message.senderAddress,
            settings: settings
        )
    }

    private static let verificationKeywords = [
        "验证码", "校验码", "动态码", "登录码", "安全码", "通行密钥", "登录方式",
        "verification code", "security code", "sign-in code", "one-time", "otp", "passcode", "2fa"
    ]
    private static let billingKeywords = [
        "账单", "发票", "收据", "扣款", "付款", "支付成功", "续费", "对账单", "余额", "退款", "移除了一张卡", "银行卡",
        "invoice", "receipt", "billing", "payment", "statement", "charged", "refund", "subscription", "order number", "renew"
    ]
    private static let orderLogisticsKeywords = [
        "订单", "发货", "物流", "快递", "运单", "签收", "派送", "包裹", "揽收", "已出库", "16688", "apple store",
        "your order", "processing your order", "shipped", "shipping", "delivery", "tracking", "package", "dispatched"
    ]
    private static let meetingKeywords = [
        "会议", "纪要", "日程", "评审", "邀请", "例会", "议程",
        "meeting", "calendar", "invite", "invitation", "recurrent", "teams", "zoom", "webinar"
    ]
    private static let promotionKeywords = [
        "优惠", "促销", "折扣", "特惠", "限时", "双11", "双十一", "新观点", "订阅", "周刊",
        "black friday", "sale", "discount", "off ", "promo", "deal", "newsletter", "digest"
    ]
    private static let automatedSenderKeywords = [
        "noreply", "no-reply", "donotreply", "do-not-reply",
        "notify", "notification", "notice", "service@", "support@",
        "info@", "billing@", "admin@", "hello@", "team@", "mailer@", "alert", "system"
    ]
    private static let notificationKeywords = [
        "通知", "提醒", "告警", "变配", "状态", "登录", "更新", "确认", "激活", "欢迎", "工单", "密码", "过期",
        "notification", "alert", "reminder", "notice", "status", "account", "shared some",
        "login", "sign in", "sign-in", "failed", "welcome", "portal", "activation", "activate",
        "verify", "confirm", "password", "reset", "security", "ticket", "expir", "suspended"
    ]

    private static let verificationKeywordBytes = encodeKeywords(verificationKeywords)
    private static let billingKeywordBytes = encodeKeywords(billingKeywords)
    private static let orderLogisticsKeywordBytes = encodeKeywords(orderLogisticsKeywords)
    private static let meetingKeywordBytes = encodeKeywords(meetingKeywords)
    private static let promotionKeywordBytes = encodeKeywords(promotionKeywords)
    private static let automatedSenderKeywordBytes = encodeKeywords(automatedSenderKeywords)
    private static let notificationKeywordBytes = encodeKeywords(notificationKeywords)

    private static func encodeKeywords(_ keywords: [String]) -> [[UInt8]] {
        keywords.compactMap { kw in
            let bytes = Array(kw.utf8)
            return bytes.isEmpty ? nil : bytes
        }
    }

    public static func classify(
        subject: String,
        senderName: String,
        senderAddress: String,
        settings: MailTagSettings = MailTagSettings()
    ) -> [MailSmartTag] {
        guard settings.isEnabled else { return [] }

        let subjBytes = lowercasedUTF8Bytes(subject)
        let addrBytes = lowercasedUTF8Bytes(senderAddress)
        let nameBytes = lowercasedUTF8Bytes(senderName)
        var combinedBytes: [UInt8] = []
        combinedBytes.reserveCapacity(subjBytes.count + nameBytes.count + addrBytes.count + 2)
        combinedBytes.append(contentsOf: subjBytes)
        combinedBytes.append(0x20)
        combinedBytes.append(contentsOf: nameBytes)
        combinedBytes.append(0x20)
        combinedBytes.append(contentsOf: addrBytes)
        let hasCustom = !settings.customKeywords.isEmpty

        var tags: [MailSmartTag] = []
        tags.reserveCapacity(2)

        // 1. Verification / Security Code
        if settings.isTagEnabled(.verification) {
            if matchesAnyUTF8(subjBytes, verificationKeywordBytes)
                || (hasCustom && matchesAnyUTF8(combinedBytes, encodeKeywords(settings.customKeywordList(for: .verification)))) {
                tags.append(.verification)
            }
        }

        // 2. Billing / Invoice / Payment
        if settings.isTagEnabled(.billing) {
            if matchesAnyUTF8(combinedBytes, billingKeywordBytes)
                || (hasCustom && matchesAnyUTF8(combinedBytes, encodeKeywords(settings.customKeywordList(for: .billing)))) {
                tags.append(.billing)
            }
        }

        // 3. Order & Logistics
        if tags.count < 2 && settings.isTagEnabled(.orderLogistics) {
            if matchesAnyUTF8(combinedBytes, orderLogisticsKeywordBytes)
                || (hasCustom && matchesAnyUTF8(combinedBytes, encodeKeywords(settings.customKeywordList(for: .orderLogistics)))) {
                tags.append(.orderLogistics)
            }
        }

        // 4. Meeting & Calendar
        if tags.count < 2 && settings.isTagEnabled(.meeting) {
            if matchesAnyUTF8(subjBytes, meetingKeywordBytes)
                || (hasCustom && matchesAnyUTF8(combinedBytes, encodeKeywords(settings.customKeywordList(for: .meeting)))) {
                tags.append(.meeting)
            }
        }

        // 5. Promotion / Newsletter
        if tags.count < 2 && settings.isTagEnabled(.promotion) {
            if matchesAnyUTF8(subjBytes, promotionKeywordBytes)
                || (hasCustom && matchesAnyUTF8(combinedBytes, encodeKeywords(settings.customKeywordList(for: .promotion)))) {
                tags.append(.promotion)
            }
        }

        // 6. System Notification / Security / Welcome / Support
        if tags.count < 2 && settings.isTagEnabled(.notification) {
            let hasNotifyKeyword = matchesAnyUTF8(subjBytes, notificationKeywordBytes)
            let matchedCustom = hasCustom && matchesAnyUTF8(combinedBytes, encodeKeywords(settings.customKeywordList(for: .notification)))
            if matchedCustom || hasNotifyKeyword || (tags.isEmpty && matchesAnyUTF8(addrBytes, automatedSenderKeywordBytes)) {
                if !tags.contains(.promotion) {
                    tags.append(.notification)
                }
            }
        }

        return tags
    }

    /// Lowercases ASCII in-place directly on UTF-8 bytes; falls back to full Unicode `lowercased()`
    /// only when non-ASCII Latin/script characters are present (CJK bytes pass through untouched).
    private static func lowercasedUTF8Bytes(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        var needsUnicodeLowercase = false
        for i in bytes.indices {
            let b = bytes[i]
            if b >= 0x41 && b <= 0x5A {
                bytes[i] = b &+ 32
            } else if b >= 0xC0 && !(b >= 0xE3 && b <= 0xE9) {
                // Non-CJK multi-byte UTF-8 lead byte (Latin Extended, Greek, Cyrillic, Fullwidth Latin, etc.).
                needsUnicodeLowercase = true
                break
            }
        }
        if needsUnicodeLowercase {
            return Array(text.lowercased().utf8)
        }
        return bytes
    }

    private static func matchesAnyUTF8(_ haystack: [UInt8], _ needles: [[UInt8]]) -> Bool {
        let hCount = haystack.count
        guard hCount > 0 else { return false }
        return haystack.withUnsafeBufferPointer { hBuf in
            guard let hBase = hBuf.baseAddress else { return false }
            for needle in needles {
                let nCount = needle.count
                if nCount == 0 || nCount > hCount { continue }
                let first = needle[0]
                let limit = hCount - nCount
                if nCount == 1 {
                    if memchr(hBase, Int32(first), hCount) != nil {
                        return true
                    }
                    continue
                }
                let matched = needle.withUnsafeBufferPointer { nBuf -> Bool in
                    guard let nBase = nBuf.baseAddress else { return false }
                    var offset = 0
                    while offset <= limit {
                        guard let found = memchr(hBase.advanced(by: offset), Int32(first), limit - offset + 1) else {
                            return false
                        }
                        let pos = hBase.distance(to: found.assumingMemoryBound(to: UInt8.self))
                        if memcmp(hBase.advanced(by: pos + 1), nBase.advanced(by: 1), nCount - 1) == 0 {
                            return true
                        }
                        offset = pos + 1
                    }
                    return false
                }
                if matched {
                    return true
                }
            }
            return false
        }
    }
}
