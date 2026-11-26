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
    /// Pre-parsed rule snapshot to avoid repeatedly splitting/encoding `customKeywords` across a batch.
    public struct PreparedRules: Sendable {
        let isEnabled: Bool
        let enabledTags: Set<MailSmartTag>
        let customStrings: [MailSmartTag: [String]]
        let customBytes: [MailSmartTag: [[UInt8]]]
        let customFastPathSafe: [MailSmartTag: Bool]
        let hasCustom: Bool

        public init(settings: MailTagSettings) {
            self.isEnabled = settings.isEnabled
            var enabled: Set<MailSmartTag> = []
            var stringsMap: [MailSmartTag: [String]] = [:]
            var bytesMap: [MailSmartTag: [[UInt8]]] = [:]
            var safeMap: [MailSmartTag: Bool] = [:]
            var anyCustom = false
            for tag in MailSmartTag.allCases {
                if settings.isTagEnabled(tag) {
                    enabled.insert(tag)
                }
                let list = settings.customKeywordList(for: tag)
                if !list.isEmpty {
                    anyCustom = true
                    stringsMap[tag] = list
                    let allSafe = list.allSatisfy { MailTagClassifier.isASCIIOrCJKSafe($0) }
                    safeMap[tag] = allSafe
                    if allSafe {
                        bytesMap[tag] = MailTagClassifier.encodeKeywords(list)
                    }
                }
            }
            self.enabledTags = enabled
            self.customStrings = stringsMap
            self.customBytes = bytesMap
            self.customFastPathSafe = safeMap
            self.hasCustom = anyCustom
        }
    }

    public static func classify(
        _ message: MailMessageSummary,
        settings: MailTagSettings = MailTagSettings()
    ) -> [MailSmartTag] {
        classify(
            subject: message.subject,
            senderName: message.senderName,
            senderAddress: message.senderAddress,
            prepared: PreparedRules(settings: settings)
        )
    }

    public static func classify(
        _ message: MailMessageSummary,
        prepared: PreparedRules
    ) -> [MailSmartTag] {
        classify(
            subject: message.subject,
            senderName: message.senderName,
            senderAddress: message.senderAddress,
            prepared: prepared
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
        classify(
            subject: subject,
            senderName: senderName,
            senderAddress: senderAddress,
            prepared: PreparedRules(settings: settings)
        )
    }

    public static func classify(
        subject: String,
        senderName: String,
        senderAddress: String,
        prepared: PreparedRules
    ) -> [MailSmartTag] {
        guard prepared.isEnabled else { return [] }

        // Only use the zero-allocation UTF-8 byte matcher when inputs consist strictly of
        // ASCII + CJK Unified Ideographs (U+4000..U+9FFF) — zero combining marks, zero canonical
        // decompositions, and zero case-folding ambiguities. Any other Unicode falls back to exact
        // Foundation/Swift `String.lowercased()` + `String.contains` semantics.
        guard let subjBytes = fastPathLowercasedUTF8(subject),
              let addrBytes = fastPathLowercasedUTF8(senderAddress),
              let nameBytes = fastPathLowercasedUTF8(senderName) else {
            return classifyUnicodeExact(
                subject: subject,
                senderName: senderName,
                senderAddress: senderAddress,
                prepared: prepared
            )
        }

        var combinedBytes: [UInt8] = []
        combinedBytes.reserveCapacity(subjBytes.count + nameBytes.count + addrBytes.count + 2)
        combinedBytes.append(contentsOf: subjBytes)
        combinedBytes.append(0x20)
        combinedBytes.append(contentsOf: nameBytes)
        combinedBytes.append(0x20)
        combinedBytes.append(contentsOf: addrBytes)

        var lazyCombinedString: String?
        func matchesCustom(_ tag: MailSmartTag) -> Bool {
            guard prepared.hasCustom else { return false }
            if prepared.customFastPathSafe[tag] == true, let kwBytes = prepared.customBytes[tag] {
                return matchesAnyUTF8(combinedBytes, kwBytes)
            }
            guard let kwStrings = prepared.customStrings[tag], !kwStrings.isEmpty else { return false }
            if lazyCombinedString == nil {
                lazyCombinedString = "\(subject.lowercased()) \(senderName.lowercased()) \(senderAddress.lowercased())"
            }
            return matchesAnyString(lazyCombinedString!, kwStrings)
        }

        var tags: [MailSmartTag] = []
        tags.reserveCapacity(2)

        // 1. Verification / Security Code
        if prepared.enabledTags.contains(.verification) {
            if matchesAnyUTF8(subjBytes, verificationKeywordBytes) || matchesCustom(.verification) {
                tags.append(.verification)
            }
        }

        // 2. Billing / Invoice / Payment
        if prepared.enabledTags.contains(.billing) {
            if matchesAnyUTF8(combinedBytes, billingKeywordBytes) || matchesCustom(.billing) {
                tags.append(.billing)
            }
        }

        // 3. Order & Logistics
        if tags.count < 2 && prepared.enabledTags.contains(.orderLogistics) {
            if matchesAnyUTF8(combinedBytes, orderLogisticsKeywordBytes) || matchesCustom(.orderLogistics) {
                tags.append(.orderLogistics)
            }
        }

        // 4. Meeting & Calendar
        if tags.count < 2 && prepared.enabledTags.contains(.meeting) {
            if matchesAnyUTF8(subjBytes, meetingKeywordBytes) || matchesCustom(.meeting) {
                tags.append(.meeting)
            }
        }

        // 5. Promotion / Newsletter
        if tags.count < 2 && prepared.enabledTags.contains(.promotion) {
            if matchesAnyUTF8(subjBytes, promotionKeywordBytes) || matchesCustom(.promotion) {
                tags.append(.promotion)
            }
        }

        // 6. System Notification / Security / Welcome / Support
        if tags.count < 2 && prepared.enabledTags.contains(.notification) {
            let hasNotifyKeyword = matchesAnyUTF8(subjBytes, notificationKeywordBytes)
            let matchedCustom = matchesCustom(.notification)
            if matchedCustom || hasNotifyKeyword || (tags.isEmpty && matchesAnyUTF8(addrBytes, automatedSenderKeywordBytes)) {
                if !tags.contains(.promotion) {
                    tags.append(.notification)
                }
            }
        }

        return tags
    }

    /// Exact Swift `String.contains` fallback preserving canonical Unicode equivalence (NFC/NFD)
    /// and extended grapheme cluster boundaries (e.g. combining accents, Kana voiced marks, `İ`).
    private static func classifyUnicodeExact(
        subject: String,
        senderName: String,
        senderAddress: String,
        prepared: PreparedRules
    ) -> [MailSmartTag] {
        let subj = subject.lowercased()
        let addrLower = senderAddress.lowercased()
        let sender = "\(senderName.lowercased()) \(addrLower)"
        let combined = "\(subj) \(sender)"

        var tags: [MailSmartTag] = []
        tags.reserveCapacity(2)

        if prepared.enabledTags.contains(.verification) {
            if matchesAnyString(subj, verificationKeywords)
                || (prepared.hasCustom && matchesAnyString(combined, prepared.customStrings[.verification] ?? [])) {
                tags.append(.verification)
            }
        }
        if prepared.enabledTags.contains(.billing) {
            if matchesAnyString(combined, billingKeywords)
                || (prepared.hasCustom && matchesAnyString(combined, prepared.customStrings[.billing] ?? [])) {
                tags.append(.billing)
            }
        }
        if tags.count < 2 && prepared.enabledTags.contains(.orderLogistics) {
            if matchesAnyString(combined, orderLogisticsKeywords)
                || (prepared.hasCustom && matchesAnyString(combined, prepared.customStrings[.orderLogistics] ?? [])) {
                tags.append(.orderLogistics)
            }
        }
        if tags.count < 2 && prepared.enabledTags.contains(.meeting) {
            if matchesAnyString(subj, meetingKeywords)
                || (prepared.hasCustom && matchesAnyString(combined, prepared.customStrings[.meeting] ?? [])) {
                tags.append(.meeting)
            }
        }
        if tags.count < 2 && prepared.enabledTags.contains(.promotion) {
            if matchesAnyString(subj, promotionKeywords)
                || (prepared.hasCustom && matchesAnyString(combined, prepared.customStrings[.promotion] ?? [])) {
                tags.append(.promotion)
            }
        }
        if tags.count < 2 && prepared.enabledTags.contains(.notification) {
            let hasNotifyKeyword = matchesAnyString(subj, notificationKeywords)
            let matchedCustom = prepared.hasCustom && matchesAnyString(combined, prepared.customStrings[.notification] ?? [])
            if matchedCustom || hasNotifyKeyword || (tags.isEmpty && matchesAnyString(addrLower, automatedSenderKeywords)) {
                if !tags.contains(.promotion) {
                    tags.append(.notification)
                }
            }
        }
        return tags
    }

    private static func matchesAnyString(_ text: String, _ keywords: [String]) -> Bool {
        for kw in keywords where !kw.isEmpty {
            if text.contains(kw) {
                return true
            }
        }
        return false
    }

    /// Returns `true` iff every UTF-8 sequence is ASCII (`0x00..0x7F`, excluding CR) or a 3-byte
    /// CJK ideograph (`0xE4..0xE9`, i.e. `U+4000..U+9FFF`), which have no combining marks or decompositions.
    private static func isASCIIOrCJKSafe(_ text: String) -> Bool {
        for b in text.utf8 {
            if b < 0x80 {
                if b == 0x0D { return false }
                continue
            }
            if b >= 0x80 && b <= 0xBF {
                continue
            }
            if b >= 0xE4 && b <= 0xE9 {
                continue
            }
            return false
        }
        return true
    }

    /// Lowercases ASCII in-place directly on UTF-8 bytes when safe; returns `nil` for any text
    /// containing non-CJK Unicode so the caller uses exact Swift grapheme-aware matching.
    private static func fastPathLowercasedUTF8(_ text: String) -> [UInt8]? {
        var bytes = Array(text.utf8)
        for i in bytes.indices {
            let b = bytes[i]
            if b < 0x80 {
                if b == 0x0D { return nil }
                if b >= 0x41 && b <= 0x5A {
                    bytes[i] = b &+ 32
                }
            } else if b >= 0x80 && b <= 0xBF {
                continue
            } else if b >= 0xE4 && b <= 0xE9 {
                continue
            } else {
                return nil
            }
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
