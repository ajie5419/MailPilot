import AppKit
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

/// Frosted-glass mini inbox hosted inside the menu bar `NSPopover`.
/// Uses zero `@State` (bare `swiftc` builds without SwiftUI macro plugins).
struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: AppViewModel
    let onOpenMain: () -> Void
    let onSelectMessage: (Int64) -> Void
    let onCompose: () -> Void
    let onCheckMail: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var unreadCount: Int {
        viewModel.totalInboxUnreadCount
    }

    private var previewItems: [MailMessageSummary] {
        let cached = viewModel.menuBarUnreadMessages
        if !cached.isEmpty {
            return Array(cached.prefix(5))
        }
        return Array(viewModel.messages.filter { !$0.isRead }.prefix(5))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .opacity(colorScheme == .dark ? 0.35 : 0.45)

            contentSection

            Divider()
                .opacity(colorScheme == .dark ? 0.35 : 0.45)

            footerBar
        }
        .frame(width: 332)
        .tint(BrandPalette.coral)
    }

    private var headerBar: some View {
        HStack(spacing: 9) {
            AppBrandIconView(size: 24, showShadow: false)

            Text("MailPilot")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.primary)

            if unreadCount > 0 {
                Text("\(unreadCount) 未读")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(BrandPalette.coral, in: Capsule())
            } else {
                Text("全部已读")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(BrandPalette.sidebarPillFill(for: colorScheme), in: Capsule())
            }

            Spacer(minLength: 4)

            Button(action: onCompose) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 26, height: 24)
                    .background(BrandPalette.sidebarPillFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("写新邮件")

            Button(action: onCheckMail) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
                    .background(BrandPalette.sidebarPillFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("立即检查新邮件")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var contentSection: some View {
        if viewModel.accessError != nil {
            VStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(BrandPalette.coral)
                Text("需要完全磁盘访问权限")
                    .font(.callout.weight(.semibold))
                Text("授权后即可在这里即时预览收件箱未读邮件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("前往主窗口授权", action: onOpenMain)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        } else if previewItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(BrandPalette.coral.opacity(0.85))
                Text("收件箱很清爽")
                    .font(.callout.weight(.semibold))
                Text("当前没有待处理的未读邮件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            VStack(spacing: 4) {
                ForEach(previewItems) { msg in
                    Button {
                        onSelectMessage(msg.id)
                    } label: {
                        unreadRow(for: msg)
                    }
                    .buttonStyle(.plain)
                }

                if unreadCount > previewItems.count {
                    Button(action: onOpenMain) {
                        HStack(spacing: 4) {
                            Text("查看其余 \(unreadCount - previewItems.count) 封未读邮件")
                                .font(.caption.weight(.medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(BrandPalette.coral)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    private func unreadRow(for message: MailMessageSummary) -> some View {
        let snippet = viewModel.snippet(for: message.id)
        return HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(BrandPalette.coral)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.displaySender)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(formatRelativeTime(message.dateReceived))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Text(message.subject.isEmpty ? "(无主题)" : message.subject)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(1)

                if let snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            BrandPalette.floatingCardFill(for: colorScheme).opacity(colorScheme == .dark ? 0.65 : 0.72),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(BrandPalette.floatingCardBorder(for: colorScheme).opacity(0.55), lineWidth: 0.6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button(action: onOpenMain) {
                Label("打开主窗口", systemImage: "macwindow")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Button(action: onOpenSettings) {
                Label("设置", systemImage: "gearshape")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onQuit) {
                Text("退出")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func formatRelativeTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天"
        }
        return Self.dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df
    }()

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM/dd"
        return df
    }()
}
