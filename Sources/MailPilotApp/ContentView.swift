import AppKit
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @FocusState private var isMessageListFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            if let error = viewModel.accessError {
                PermissionGuideView(error: error, viewModel: viewModel)
            } else {
                NavigationSplitView {
                    sidebarView
                        .navigationSplitViewColumnWidth(min: 155, ideal: 175, max: 220)
                } content: {
                    messageListView
                        .navigationSplitViewColumnWidth(min: 245, ideal: 280, max: 360)
                } detail: {
                    MailDetailView(viewModel: viewModel)
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
                .inspector(isPresented: $viewModel.showAIPanel) {
                    AIAssistantPanel(viewModel: viewModel)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            viewModel.openComposeNew()
                        } label: {
                            Label("写邮件", systemImage: "square.and.pencil")
                        }
                        .help("撰写新邮件（⌘N）")

                        Button {
                            viewModel.triggerNativeMailFetch()
                        } label: {
                            Label("让 Mail.app 收信", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .help("调用系统 Mail.app 立即检查新邮件")

                        Button {
                            viewModel.generateUnreadBriefing()
                            viewModel.showAIPanel = true
                        } label: {
                            Label("未读简报", systemImage: "sparkles.rectangle.stack")
                        }
                        .help("用 AI 汇总当前列表里的未读邮件")

                        Button {
                            viewModel.showAIPanel.toggle()
                        } label: {
                            Label("AI 抽屉", systemImage: viewModel.showAIPanel ? "sidebar.right" : "sparkles")
                        }
                        .help("展开或收起右侧 AI 对话抽屉（⌘J）")

                        Button {
                            viewModel.showSettings = true
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                        .help("打开设置与 AI 订阅登录（⌘,）")
                    }
                }
            }

            if let toast = viewModel.toastMessage {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                    .shadow(radius: 6)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.toastMessage)
    }

    private var sidebarView: some View {
        List(selection: $viewModel.sidebarSelection) {
            Section("快捷视图") {
                sidebarItemRow(
                    title: "全部收件箱",
                    icon: "tray.full.fill",
                    color: .blue,
                    badge: viewModel.totalInboxUnreadCount > 0 ? viewModel.totalInboxUnreadCount : nil
                )
                .tag(SidebarSelection.allInbox)

                sidebarItemRow(
                    title: "未读邮件",
                    icon: "envelope.badge.fill",
                    color: .accentColor,
                    badge: viewModel.totalInboxUnreadCount > 0 ? viewModel.totalInboxUnreadCount : nil
                )
                .tag(SidebarSelection.unread)

                sidebarItemRow(title: "已标星", icon: "flag.fill", color: .orange, badge: nil)
                    .tag(SidebarSelection.flagged)
            }

            if viewModel.tagSettings.isEnabled {
                let activeTags = MailSmartTag.allCases.filter { viewModel.tagSettings.isTagEnabled($0) }
                if !activeTags.isEmpty {
                    let tagsCollapsed = viewModel.isSectionCollapsed("smart-tags")
                    Section {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                viewModel.toggleSectionCollapsed("smart-tags")
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: tagsCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 9)

                                ZStack {
                                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                        .fill(Color.purple.opacity(0.18))
                                    Image(systemName: "tag.fill")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(.purple)
                                }
                                .frame(width: 17, height: 17)

                                Text("智能标签")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary.opacity(0.92))
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))

                        if !tagsCollapsed {
                            ForEach(activeTags) { tag in
                                sidebarItemRow(title: tag.rawValue, icon: tag.iconName, color: colorForSmartTag(tag), badge: nil)
                                    .padding(.leading, 14)
                                    .tag(SidebarSelection.smartTag(tag))
                            }
                        }
                    }
                }
            }

            if !viewModel.groupedMailboxes.isEmpty {
                Section("邮箱账号") {
                    ForEach(viewModel.groupedMailboxes) { group in
                        let isCollapsed = viewModel.isSectionCollapsed("acct-\(group.id)")
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                viewModel.toggleSectionCollapsed("acct-\(group.id)")
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 9)

                                AccountLogoView(
                                    accountID: group.id,
                                    email: group.email,
                                    customIconPath: group.customIconPath,
                                    presetLogoID: group.presetLogoID,
                                    sfSymbolName: group.sfSymbolName,
                                    fallbackColor: viewModel.accountBadgeColor(for: group.id),
                                    size: 17
                                )

                                Text(group.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary.opacity(0.92))
                                    .lineLimit(1)

                                Spacer(minLength: 4)

                                if group.totalUnread > 0 {
                                    Text("\(group.totalUnread)")
                                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))

                        if !isCollapsed {
                            ForEach(group.mailboxes) { mb in
                                sidebarItemRow(
                                    title: mb.displayName,
                                    icon: iconName(for: mb.displayName),
                                    color: iconColor(for: mb.displayName),
                                    badge: mb.unreadCount > 0 ? mb.unreadCount : nil
                                )
                                .padding(.leading, 14)
                                .tag(SidebarSelection.mailbox(mb.id))
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isWatchingLive ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(viewModel.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var messageListView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("搜索主题、发件人或正文", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if viewModel.selectedMessageIDs.count > 1 {
                HStack(spacing: 8) {
                    Text("已选 \(viewModel.selectedMessageIDs.count) 封")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Button {
                        viewModel.batchMarkSelected(isRead: true)
                    } label: {
                        Image(systemName: "envelope.open")
                    }
                    .help("全部标为已读")

                    Button {
                        viewModel.batchArchiveSelected()
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .help("批量归档")

                    Button {
                        viewModel.batchDeleteSelected()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("批量删除")

                    Button {
                        viewModel.clearMultiSelection()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .help("取消多选")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))

                Divider()
            }

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { idx, msg in
                            messageListCell(msg: msg, index: idx)
                                .id(msg.id)
                        }

                        if viewModel.hasMoreMessages {
                            let isSearching = !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            HStack {
                                Spacer()
                                Button(isSearching ? "加载更多搜索结果" : "加载更多历史邮件") {
                                    viewModel.loadMoreMessages()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Spacer()
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($isMessageListFocused)
                .onKeyPress(.upArrow) {
                    moveMessageSelection(by: -1, scrollProxy: scrollProxy)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveMessageSelection(by: 1, scrollProxy: scrollProxy)
                    return .handled
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if viewModel.messages.isEmpty {
                    ContentUnavailableView(
                        "暂无邮件",
                        systemImage: "tray",
                        description: Text("当前筛选条件下没有匹配的邮件。")
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func messageListCell(msg: MailMessageSummary, index: Int) -> some View {
        let isSelected = viewModel.selectedMessageIDs.contains(msg.id)
        let hasNext = index + 1 < viewModel.messages.count
        let nextSelected = hasNext && viewModel.selectedMessageIDs.contains(viewModel.messages[index + 1].id)

        MessageListRowContainer(
            isSelected: isSelected,
            showBottomDivider: hasNext && !isSelected && !nextSelected,
            onTap: {
                isMessageListFocused = true
                handleMessageRowTap(msg.id)
            }
        ) {
            MessageRowView(
                message: msg,
                tags: viewModel.tags(for: msg),
                accountBadge: viewModel.isUnifiedView ? viewModel.accountShortUsername(for: msg.accountID) : nil,
                accountEmail: viewModel.accountEmail(for: msg.accountID),
                accountCustomIconPath: viewModel.accountCustomIconPath(for: msg.accountID),
                accountPresetLogoID: viewModel.accountPresetLogoID(for: msg.accountID),
                accountSFSymbolName: viewModel.accountSFSymbolName(for: msg.accountID),
                accountColor: viewModel.accountBadgeColor(for: msg.accountID)
            )
            .equatable()
        } contextMenu: {
            messageContextMenu(for: msg)
        }
    }

    @ViewBuilder
    private func messageContextMenu(for msg: MailMessageSummary) -> some View {
        if viewModel.selectedMessageIDs.count > 1 && viewModel.selectedMessageIDs.contains(msg.id) {
            Button("全部标为已读（\(viewModel.selectedMessageIDs.count) 封）") {
                viewModel.batchMarkSelected(isRead: true)
            }
            Button("全部标为未读（\(viewModel.selectedMessageIDs.count) 封）") {
                viewModel.batchMarkSelected(isRead: false)
            }
            Divider()
            Button("批量归档（\(viewModel.selectedMessageIDs.count) 封）") {
                viewModel.batchArchiveSelected()
            }
            Button("批量删除（\(viewModel.selectedMessageIDs.count) 封）", role: .destructive) {
                viewModel.batchDeleteSelected()
            }
        } else {
            Button("回复") {
                viewModel.openComposeReply(for: msg)
            }
            Button("转发") {
                viewModel.openComposeForward(for: msg)
            }
            Divider()
            Button(msg.isRead ? "标记为未读" : "标记为已读") {
                viewModel.toggleReadStatus(for: msg)
            }
            Button(msg.isFlagged ? "取消旗标" : "添加旗标") {
                viewModel.toggleFlaggedStatus(for: msg)
            }
            Button("归档") {
                viewModel.archiveMessage(msg)
            }
            Button("删除", role: .destructive) {
                viewModel.deleteMessage(msg)
            }
            Divider()
            Button("在系统 Mail.app 中打开") {
                viewModel.openInNativeMail(msg)
            }
        }
    }

    private func handleMessageRowTap(_ id: Int64) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if viewModel.selectedMessageIDs.contains(id) {
                viewModel.selectedMessageIDs.remove(id)
                if viewModel.selectedMessageID == id {
                    viewModel.selectedMessageID = viewModel.selectedMessageIDs.first
                }
            } else {
                viewModel.selectedMessageIDs.insert(id)
                if viewModel.selectedMessageID == nil {
                    viewModel.selectedMessageID = id
                }
            }
        } else if flags.contains(.shift),
                  let anchorID = viewModel.selectedMessageID,
                  let anchorIdx = viewModel.messages.firstIndex(where: { $0.id == anchorID }),
                  let targetIdx = viewModel.messages.firstIndex(where: { $0.id == id }) {
            let lower = min(anchorIdx, targetIdx)
            let upper = max(anchorIdx, targetIdx)
            viewModel.selectedMessageIDs = Set(viewModel.messages[lower...upper].map(\.id))
        } else {
            viewModel.selectedMessageIDs = [id]
            if viewModel.selectedMessageID != id {
                viewModel.selectedMessageID = id
            }
        }
    }

    private func moveMessageSelection(by delta: Int, scrollProxy: ScrollViewProxy) {
        guard !viewModel.messages.isEmpty else { return }
        let currentIdx = viewModel.selectedMessageID.flatMap { id in
            viewModel.messages.firstIndex(where: { $0.id == id })
        }
        let nextIdx: Int
        if let currentIdx {
            nextIdx = max(0, min(viewModel.messages.count - 1, currentIdx + delta))
        } else {
            nextIdx = delta >= 0 ? 0 : viewModel.messages.count - 1
        }
        let targetID = viewModel.messages[nextIdx].id
        viewModel.selectedMessageIDs = [targetID]
        if viewModel.selectedMessageID != targetID {
            viewModel.selectedMessageID = targetID
        }
        withAnimation(.easeInOut(duration: 0.12)) {
            scrollProxy.scrollTo(targetID)
        }
    }

    private func sidebarItemRow(title: String, icon: String, color: Color, badge: Int?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 17, alignment: .center)
            Text(title)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
            }
        }
    }

    private func colorForSmartTag(_ tag: MailSmartTag) -> Color {
        switch tag {
        case .verification: return Color(red: 0.58, green: 0.46, blue: 0.92)
        case .billing: return Color(red: 0.86, green: 0.65, blue: 0.20)
        case .orderLogistics: return Color(red: 0.88, green: 0.46, blue: 0.24)
        case .meeting: return Color(red: 0.34, green: 0.60, blue: 0.92)
        case .promotion: return Color(red: 0.80, green: 0.42, blue: 0.62)
        case .notification: return .secondary
        }
    }

    private func iconName(for name: String) -> String {
        switch name {
        case "收件箱": return "tray.fill"
        case "已发送", "已发邮件": return "paperplane"
        case "草稿", "草稿箱": return "doc.text"
        case "废纸篓", "已删除邮件": return "trash"
        case "垃圾邮件": return "exclamationmark.octagon"
        case "归档", "所有邮件": return "archivebox"
        case "已加星标", "Starred": return "star.fill"
        case "重要", "Important": return "bookmark.fill"
        default: return "folder"
        }
    }

    private func iconColor(for name: String) -> Color {
        switch name {
        case "收件箱": return .blue
        case "已发送", "已发邮件": return .teal
        case "草稿", "草稿箱": return .secondary
        case "废纸篓", "已删除邮件": return .red.opacity(0.8)
        case "垃圾邮件": return .orange.opacity(0.85)
        case "归档", "所有邮件": return .indigo.opacity(0.85)
        case "已加星标", "Starred": return .yellow
        case "重要", "Important": return .orange
        default: return .secondary
        }
    }
}

private final class RowHoverState: ObservableObject {
    @Published var isHovered = false
}

private struct MessageListRowContainer<RowContent: View, MenuContent: View>: View {
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

private struct MessageRowView: View, Equatable {
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

private struct PermissionGuideView: View {
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
