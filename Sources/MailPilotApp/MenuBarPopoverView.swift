import AppKit
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

/// Frosted-glass mini inbox hosted inside the menu bar `NSPopover`.
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

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .opacity(colorScheme == .dark ? 0.35 : 0.45)

            if let feedback = viewModel.menuBarCopyFeedbackText {
                copyFeedbackBanner(text: feedback)
            }

            if viewModel.accessError == nil, let recentCode = viewModel.menuBarRecentVerificationCode {
                verificationCodeBanner(for: recentCode)
            }

            contentSection

            Divider()
                .opacity(colorScheme == .dark ? 0.35 : 0.45)

            footerBar
        }
        .frame(width: 336)
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
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 2.5)
                    .background(BrandPalette.coralBadge, in: Capsule())
            } else {
                Text("全部已读")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7.5)
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

    private func copyFeedbackBanner(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(red: 0.14, green: 0.58, blue: 0.34), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private func verificationCodeBanner(for item: RecentVerificationCode) -> some View {
        let isCopied = viewModel.copiedVerificationMessageID == item.messageID
        return HStack(spacing: 10) {
            Button {
                onSelectMessage(item.messageID)
            } label: {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(BrandPalette.coralButtonGradient)
                            .frame(width: 28, height: 28)
                        Image(systemName: "key.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text("最新验证码")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(BrandPalette.coral)
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(formatRelativeTime(item.dateReceived))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Text(item.sender)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.88))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点击打开验证码邮件")

            Button {
                viewModel.copyVerificationCode(item.code, messageID: item.messageID)
            } label: {
                HStack(spacing: 6) {
                    Text(item.code)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.white)

                    HStack(spacing: 3) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(isCopied ? "已复制" : "复制")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.18), in: Capsule())
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(
                    isCopied
                        ? AnyShapeStyle(Color(red: 0.14, green: 0.60, blue: 0.34))
                        : AnyShapeStyle(BrandPalette.coralButtonGradient),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .help("一键复制验证码 \(item.code)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            colorScheme == .dark
                ? BrandPalette.coral.opacity(0.14)
                : BrandPalette.coral.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(BrandPalette.coral.opacity(colorScheme == .dark ? 0.34 : 0.24), lineWidth: 0.8)
        )
        .padding(.horizontal, 10)
        .padding(.top, 9)
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
        } else {
            switch viewModel.menuBarUnreadPreviewState {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取收件箱未读…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)

            case .failed:
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                    Text("暂时无法读取未读预览")
                        .font(.callout.weight(.semibold))
                    Button("重试") {
                        viewModel.refreshMenuBarUnreadPreview()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)

            case .loaded(let items):
                if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(BrandPalette.coral.opacity(0.88))
                        Text("收件箱很清爽")
                            .font(.callout.weight(.semibold))
                        Text("当前没有待处理的未读邮件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, viewModel.menuBarRecentVerificationCode != nil ? 18 : 28)
                } else {
                    VStack(spacing: 4) {
                        ForEach(items) { msg in
                            unreadRow(for: msg)
                        }

                        if unreadCount > items.count {
                            Button(action: onOpenMain) {
                                HStack(spacing: 4) {
                                    Text("查看其余 \(unreadCount - items.count) 封未读邮件")
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
        }
    }

    private func unreadRow(for message: MailMessageSummary) -> some View {
        let snippet = viewModel.snippet(for: message.id)
        let rowCode = viewModel.menuBarUnreadVerificationCodes[message.id]
        let isCopied = viewModel.copiedVerificationMessageID == message.id

        return VStack(alignment: .leading, spacing: 7) {
            Button {
                onSelectMessage(message.id)
            } label: {
                HStack(alignment: .top, spacing: 9) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let code = rowCode {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(BrandPalette.coral)
                        Text(code)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(.primary)
                    }

                    Spacer(minLength: 4)

                    Button {
                        viewModel.copyVerificationCode(code, messageID: message.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(isCopied ? "已复制" : "复制")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            isCopied
                                ? AnyShapeStyle(Color(red: 0.14, green: 0.60, blue: 0.34))
                                : AnyShapeStyle(BrandPalette.coralButtonGradient),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .help("一键复制验证码 \(code) 并标为已读")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5.5)
                .background(
                    colorScheme == .dark
                        ? BrandPalette.coral.opacity(0.14)
                        : BrandPalette.coral.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(BrandPalette.coral.opacity(colorScheme == .dark ? 0.30 : 0.20), lineWidth: 0.7)
                )
                .padding(.leading, 16)
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
        let now = Date()
        let delta = now.timeIntervalSince(date)
        if delta >= -5 && delta < 60 {
            return "刚刚"
        }
        if delta >= 60 && delta < 3600 {
            return "\(Int(delta / 60)) 分钟前"
        }
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
