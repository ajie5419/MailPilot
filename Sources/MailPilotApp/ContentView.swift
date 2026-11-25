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
                        .navigationSplitViewColumnWidth(min: 168, ideal: 192, max: 240)
                } content: {
                    messageListView
                        .navigationSplitViewColumnWidth(min: 270, ideal: 315, max: 390)
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
                            Label("检查新邮件", systemImage: "arrow.clockwise")
                        }
                        .help("调用系统 Mail.app 立即检查新邮件")

                        Button {
                            viewModel.showAIPanel.toggle()
                        } label: {
                            Label("AI 助手", systemImage: viewModel.showAIPanel ? "sidebar.right" : "sparkles")
                        }
                        .help("展开或收起右侧 AI 助手（⌘J）")
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
        VStack(spacing: 0) {
            List(selection: $viewModel.sidebarSelection) {
                Section("收件箱") {
                    sidebarItemRow(
                        title: "全部收件箱",
                        icon: "tray",
                        color: .accentColor,
                        badge: viewModel.totalInboxUnreadCount > 0 ? viewModel.totalInboxUnreadCount : nil
                    )
                    .tag(SidebarSelection.allInbox)

                    sidebarItemRow(
                        title: "未读邮件",
                        icon: "envelope.badge",
                        color: .accentColor,
                        badge: viewModel.totalInboxUnreadCount > 0 ? viewModel.totalInboxUnreadCount : nil
                    )
                    .tag(SidebarSelection.unread)

                    sidebarItemRow(title: "已标星", icon: "flag", color: .orange, badge: nil)
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
                                HStack(spacing: 6) {
                                    Image(systemName: tagsCollapsed ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 9)

                                    Text("智能标签")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 4, leading: 2, bottom: 2, trailing: 4))

                            if !tagsCollapsed {
                                ForEach(activeTags) { tag in
                                    sidebarItemRow(title: tag.rawValue, icon: tag.iconName, color: colorForSmartTag(tag), badge: nil)
                                        .padding(.leading, 10)
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
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 9)

                                    AccountLogoView(
                                        accountID: group.id,
                                        email: group.email,
                                        customIconPath: group.customIconPath,
                                        presetLogoID: group.presetLogoID,
                                        sfSymbolName: group.sfSymbolName,
                                        fallbackColor: viewModel.accountBadgeColor(for: group.id),
                                        size: 16
                                    )

                                    Text(group.title)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.primary.opacity(0.88))
                                        .lineLimit(1)

                                    Spacer(minLength: 4)

                                    if group.totalUnread > 0 {
                                        Text("\(group.totalUnread)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 3.5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 3, leading: 2, bottom: 2, trailing: 6))

                            if !isCollapsed {
                                ForEach(group.mailboxes) { mb in
                                    sidebarItemRow(
                                        title: mb.displayName,
                                        icon: iconName(for: mb.displayName),
                                        color: iconColor(for: mb.displayName),
                                        badge: mb.unreadCount > 0 ? mb.unreadCount : nil
                                    )
                                    .padding(.leading, 12)
                                    .tag(SidebarSelection.mailbox(mb.id))
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
                .opacity(0.6)

            Button {
                viewModel.showSettings = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Text("偏好设置")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("⌘,")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开设置与 AI 订阅登录（⌘,）")
        }
    }

    private var messageListView: some View {
        VStack(spacing: 0) {
            // Single-row compact search pill + filter menu button
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
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
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: viewModel.searchFocusTrigger) { _, _ in
                    isSearchFieldFocused = true
                }

                Menu {
                    Button {
                        viewModel.filterUnreadOnly.toggle()
                    } label: {
                        if viewModel.filterUnreadOnly {
                            Label("仅看未读", systemImage: "checkmark")
                        } else {
                            Label("仅看未读", systemImage: "envelope.badge")
                        }
                    }

                    Button {
                        viewModel.filterHasAttachments.toggle()
                    } label: {
                        if viewModel.filterHasAttachments {
                            Label("仅看有附件", systemImage: "checkmark")
                        } else {
                            Label("仅看有附件", systemImage: "paperclip")
                        }
                    }

                    Divider()

                    Section("时间范围") {
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
                    }

                    if viewModel.hasActiveSearchFilters {
                        Divider()
                        Button("重置全部筛选") {
                            viewModel.resetSearchFilters()
                        }
                    }
                } label: {
                    Image(systemName: viewModel.hasActiveSearchFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(viewModel.hasActiveSearchFilters ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            viewModel.hasActiveSearchFilters
                                ? Color.accentColor.opacity(0.14)
                                : Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("筛选条件（未读 / 附件 / 时间范围）")
                .accessibilityLabel("筛选邮件")
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, viewModel.hasActiveSearchFilters ? 6 : 9)

            // Active Filter Chips (only visible when a filter is active)
            if viewModel.hasActiveSearchFilters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        if viewModel.filterUnreadOnly {
                            activeFilterChip(title: "未读") {
                                viewModel.filterUnreadOnly = false
                            }
                        }
                        if viewModel.filterHasAttachments {
                            activeFilterChip(title: "有附件") {
                                viewModel.filterHasAttachments = false
                            }
                        }
                        if viewModel.filterDateRange != .all {
                            activeFilterChip(title: viewModel.filterDateRange.rawValue) {
                                viewModel.filterDateRange = .all
                            }
                        }
                        Button("重置") {
                            viewModel.resetSearchFilters()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 7)
                }
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
                snippet: viewModel.snippet(for: msg.id),
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

    private func activeFilterChip(title: String, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2.weight(.medium))
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("移除「\(title)」筛选")
        .help("点击移除「\(title)」筛选")
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
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func colorForSmartTag(_ tag: MailSmartTag) -> Color {
        switch tag {
        case .verification: return Color(red: 0.44, green: 0.42, blue: 0.82)
        case .billing: return Color(red: 0.76, green: 0.56, blue: 0.18)
        case .orderLogistics: return Color(red: 0.80, green: 0.45, blue: 0.24)
        case .meeting: return Color(red: 0.24, green: 0.52, blue: 0.84)
        case .promotion: return Color(red: 0.68, green: 0.38, blue: 0.56)
        case .notification: return .secondary
        }
    }

    private func iconName(for name: String) -> String {
        switch name {
        case "收件箱": return "tray"
        case "已发送", "已发邮件": return "paperplane"
        case "草稿", "草稿箱": return "doc.text"
        case "废纸篓", "已删除邮件": return "trash"
        case "垃圾邮件": return "exclamationmark.octagon"
        case "归档", "所有邮件": return "archivebox"
        case "已加星标", "Starred": return "star"
        case "重要", "Important": return "bookmark"
        default: return "folder"
        }
    }

    private func iconColor(for name: String) -> Color {
        switch name {
        case "收件箱": return .accentColor
        case "已发送", "已发邮件": return .secondary
        case "草稿", "草稿箱": return .secondary
        case "废纸篓", "已删除邮件": return .red.opacity(0.75)
        case "垃圾邮件": return .orange.opacity(0.8)
        case "归档", "所有邮件": return .secondary
        case "已加星标", "Starred": return .orange
        case "重要", "Important": return .orange
        default: return .secondary
        }
    }
}

