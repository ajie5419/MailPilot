import AppKit
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @FocusState private var isMessageListFocused: Bool
    @FocusState private var isSearchFieldFocused: Bool

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
                HStack(spacing: 10) {
                    Text(toast)
                        .font(.callout)
                    if let actionTitle = viewModel.toastActionTitle {
                        Button(actionTitle) {
                            viewModel.performToastAction()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                }
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
    }

    private var messageListView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(viewModel.searchScopePlaceholder, text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($isSearchFieldFocused)
                    .onKeyPress(.escape) {
                        if !viewModel.searchQuery.isEmpty {
                            viewModel.searchQuery = ""
                        }
                        isSearchFieldFocused = false
                        isMessageListFocused = true
                        return .handled
                    }
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索（Esc）")
                } else if !isSearchFieldFocused {
                    Text("⌘F")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .onChange(of: viewModel.searchFocusTrigger) { _, _ in
                isSearchFieldFocused = true
            }

            // Structured Quick Filters (Unread / Attachments / Date Range)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        viewModel.filterUnreadOnly.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "envelope.badge")
                                .font(.system(size: 10))
                            Text("未读")
                                .font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            viewModel.filterUnreadOnly ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                            in: Capsule()
                        )
                        .foregroundStyle(viewModel.filterUnreadOnly ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.filterHasAttachments.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 10))
                            Text("有附件")
                                .font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            viewModel.filterHasAttachments ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                            in: Capsule()
                        )
                        .foregroundStyle(viewModel.filterHasAttachments ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Menu {
                        ForEach(SearchDateRange.allCases) { range in
                            Button {
                                viewModel.filterDateRange = range
                            } label: {
                                if viewModel.filterDateRange == range {
                                    Label(range.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(range.rawValue)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "calendar")
                                .font(.system(size: 10))
                            Text(viewModel.filterDateRange == .all ? "时间" : viewModel.filterDateRange.rawValue)
                                .font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            viewModel.filterDateRange != .all ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                            in: Capsule()
                        )
                        .foregroundStyle(viewModel.filterDateRange != .all ? Color.accentColor : Color.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    if viewModel.hasActiveSearchFilters {
                        Button {
                            viewModel.resetSearchFilters()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("重置筛选条件")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 7)
            }

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
                .onKeyPress(.escape) {
                    if viewModel.selectedMessageIDs.count > 1 {
                        viewModel.clearMultiSelection()
                        return .handled
                    }
                    if !viewModel.searchQuery.isEmpty {
                        viewModel.searchQuery = ""
                        return .handled
                    }
                    return .ignored
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

            Divider()

            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isWatchingLive ? Color.green : Color.orange)
                    .frame(width: 6.5, height: 6.5)
                Text(viewModel.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar.opacity(0.65))
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
            Button("全部回复") {
                viewModel.openComposeReplyAll(for: msg)
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

