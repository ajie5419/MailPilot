import AppKit
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

private final class RowHoverState: ObservableObject {
    @Published var isHovered = false
}

struct MessageListRowContainer<RowContent: View, MenuContent: View>: View {
    let isSelected: Bool
    let showBottomDivider: Bool
    let onTap: () -> Void
    @ViewBuilder let content: () -> RowContent
    @ViewBuilder let contextMenu: () -> MenuContent

    @StateObject private var hoverState = RowHoverState()

    var body: some View {
        let bgColor: Color = isSelected
            ? Color.accentColor.opacity(0.13)
            : (hoverState.isHovered ? Color.primary.opacity(0.035) : Color.clear)

        VStack(spacing: 0) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(bgColor)
                )
                .padding(.horizontal, 7)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .onHover { hovering in
                    if hoverState.isHovered != hovering {
                        hoverState.isHovered = hovering
                    }
                }
                .contextMenu {
                    contextMenu()
                }

            if showBottomDivider {
                Rectangle()
                    .fill(Color.primary.opacity(hoverState.isHovered ? 0 : 0.065))
                    .frame(height: 0.5)
                    .padding(.leading, 28)
                    .padding(.trailing, 14)
            }
        }
    }
}

struct MessageRowView: View, Equatable {
    let message: MailMessageSummary
    let snippet: String?
    let tags: [MailSmartTag]
    let accountBadge: String?
    let accountEmail: String?
    let accountCustomIconPath: String?
    let accountPresetLogoID: String?
    let accountSFSymbolName: String?
    let accountColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(message.isRead ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5.5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(message.displaySender)
                        .font(.system(size: 13.5, weight: message.isRead ? .semibold : .bold))
                        .foregroundStyle(message.isRead ? Color.primary.opacity(0.9) : Color.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.orange)
                    }

                    Text(Self.formatListTimestamp(message.dateReceived))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(Self.formatFullTimestamp(message.dateReceived))
                }

                Text(message.subject)
                    .font(.system(size: 12.5, weight: message.isRead ? .regular : .medium))
                    .foregroundStyle(message.isRead ? Color.secondary : Color.primary.opacity(0.88))
                    .lineLimit(1)

                if let snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary.opacity(0.82))
                        .lineLimit(1)
                }

                if accountBadge != nil || !tags.isEmpty || snippet == nil {
                    HStack(spacing: 5) {
                        if let accountBadge {
                            AccountLogoView(
                                accountID: message.accountID,
                                email: accountEmail,
                                customIconPath: accountCustomIconPath,
                                presetLogoID: accountPresetLogoID,
                                sfSymbolName: accountSFSymbolName,
                                fallbackColor: accountColor,
                                size: 13
                            )
                            Text(accountBadge)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let primaryTag = tags.first {
                            if accountBadge != nil {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.quaternary)
                            }
                            Text(Self.compactTagTitle(primaryTag))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Self.subtleTagColor(primaryTag))
                                .lineLimit(1)
                            if tags.count > 1 {
                                Text("+\(tags.count - 1)")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .help(tags.dropFirst().map(\.rawValue).joined(separator: "、"))
                            }
                        } else if accountBadge == nil && snippet == nil {
                            Text(message.mailboxName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.top, 1.5)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static func compactTagTitle(_ tag: MailSmartTag) -> String {
        switch tag {
        case .orderLogistics: return "订单"
        default: return tag.rawValue
        }
    }

    private static func subtleTagColor(_ tag: MailSmartTag) -> Color {
        switch tag {
        case .verification: return Color(red: 0.36, green: 0.32, blue: 0.76)
        case .billing: return Color(red: 0.56, green: 0.38, blue: 0.04)
        case .orderLogistics: return Color(red: 0.66, green: 0.28, blue: 0.10)
        case .meeting: return Color(red: 0.14, green: 0.42, blue: 0.76)
        case .promotion: return Color(red: 0.58, green: 0.22, blue: 0.44)
        case .notification: return .secondary
        }
    }

    private static let time24Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let sameYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd"
        return f
    }()

    private static let crossYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    private static let fullTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    private static let chineseWeekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    private static func formatListTimestamp(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.autoupdatingCurrent
        if cal.isDateInToday(date) {
            return time24Formatter.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return "昨天"
        }
        let startOfDate = cal.startOfDay(for: date)
        let startOfNow = cal.startOfDay(for: now)
        if let days = cal.dateComponents([.day], from: startOfDate, to: startOfNow).day,
           days >= 2 && days < 7 {
            let weekdayIndex = cal.component(.weekday, from: date) - 1
            if chineseWeekdays.indices.contains(weekdayIndex) {
                return chineseWeekdays[weekdayIndex]
            }
        }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return sameYearFormatter.string(from: date)
        }
        return crossYearFormatter.string(from: date)
    }

    private static func formatFullTimestamp(_ date: Date) -> String {
        fullTimestampFormatter.string(from: date)
    }
}

struct AccountLogoView: View {
    let accountID: String
    let email: String?
    var customIconPath: String? = nil
    var presetLogoID: String? = nil
    var sfSymbolName: String? = nil
    let fallbackColor: Color
    let size: CGFloat

    @ObservedObject private var avatarLoader = SenderAvatarLoader.shared

    var body: some View {
        if let customImage = avatarLoader.customIcon(at: customIconPath) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(Color.white)
                Image(nsImage: customImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
            )
        } else if let preset = PresetLogoOption.find(presetLogoID) {
            PresetLogoTile(option: preset, size: size)
        } else if let symbol = sfSymbolName, !symbol.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(fallbackColor.opacity(0.18))
                Image(systemName: symbol)
                    .font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(fallbackColor)
            }
            .frame(width: size, height: size)
        } else if accountID.uppercased() == "LOCAL" {
            Image(systemName: "desktopcomputer")
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        } else if let email, let logo = avatarLoader.accountLogo(for: email) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(Color.white)
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.14)
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
            )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(fallbackColor.opacity(0.2))
                Image(systemName: "envelope.fill")
                    .font(.system(size: size * 0.52))
                    .foregroundStyle(fallbackColor)
            }
            .frame(width: size, height: size)
        }
    }
}

struct AccountBadgePill: View {
    let accountID: String
    let label: String
    let email: String?
    var customIconPath: String? = nil
    var presetLogoID: String? = nil
    var sfSymbolName: String? = nil
    let fallbackColor: Color

    var body: some View {
        HStack(spacing: 4) {
            AccountLogoView(
                accountID: accountID,
                email: email,
                customIconPath: customIconPath,
                presetLogoID: presetLogoID,
                sfSymbolName: sfSymbolName,
                fallbackColor: fallbackColor,
                size: 13
            )
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
        )
        .help(email ?? label)
    }
}

struct SmartTagPill: View {
    let tag: MailSmartTag

    private var compactTitle: String {
        switch tag {
        case .orderLogistics: return "订单"
        default: return tag.rawValue
        }
    }

    private var tint: Color {
        switch tag {
        case .verification: return Color(red: 0.48, green: 0.36, blue: 0.85)
        case .billing: return Color(red: 0.78, green: 0.56, blue: 0.12)
        case .orderLogistics: return Color(red: 0.82, green: 0.38, blue: 0.18)
        case .meeting: return Color(red: 0.22, green: 0.48, blue: 0.82)
        case .promotion: return Color(red: 0.68, green: 0.32, blue: 0.52)
        case .notification: return Color.secondary
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: tag.iconName)
                .font(.system(size: 9.5, weight: .medium))
            Text(compactTitle)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 0.7)
        )
        .fixedSize(horizontal: true, vertical: false)
        .help(tag.rawValue)
    }
}

struct SenderAvatarView: View {
    let name: String
    let email: String
    let size: CGFloat

    @ObservedObject private var avatarLoader = SenderAvatarLoader.shared

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    private var tint: Color {
        let palette: [Color] = [
            Color(red: 0.24, green: 0.48, blue: 0.84),
            Color(red: 0.42, green: 0.44, blue: 0.76),
            Color(red: 0.20, green: 0.56, blue: 0.55),
            Color(red: 0.72, green: 0.48, blue: 0.30),
            Color(red: 0.62, green: 0.40, blue: 0.54),
            Color(red: 0.34, green: 0.54, blue: 0.40)
        ]
        let hash = abs(name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return palette[hash % palette.count]
    }

    var body: some View {
        if let brandImage = avatarLoader.image(for: email) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Color.white)
                Image(nsImage: brandImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.14)
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
            )
        } else {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.13))
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
        }
    }
}

struct PermissionGuideView: View {
    let error: MailAccessError
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ZStack {
            // Native macOS behindWindow dark frosted glass HUD canvas
            VisualEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // Subtle warm sunset glow behind the hero icon for depth without sacrificing glass translucency
            ZStack {
                Color.black.opacity(0.36)
                RadialGradient(
                    colors: [BrandPalette.coral.opacity(0.22), Color.clear],
                    center: UnitPoint(x: 0.5, y: 0.22),
                    startRadius: 16,
                    endRadius: 230
                )
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 26)

                // Hero Sunset Coral Origami Crane App Icon + Display Wordmark
                AppBrandIconView(size: 84, showShadow: true)
                    .padding(.bottom, 12)

                Text("MailPilot")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(.white)
                    .shadow(color: Color.black.opacity(0.24), radius: 10, y: 3)

                Text("为 macOS 原生邮件注入 AI 领航能力，\n零同步故障，一切尽在掌控。")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.bottom, 26)

                // Horizontal 3-Column Frosted Glass Capability Bar (Canapé aesthetic)
                HStack(spacing: 0) {
                    capabilityColumn(
                        icon: "lock.shield.fill",
                        iconColor: Color(red: 0.14, green: 0.48, blue: 0.94),
                        title: "严格只读",
                        subtitle: "零损坏风险"
                    )
                    capabilityDivider
                    capabilityColumn(
                        icon: "bolt.horizontal.fill",
                        iconColor: BrandPalette.coral,
                        title: "原生同步",
                        subtitle: "Mail.app 驱动"
                    )
                    capabilityDivider
                    capabilityColumn(
                        icon: "sparkles",
                        iconColor: Color(red: 0.55, green: 0.32, blue: 0.94),
                        title: "AI 领航",
                        subtitle: "摘要 · 翻译"
                    )
                }
                .padding(.vertical, 18)
                .padding(.horizontal, 8)
                .background(
                    Color.white.opacity(0.085),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.9)
                )
                .padding(.bottom, 22)

                Text("只需授予一次完全磁盘访问权限即可开启。")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.bottom, 14)

                // Vibrant Sunset Coral Gradient Primary CTA
                Button {
                    viewModel.openFullDiskAccessSettings()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("授予完全磁盘访问权限")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: 268)
                    .padding(.vertical, 11)
                    .background(
                        BrandPalette.coralButtonGradient,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                    )
                    .shadow(color: BrandPalette.coral.opacity(0.38), radius: 14, y: 6)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)

                // Quiet Secondary Actions
                HStack(spacing: 14) {
                    Button {
                        viewModel.connectToNativeMail()
                    } label: {
                        Label("我已授权，重新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.86))

                    Text("·")
                        .foregroundStyle(.white.opacity(0.32))

                    Button {
                        viewModel.settingsTab = .ai
                        viewModel.showSettings = true
                    } label: {
                        Label("先配置 AI 订阅", systemImage: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.66))
                }
                .font(.system(size: 12, weight: .medium))

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    private func capabilityColumn(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.96))
                    .frame(width: 36, height: 36)
                    .shadow(color: Color.black.opacity(0.18), radius: 5, y: 2)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.60))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var capabilityDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 46)
    }
}
