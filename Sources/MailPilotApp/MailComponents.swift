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
        let fillOpacity: Double = isSelected ? 0.075 : (hoverState.isHovered ? 0.032 : 0)
        let borderOpacity: Double = isSelected ? 0.065 : 0

        VStack(spacing: 0) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(fillOpacity))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 0.75)
                )
                .padding(.horizontal, 8)
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
                    .fill(Color.primary.opacity(hoverState.isHovered ? 0 : 0.08))
                    .frame(height: 0.75)
                    .padding(.leading, 60)
                    .padding(.trailing, 18)
            }
        }
    }
}

struct MessageRowView: View, Equatable {
    let message: MailMessageSummary
    let tags: [MailSmartTag]
    let accountBadge: String?
    let accountEmail: String?
    let accountCustomIconPath: String?
    let accountPresetLogoID: String?
    let accountSFSymbolName: String?
    let accountColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SenderAvatarView(name: message.displaySender, email: message.senderAddress, size: 32)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !message.isRead {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                    }
                    Text(message.displaySender)
                        .font(.subheadline.weight(message.isRead ? .medium : .semibold))
                        .foregroundStyle(message.isRead ? Color.primary.opacity(0.82) : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(Self.formatListTimestamp(message.dateReceived))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(Self.formatFullTimestamp(message.dateReceived))
                }

                Text(message.subject)
                    .font(.callout.weight(message.isRead ? .regular : .medium))
                    .foregroundStyle(message.isRead ? .secondary : .primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if let primaryTag = tags.first {
                        SmartTagPill(tag: primaryTag)
                        if tags.count > 1 {
                            let extraTags = Array(tags.dropFirst())
                            Text("+\(extraTags.count)")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(.separator.opacity(0.45), lineWidth: 0.7)
                                )
                                .fixedSize(horizontal: true, vertical: false)
                                .help(extraTags.map(\.rawValue).joined(separator: "、"))
                        }
                    } else {
                        Text(message.mailboxName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if let accountBadge {
                        AccountBadgePill(
                            accountID: message.accountID,
                            label: accountBadge,
                            email: accountEmail,
                            customIconPath: accountCustomIconPath,
                            presetLogoID: accountPresetLogoID,
                            sfSymbolName: accountSFSymbolName,
                            fallbackColor: accountColor
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
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
            Color(red: 0.28, green: 0.52, blue: 0.88),
            Color(red: 0.48, green: 0.38, blue: 0.84),
            Color(red: 0.16, green: 0.62, blue: 0.58),
            Color(red: 0.82, green: 0.45, blue: 0.26),
            Color(red: 0.74, green: 0.34, blue: 0.54),
            Color(red: 0.32, green: 0.58, blue: 0.36)
        ]
        let hash = abs(name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return palette[hash % palette.count]
    }

    var body: some View {
        if let brandImage = avatarLoader.image(for: email) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(Color.white)
                Image(nsImage: brandImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.14)
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.separator.opacity(0.45), lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        } else {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                Text(initial)
                    .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
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
        VStack(spacing: 22) {
            // Brand Mark + Headline
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color.indigo],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 56, height: 56)
                        .shadow(color: Color.accentColor.opacity(0.28), radius: 10, y: 5)

                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 6) {
                    Text("连接 macOS 原生邮件")
                        .font(.title2.weight(.semibold))
                    Text("只需授予一次「完全磁盘访问权限」，MailPilot 即可零同步故障地接管阅读与 AI 助理。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Feature Guarantees
            VStack(alignment: .leading, spacing: 12) {
                guaranteeRow(
                    icon: "lock.fill",
                    color: .blue,
                    title: "严格只读本地索引",
                    subtitle: "仅以只读模式读取系统邮件库，绝不修改或损坏数据库"
                )
                guaranteeRow(
                    icon: "bolt.horizontal.fill",
                    color: .green,
                    title: "原生 Mail.app 驱动收信与推送",
                    subtitle: "零断连、支持休眠唤醒与多账号稳定同步"
                )
                guaranteeRow(
                    icon: "checkmark.seal.fill",
                    color: .purple,
                    title: "写操作安全委托",
                    subtitle: "标记已读、旗标与回复草稿均通过官方通道交由 Mail.app 执行"
                )
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator.opacity(0.45), lineWidth: 0.7)
            )

            // Action Hierarchy
            VStack(spacing: 12) {
                Button {
                    viewModel.openFullDiskAccessSettings()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape.fill")
                        Text("打开「完全磁盘访问权限」并勾选 MailPilot")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(spacing: 16) {
                    Button {
                        viewModel.connectToNativeMail()
                    } label: {
                        Label("我已勾选，重新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)

                    Text("·")
                        .foregroundStyle(.quaternary)

                    Button {
                        viewModel.settingsTab = .ai
                        viewModel.showSettings = true
                    } label: {
                        Label("先配置 AI 订阅", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func guaranteeRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
