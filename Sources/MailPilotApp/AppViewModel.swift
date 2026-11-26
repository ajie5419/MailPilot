import AppKit
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import ServiceManagement
import SwiftUI

enum SearchDateRange: String, CaseIterable, Identifiable {
    case all = "全部时间"
    case last7Days = "近 7 天"
    case last30Days = "近 30 天"
    case last90Days = "近 90 天"

    var id: String { rawValue }

    var cutoffDate: Date? {
        let now = Date()
        switch self {
        case .all: return nil
        case .last7Days: return Calendar.current.date(byAdding: .day, value: -7, to: now)
        case .last30Days: return Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .last90Days: return Calendar.current.date(byAdding: .day, value: -90, to: now)
        }
    }
}

enum SidebarSelection: Hashable {
    case allInbox
    case unread
    case flagged
    case smartTag(MailSmartTag)
    case mailbox(Int64)
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case ai = "AI 与订阅"
    case accounts = "邮箱账号"
    case tags = "智能标签"
    case notifications = "通知与状态栏"
    case permissions = "系统权限"
    case about = "关于"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .ai: return "sparkles"
        case .accounts: return "at.circle.fill"
        case .tags: return "tag.fill"
        case .notifications: return "bell.badge.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }
}

enum MenuBarUnreadPreviewState: Equatable {
    case loading
    case loaded([MailMessageSummary])
    case failed
}

struct RecentVerificationCode: Equatable, Sendable {
    let messageID: Int64
    let code: String
    let sender: String
    let subject: String
    let dateReceived: Date
    let isUnread: Bool
}

struct CachedAccountMeta {
    let title: String
    let shortName: String
    let email: String?
    let customIconPath: String?
    let presetLogoID: String?
    let sfSymbolName: String?
    let color: Color
}

@MainActor
final class AppViewModel: ObservableObject {
    // MARK: - Child Coordinators (isolated ObservableObjects for scoped SwiftUI updates)

    let bodyIndex = BodyIndexCoordinator()
    let ai = AIAssistantController()
    let compose = ComposeCoordinator()

    // MARK: - Navigation & Message List State

    @Published var sidebarSelection: SidebarSelection = .allInbox {
        didSet {
            if sidebarSelection != oldValue {
                sessionKeptUnreadMessages.removeAll()
            }
            guard !suppressFilterReload else { return }
            pendingJumpMessageID = nil
            pinnedJumpMessageID = nil
            suppressAutoSelectFirstMessage = false
            currentPageLimit = 200
            reloadMessages()
        }
    }
    @Published var searchQuery: String = "" {
        didSet {
            guard !suppressFilterReload else { return }
            if searchQuery != oldValue {
                pendingJumpMessageID = nil
                pinnedJumpMessageID = nil
                suppressAutoSelectFirstMessage = false
                reloadGeneration &+= 1
                reloadTask?.cancel()
                snippetFetchTask?.cancel()
                currentPageLimit = 200
                scheduleSearchReload()
            }
        }
    }
    @Published var filterUnreadOnly: Bool = false {
        didSet {
            guard !suppressFilterReload else { return }
            if filterUnreadOnly != oldValue {
                pinnedJumpMessageID = nil
                suppressAutoSelectFirstMessage = false
                currentPageLimit = 200
                reloadMessages()
            }
        }
    }
    @Published var filterHasAttachments: Bool = false {
        didSet {
            guard !suppressFilterReload else { return }
            if filterHasAttachments != oldValue {
                pinnedJumpMessageID = nil
                suppressAutoSelectFirstMessage = false
                currentPageLimit = 200
                reloadMessages()
            }
        }
    }
    @Published var filterDateRange: SearchDateRange = .all {
        didSet {
            guard !suppressFilterReload else { return }
            if filterDateRange != oldValue {
                pinnedJumpMessageID = nil
                suppressAutoSelectFirstMessage = false
                currentPageLimit = 200
                reloadMessages()
            }
        }
    }
    @Published var searchFocusTrigger: Int = 0

    var hasActiveSearchFilters: Bool {
        filterUnreadOnly || filterHasAttachments || filterDateRange != .all
    }

    func resetSearchFilters() {
        filterUnreadOnly = false
        filterHasAttachments = false
        filterDateRange = .all
    }

    func focusSearchField() {
        searchFocusTrigger += 1
    }

    var searchScopePlaceholder: String {
        switch sidebarSelection {
        case .allInbox:
            return "在「收件箱」中搜索…"
        case .unread:
            return "在「未读邮件」中搜索…"
        case .flagged:
            return "在「已标星」中搜索…"
        case .smartTag(let tag):
            return "在「\(tag.rawValue)」中搜索…"
        case .mailbox(let id):
            let name = mailboxes.first(where: { $0.id == id })?.displayName ?? "当前文件夹"
            return "在「\(name)」中搜索…"
        }
    }

    @Published var mailboxes: [MailboxInfo] = [] {
        didSet {
            rebuildAccountGroupingCache()
            updateDockUnreadBadge()
        }
    }
    @Published var groupedMailboxes: [AccountMailboxGroup] = []
    @Published var messages: [MailMessageSummary] = []
    @Published var messageSnippets: [Int64: String] = [:]
    @Published var currentPageLimit: Int = 200

    func snippet(for messageID: Int64) -> String? {
        messageSnippets[messageID]
    }
    @Published var hasMoreMessages: Bool = false
    @Published var selectedMessageIDs: Set<Int64> = [] {
        didSet {
            if selectedMessageIDs.count == 1, let single = selectedMessageIDs.first {
                if selectedMessageID != single {
                    selectedMessageID = single
                }
            } else if selectedMessageIDs.isEmpty {
                selectedMessageID = nil
            }
        }
    }
    @Published var selectedMessageID: Int64? {
        didSet {
            if let id = selectedMessageID {
                suppressAutoSelectFirstMessage = false
                if let pinned = pinnedJumpMessageID, pinned != id {
                    pinnedJumpMessageID = nil
                }
                if selectedMessageIDs.count <= 1, selectedMessageIDs != [id] {
                    selectedMessageIDs = [id]
                }
            }
            loadSelectedMessageBody()
        }
    }

    // MARK: - Selected Body State

    @Published var selectedBody: ParsedMailBody?
    @Published var selectedBodyMessageID: Int64?
    @Published var selectedMessageRecipients: [MailRecipientInfo] = []
    @Published var selectedPlainAttributedText: AttributedString = AttributedString("")
    @Published var selectedBodyHasRemoteResources: Bool = false
    @Published var isLoadingBody = false
    @Published var preferPlainText = false
    @Published var blockRemoteImages: Bool {
        didSet {
            UserDefaults.standard.set(blockRemoteImages, forKey: Self.blockRemoteImagesKey)
        }
    }
    @Published var allowedRemoteContentMessageIDs: Set<Int64> = []

    /// Returns the loaded body strictly for the currently selected message; `nil` while switching/loading.
    var currentLoadedBody: ParsedMailBody? {
        guard !isLoadingBody, let id = selectedMessageID, selectedBodyMessageID == id else {
            return nil
        }
        return selectedBody
    }

    var allowOnlineBrandAvatars: Bool {
        get { SenderAvatarLoader.shared.allowOnlineBrandAvatars }
        set {
            SenderAvatarLoader.shared.allowOnlineBrandAvatars = newValue
            objectWillChange.send()
        }
    }

    func allowRemoteContent(for messageID: Int64) {
        allowedRemoteContentMessageIDs.insert(messageID)
    }

    // MARK: - Window, Account & Preferences State

    @Published var accessError: MailAccessError?
    @Published var statusText: String = "正在连接原生 Mail.app 索引..."
    @Published var isWatchingLive = false
    @Published var showAIPanel = false
    @Published var showSettings = false
    @Published var settingsTab: SettingsTab = .ai
    @Published var toastMessage: String?
    @Published var toastActionTitle: String?
    private var toastActionHandler: (() -> Void)?
    private var toastDismissTask: Task<Void, Never>?

    @Published var showMenuBarExtra: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarExtra, forKey: Self.showMenuBarExtraKey)
            updateDockUnreadBadge()
        }
    }
    @Published var menuBarUnreadPreviewState: MenuBarUnreadPreviewState = .loading
    @Published var menuBarRecentVerificationCode: RecentVerificationCode?
    @Published var menuBarUnreadVerificationCodes: [Int64: String] = [:]
    @Published var copiedVerificationMessageID: Int64?
    @Published var menuBarCopyFeedbackText: String?
    @Published var launchAtLoginEnabled: Bool = false

    @Published var accounts: [MailAccountInfo] = [] {
        didSet { rebuildAccountGroupingCache() }
    }
    @Published var accountEmails: [String] = []
    @Published var accountCustomizations: [String: AccountCustomization] {
        didSet {
            saveAccountCustomizations()
            rebuildAccountGroupingCache()
        }
    }
    @Published var defaultSendAccountID: String {
        didSet {
            UserDefaults.standard.set(defaultSendAccountID, forKey: Self.defaultSendAccountKey)
        }
    }
    @Published var selectedSettingsAccountID: String = ""
    @Published var showIconPickerSheet = false
    @Published var iconPickerState = AccountIconPickerState()

    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Self.notificationsEnabledKey)
        }
    }
    @Published var notificationAuthStatusText: String = "检测中..."
    @Published var tagSettings: MailTagSettings {
        didSet {
            saveTagSettings()
            recomputeCachedTags()
            if case .smartTag = sidebarSelection {
                reloadMessages()
            }
        }
    }
    @Published var collapsedSidebarSections: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(collapsedSidebarSections), forKey: Self.collapsedSectionsStorageKey)
        }
    }

    // MARK: - Internal State Shared Across Extensions

    var reader: EnvelopeIndexReader?
    var emlxParser: EmlxParser?
    let notificationManager = NotificationManager()
    var lastSeenMaxRowID: Int64?
    var hasSeededNotificationWatermark = false
    var notifiedMessageIDs: Set<Int64> = []
    var isCheckingIncomingNotifications = false
    var needsFollowUpNotificationCheck = false
    var cachedAccountLookup: [String: CachedAccountMeta] = [:]
    var pendingRemovedIDs: Set<Int64> = []
    var pendingReadOverrides: [Int64: (isRead: Bool, token: UInt64)] = [:]
    var pendingReadOriginals: [Int64: (message: MailMessageSummary, isInbox: Bool)] = [:]
    var nextReadOpToken: UInt64 = 0
    var localListMutationVersion: UInt64 = 0
    var isFetchingAccounts = false
    var lastAccountsFetchAt: Date = .distantPast

    private struct CachedRenderedBody: Sendable {
        let body: ParsedMailBody
        let attributedPlain: AttributedString
        let hasRemoteResources: Bool
    }

    private var bodyLoadTask: Task<Void, Never>?
    private var recipientsLoadTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var menuBarPreviewTask: Task<Void, Never>?
    private var menuBarPreviewGeneration: UInt64 = 0
    private var menuBarCodeTask: Task<Void, Never>?
    private var menuBarCodeGeneration: UInt64 = 0
    private var copiedCodeResetTask: Task<Void, Never>?
    /// Maps message ROWID -> extracted OTP code (`nil` means parsed and confirmed no code).
    var cachedVerificationCodes: [Int64: String?] = [:]
    private var cachedVerificationOrder: [Int64] = []
    private static let maxCachedVerificationEntries = 128
    private var pendingJumpMessageID: Int64?
    var pinnedJumpMessageID: Int64?
    var suppressAutoSelectFirstMessage = false
    private var suppressFilterReload = false
    private var reloadGeneration: UInt64 = 0
    private var snippetFetchTask: Task<Void, Never>?
    private var snippetGeneration: UInt64 = 0
    private var pendingSnippetRefreshIDs: Set<Int64> = []
    private var searchDebounceTask: Task<Void, Never>?
    var autoMarkReadTask: Task<Void, Never>?
    var autoMarkReadTargetID: Int64?
    private var watcher: MailDirectoryWatcher?
    private var wakeObserver: NSObjectProtocol?
    private var appLifecycleObservers: [NSObjectProtocol] = []
    private var isRefreshingMailboxes = false
    private var needsFollowUpRefresh = false
    private var cachedMessageTags: [Int64: [MailSmartTag]] = [:]
    private var recentBodyCache: [Int64: CachedRenderedBody] = [:]
    private var recentBodyOrder: [Int64] = []
    /// Keeps messages auto-marked as read during the current `.unread` session visible so reading never jumps away.
    var sessionKeptUnreadMessages: [Int64: MailMessageSummary] = [:]

    private static let maxRecentBodyCacheEntries = 8
    private static let maxCacheableBodyBytes = 2 * 1024 * 1024
    private static let notificationsEnabledKey = "MailPilot.NotificationsEnabled.v1"
    private static let showMenuBarExtraKey = "MailPilot.ShowMenuBarExtra.v1"
    private static let blockRemoteImagesKey = "MailPilot.BlockRemoteImages.v1"
    private static let tagSettingsStorageKey = "MailPilot.TagSettings.v1"
    private static let collapsedSectionsStorageKey = "MailPilot.CollapsedSidebarSections.v1"
    static let accountCustomizationsKey = "MailPilot.AccountCustomizations.v1"
    private static let defaultSendAccountKey = "MailPilot.DefaultSendAccountID.v1"

    init() {
        if UserDefaults.standard.object(forKey: Self.blockRemoteImagesKey) != nil {
            self.blockRemoteImages = UserDefaults.standard.bool(forKey: Self.blockRemoteImagesKey)
        } else {
            self.blockRemoteImages = true
        }
        if UserDefaults.standard.object(forKey: Self.notificationsEnabledKey) != nil {
            self.notificationsEnabled = UserDefaults.standard.bool(forKey: Self.notificationsEnabledKey)
        } else {
            self.notificationsEnabled = true
        }
        if UserDefaults.standard.object(forKey: Self.showMenuBarExtraKey) != nil {
            self.showMenuBarExtra = UserDefaults.standard.bool(forKey: Self.showMenuBarExtraKey)
        } else {
            self.showMenuBarExtra = true
        }
        self.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        if let customData = UserDefaults.standard.data(forKey: Self.accountCustomizationsKey),
           let decodedCustom = try? JSONDecoder().decode([String: AccountCustomization].self, from: customData) {
            self.accountCustomizations = decodedCustom
        } else {
            self.accountCustomizations = [:]
        }
        self.defaultSendAccountID = UserDefaults.standard.string(forKey: Self.defaultSendAccountKey) ?? ""
        if let savedCollapsed = UserDefaults.standard.stringArray(forKey: Self.collapsedSectionsStorageKey) {
            self.collapsedSidebarSections = Set(savedCollapsed)
        } else {
            self.collapsedSidebarSections = []
        }
        if let tagData = UserDefaults.standard.data(forKey: Self.tagSettingsStorageKey),
           let decodedTags = try? JSONDecoder().decode(MailTagSettings.self, from: tagData) {
            self.tagSettings = decodedTags
        } else {
            self.tagSettings = MailTagSettings()
        }

        wireCoordinators()

        notificationManager.onSelectMessage = { [weak self] rowID in
            Task { @MainActor [weak self] in
                self?.jumpToMessage(rowID: rowID)
            }
        }
        ai.startInitialLoads()
        requestNotificationPermissionOnLaunch()
        connectToNativeMail()
        observeSystemWake()
        observeAppLifecycle()
        Task {
            let fetchedAccounts = await MailAppleScriptBridge.fetchAccounts()
            self.accounts = fetchedAccounts
            let emails = await MailAppleScriptBridge.fetchAccountEmails()
            self.accountEmails = emails.isEmpty ? fetchedAccounts.map(\.email).filter { !$0.isEmpty } : emails
        }
    }

    private func wireCoordinators() {
        bodyIndex.onIndexedRowIDsUpdated = { [weak self] updatedIDs in
            self?.handleIndexedRowIDsUpdated(updatedIDs)
        }
        bodyIndex.onIndexCleared = { [weak self] in
            self?.invalidateAllSnippets()
        }
        bodyIndex.onRowIDsDeleted = { [weak self] deletedIDs in
            self?.removeSnippets(for: deletedIDs)
        }

        ai.onShowToast = { [weak self] msg in
            self?.showToast(msg)
        }
        ai.onOpenAIPanel = { [weak self] in
            self?.showAIPanel = true
        }
        ai.onOpenReplyDraft = { [weak self] message, body in
            self?.openComposeReply(for: message, prefilledBody: body)
        }
        ai.currentSelectedMessageID = { [weak self] in
            self?.selectedMessageID
        }
        ai.currentMessageContext = { [weak self] in
            guard let self else { return (nil, nil) }
            return (self.selectedMessage, self.currentLoadedBody)
        }
        ai.currentMessages = { [weak self] in
            self?.messages ?? []
        }
        ai.onSearchEmailsForQA = { [weak self] keywords, limit in
            guard let self, let reader = self.reader else { return [] }
            let fts = self.bodyIndex
            var hitIDs: [Int64] = []
            var seen: Set<Int64> = []
            for kw in keywords {
                let ids = await fts.searchRowIDs(query: kw, limit: 80)
                for id in ids where seen.insert(id).inserted {
                    hitIDs.append(id)
                }
            }
            let primaryKeyword = keywords.first ?? ""
            let fetched: [MailMessageSummary] = await Task.detached(priority: .userInitiated) {
                let page = (try? reader.fetchMessagePage(
                    onlyInbox: false,
                    searchQuery: primaryKeyword,
                    bodyHitIDs: hitIDs,
                    limit: limit
                ))
                return page?.messages ?? []
            }.value
            let snippets = await fts.fetchSnippets(for: fetched.map(\.id), maxChars: 650)
            return fetched.map { msg in
                (message: msg, snippet: snippets[msg.id] ?? "")
            }
        }

        compose.currentAIConfig = { [weak self] in
            self?.ai.aiConfig ?? AIConfig()
        }
        compose.preferredSenderEmail = { [weak self] in
            self?.preferredSenderEmail() ?? ""
        }
        compose.senderEmailForOriginAccount = { [weak self] accountID in
            self?.senderEmail(forOriginAccountID: accountID)
        }
        compose.formattedSenderHeader = { [weak self] rawEmail in
            self?.formattedSenderHeader(for: rawEmail)
        }
        compose.signatureForSenderEmail = { [weak self] rawEmail in
            self?.signature(forSenderEmail: rawEmail)
        }
        compose.allOwnEmails = { [weak self] in
            guard let self else { return [] }
            var emails = self.accountEmails
            for acct in self.accounts where !acct.email.isEmpty {
                emails.append(acct.email)
            }
            return emails
        }
        compose.accountEmailsCount = { [weak self] in
            self?.accountEmails.count ?? 0
        }
        compose.onRefreshAccountEmailsIfEmpty = { [weak self] in
            self?.refreshAccountEmailsIfEmpty()
        }
        compose.onSearchContacts = { [weak self] query in
            guard let reader = self?.reader else { return [] }
            return await Task.detached(priority: .userInitiated) {
                (try? reader.searchContacts(query: query, limit: 8)) ?? []
            }.value
        }
        compose.onMaterializeAttachment = { attachment, messageID in
            await Task.detached(priority: .userInitiated) {
                if let local = attachment.localFileURL, FileManager.default.fileExists(atPath: local.path) {
                    return local
                }
                guard let data = EmlxParser.decodeAttachmentData(attachment) else { return nil }
                let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let folder = caches
                    .appendingPathComponent("MailPilot/Attachments", isDirectory: true)
                    .appendingPathComponent("\(messageID)", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let safeName = attachment.filename.replacingOccurrences(of: "/", with: "_")
                let targetURL = folder.appendingPathComponent(safeName)
                do {
                    try data.write(to: targetURL, options: .atomic)
                    return targetURL
                } catch {
                    return nil
                }
            }.value
        }
        compose.onShowToast = { [weak self] msg in
            self?.showToast(msg)
        }
    }

    // MARK: - Convenience Coordinator Actions

    func openComposeNew() {
        compose.openNew()
    }

    func openComposeReply(for message: MailMessageSummary? = nil, prefilledBody: String? = nil) {
        guard let target = message ?? selectedMessage else { return }
        let verifiedBody = (target.id == selectedBodyMessageID && !isLoadingBody) ? selectedBody?.plainText : nil
        compose.openReply(for: target, verifiedBody: verifiedBody, prefilledBody: prefilledBody)
    }

    func openComposeReplyAll(for message: MailMessageSummary? = nil, prefilledBody: String? = nil) {
        guard let target = message ?? selectedMessage else { return }
        let verifiedBody = (target.id == selectedBodyMessageID && !isLoadingBody) ? selectedBody?.plainText : nil
        if target.id == selectedMessageID && !selectedMessageRecipients.isEmpty {
            compose.openReplyAll(
                for: target,
                recipients: selectedMessageRecipients,
                verifiedBody: verifiedBody,
                prefilledBody: prefilledBody
            )
            return
        }
        guard let reader else {
            compose.openReplyAll(for: target, recipients: [], verifiedBody: verifiedBody, prefilledBody: prefilledBody)
            return
        }
        Task { [weak self] in
            let fetched = await Task.detached(priority: .userInitiated) {
                (try? reader.fetchRecipients(for: target.id)) ?? []
            }.value
            self?.compose.openReplyAll(
                for: target,
                recipients: fetched,
                verifiedBody: verifiedBody,
                prefilledBody: prefilledBody
            )
        }
    }

    func openComposeForward(for message: MailMessageSummary? = nil) {
        guard let target = message ?? selectedMessage else { return }
        let isLoadedForTarget = (target.id == selectedBodyMessageID && !isLoadingBody)
        let verifiedBody = isLoadedForTarget ? selectedBody?.plainText : nil
        let originalAttachments = isLoadedForTarget ? (selectedBody?.attachments ?? []) : []
        compose.openForward(for: target, verifiedBody: verifiedBody, originalAttachments: originalAttachments)
    }

    func generateUnreadBriefing() {
        ai.generateUnreadBriefing()
    }

    func rebuildBodySearchIndex() {
        bodyIndex.rebuild(
            visiblePriority: messages,
            reader: reader,
            parser: emlxParser,
            onToast: { [weak self] in self?.showToast($0) }
        )
    }

    func retryBodySearchIndexing() {
        bodyIndex.retry(
            visiblePriority: messages,
            reader: reader,
            parser: emlxParser,
            onToast: { [weak self] in self?.showToast($0) }
        )
    }

    func clearBodySearchIndex() {
        bodyIndex.clear(onToast: { [weak self] in self?.showToast($0) })
    }

    // MARK: - Selection & Sidebar Helpers

    var selectedMessage: MailMessageSummary? {
        guard let id = selectedMessageID else { return nil }
        return messages.first(where: { $0.id == id })
    }

    var totalInboxUnreadCount: Int {
        mailboxes.reduce(0) { sum, mb in
            mb.displayName == "收件箱" ? sum + mb.unreadCount : sum
        }
    }

    func updateDockUnreadBadge() {
        let count = totalInboxUnreadCount
        notificationManager.syncBadgeCount(count)
        MailPilotAppDelegate.shared?.bind(viewModel: self)
        MailPilotAppDelegate.shared?.onMenuBarCompose = { [weak self] in
            self?.openComposeNew()
        }
        MailPilotAppDelegate.shared?.onMenuBarCheckMail = { [weak self] in
            self?.triggerNativeMailFetch()
        }
        MailPilotAppDelegate.shared?.updateMenuBarStatus(visible: showMenuBarExtra, unreadCount: count)
        if showMenuBarExtra {
            refreshMenuBarUnreadPreview()
        }
    }

    func refreshMenuBarUnreadPreview() {
        guard let activeReader = reader else {
            menuBarPreviewGeneration &+= 1
            menuBarPreviewTask?.cancel()
            menuBarPreviewTask = nil
            menuBarCodeGeneration &+= 1
            menuBarCodeTask?.cancel()
            menuBarCodeTask = nil
            menuBarUnreadPreviewState = accessError != nil ? .loaded([]) : .loading
            menuBarRecentVerificationCode = nil
            menuBarUnreadVerificationCodes = [:]
            return
        }
        if case .failed = menuBarUnreadPreviewState {
            menuBarUnreadPreviewState = .loading
        }
        menuBarPreviewGeneration &+= 1
        let generation = menuBarPreviewGeneration
        let mutationVersionAtStart = localListMutationVersion
        let locallyUnreadIDs = pendingReadOverrides.compactMap { $0.value.isRead ? nil : $0.key }
        let locallyExcludedCount = pendingRemovedIDs.count + pendingReadOverrides.values.filter(\.isRead).count
        let fetchLimit = max(15, 5 + locallyExcludedCount)
        let recentCodeCutoff = Date().addingTimeInterval(-15 * 60)
        menuBarPreviewTask?.cancel()
        menuBarPreviewTask = Task { [weak self] in
            do {
                let (fetched, localUnreadExtras, recentInbox) = try await Self.runCancellableDetached(priority: .utility) {
                    try Task.checkCancellation()
                    let page = try activeReader.fetchMessagePage(
                        mailboxID: nil,
                        onlyInbox: true,
                        onlyUnread: true,
                        onlyFlagged: false,
                        onlyWithAttachments: false,
                        sinceDate: nil,
                        searchQuery: "",
                        bodyHitIDs: [],
                        fallbackAttachmentRowIDs: nil,
                        limit: fetchLimit,
                        predicate: nil
                    )
                    try Task.checkCancellation()
                    let extras: [MailMessageSummary]
                    if locallyUnreadIDs.isEmpty {
                        extras = []
                    } else {
                        extras = try activeReader.fetchMessages(byRowIDs: locallyUnreadIDs, onlyInbox: true)
                    }
                    try Task.checkCancellation()
                    let recentPage = (try? activeReader.fetchMessagePage(
                        mailboxID: nil,
                        onlyInbox: true,
                        onlyUnread: false,
                        onlyFlagged: false,
                        onlyWithAttachments: false,
                        sinceDate: recentCodeCutoff,
                        searchQuery: "",
                        bodyHitIDs: [],
                        fallbackAttachmentRowIDs: nil,
                        limit: 8,
                        predicate: nil
                    ).messages) ?? []
                    try Task.checkCancellation()
                    return (page.messages, extras, recentPage)
                }
                guard !Task.isCancelled, let self,
                      self.menuBarPreviewGeneration == generation,
                      self.reader === activeReader else {
                    return
                }
                if self.localListMutationVersion != mutationVersionAtStart {
                    self.refreshMenuBarUnreadPreview()
                    return
                }

                var byID: [Int64: MailMessageSummary] = [:]
                for msg in fetched {
                    guard !self.pendingRemovedIDs.contains(msg.id) else { continue }
                    if let override = self.pendingReadOverrides[msg.id], override.isRead { continue }
                    byID[msg.id] = msg
                }
                for msg in localUnreadExtras {
                    guard !self.pendingRemovedIDs.contains(msg.id) else { continue }
                    if let override = self.pendingReadOverrides[msg.id], override.isRead { continue }
                    byID[msg.id] = MailMessageSummary(
                        id: msg.id,
                        messageIDHeader: msg.messageIDHeader,
                        subject: msg.subject,
                        senderAddress: msg.senderAddress,
                        senderName: msg.senderName,
                        dateReceived: msg.dateReceived,
                        isRead: false,
                        isFlagged: msg.isFlagged,
                        mailboxID: msg.mailboxID,
                        mailboxName: msg.mailboxName,
                        accountID: msg.accountID
                    )
                }

                let merged = byID.values.sorted {
                    if $0.dateReceived != $1.dateReceived {
                        return $0.dateReceived > $1.dateReceived
                    }
                    return $0.id > $1.id
                }
                let topUnread = Array(merged.prefix(5))
                let nextState: MenuBarUnreadPreviewState = .loaded(topUnread)
                if self.menuBarUnreadPreviewState != nextState {
                    self.menuBarUnreadPreviewState = nextState
                }

                // Combine top unread messages and recent 15-minute inbox messages (including read)
                // so fresh 2FA codes stay one-click copyable even when the inbox reads "全部已读".
                var codeCandidatesByID: [Int64: MailMessageSummary] = [:]
                for msg in topUnread {
                    codeCandidatesByID[msg.id] = msg
                }
                for msg in recentInbox {
                    guard !self.pendingRemovedIDs.contains(msg.id) else { continue }
                    if codeCandidatesByID[msg.id] != nil { continue }
                    if let override = self.pendingReadOverrides[msg.id], override.isRead != msg.isRead {
                        codeCandidatesByID[msg.id] = MailMessageSummary(
                            id: msg.id,
                            messageIDHeader: msg.messageIDHeader,
                            subject: msg.subject,
                            senderAddress: msg.senderAddress,
                            senderName: msg.senderName,
                            dateReceived: msg.dateReceived,
                            isRead: override.isRead,
                            isFlagged: msg.isFlagged,
                            mailboxID: msg.mailboxID,
                            mailboxName: msg.mailboxName,
                            accountID: msg.accountID
                        )
                    } else {
                        codeCandidatesByID[msg.id] = msg
                    }
                }
                let codeCandidates = codeCandidatesByID.values.sorted {
                    if $0.dateReceived != $1.dateReceived {
                        return $0.dateReceived > $1.dateReceived
                    }
                    return $0.id > $1.id
                }
                self.refreshMenuBarVerificationCodes(
                    for: codeCandidates,
                    topUnreadIDs: Set(topUnread.map(\.id)),
                    activeReader: activeReader
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self,
                      self.menuBarPreviewGeneration == generation,
                      self.reader === activeReader else {
                    return
                }
                self.menuBarUnreadPreviewState = .failed
            }
        }
    }

    func cacheVerificationCode(_ code: String?, for rowID: Int64) {
        if cachedVerificationCodes[rowID] == nil {
            cachedVerificationOrder.append(rowID)
            if cachedVerificationOrder.count > Self.maxCachedVerificationEntries {
                let evicted = cachedVerificationOrder.removeFirst()
                cachedVerificationCodes.removeValue(forKey: evicted)
            }
        }
        cachedVerificationCodes[rowID] = code
    }

    func recordIncomingVerificationCode(_ code: String, for message: MailMessageSummary) {
        guard !code.isEmpty, !pendingRemovedIDs.contains(message.id) else { return }
        cacheVerificationCode(code, for: message.id)
        if !message.isRead {
            menuBarUnreadVerificationCodes[message.id] = code
        }
        let candidate = RecentVerificationCode(
            messageID: message.id,
            code: code,
            sender: message.displaySender,
            subject: message.subject,
            dateReceived: message.dateReceived,
            isUnread: !message.isRead
        )
        if let existing = menuBarRecentVerificationCode {
            if candidate.dateReceived >= existing.dateReceived || candidate.messageID == existing.messageID {
                menuBarRecentVerificationCode = candidate
            }
        } else {
            menuBarRecentVerificationCode = candidate
        }
    }

    func copyVerificationCode(_ code: String, messageID: Int64) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        let markedRead = markVerificationMessageReadIfNeeded(rowID: messageID)
        copiedVerificationMessageID = messageID
        menuBarCopyFeedbackText = markedRead
            ? "已复制 \(code) · 已标为已读"
            : "已复制验证码 \(code)"
        copiedCodeResetTask?.cancel()
        copiedCodeResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled, let self, self.copiedVerificationMessageID == messageID else { return }
            self.copiedVerificationMessageID = nil
            self.menuBarCopyFeedbackText = nil
        }
    }

    @discardableResult
    private func markVerificationMessageReadIfNeeded(rowID: Int64) -> Bool {
        // Skip if a mark-read write is already in flight for this row.
        if let existingOverride = pendingReadOverrides[rowID], existingOverride.isRead {
            return false
        }

        let messageInList = messages.first(where: { $0.id == rowID })
        let messageInPreview: MailMessageSummary?
        if case .loaded(let items) = menuBarUnreadPreviewState {
            messageInPreview = items.first(where: { $0.id == rowID })
        } else {
            messageInPreview = nil
        }

        let isUnread = (pendingReadOverrides[rowID]?.isRead == false)
            || (messageInList?.isRead == false)
            || (messageInPreview != nil)
            || (menuBarUnreadVerificationCodes[rowID] != nil)
            || (menuBarRecentVerificationCode?.messageID == rowID && menuBarRecentVerificationCode?.isUnread == true)
        guard isUnread else { return false }

        if autoMarkReadTargetID == rowID {
            autoMarkReadTask?.cancel()
            autoMarkReadTask = nil
            autoMarkReadTargetID = nil
        }

        let readToken = beginReadOverride(rowID: rowID, isRead: true)
        menuBarUnreadVerificationCodes.removeValue(forKey: rowID)
        if let banner = menuBarRecentVerificationCode, banner.messageID == rowID {
            menuBarRecentVerificationCode = RecentVerificationCode(
                messageID: banner.messageID,
                code: banner.code,
                sender: banner.sender,
                subject: banner.subject,
                dateReceived: banner.dateReceived,
                isUnread: false
            )
        }

        if messageInList != nil {
            updateLocalReadState(rowID: rowID, isRead: true)
            if sidebarSelection == .unread,
               let updated = messages.first(where: { $0.id == rowID }) {
                sessionKeptUnreadMessages[rowID] = updated
            }
        } else {
            if let previewMsg = messageInPreview {
                pendingReadOriginals[rowID] = (message: previewMsg, isInbox: true)
                adjustLocalUnreadCount(for: previewMsg, delta: -1)
            }
            updateLocalReadState(rowID: rowID, isRead: true)
            notificationManager.removeDeliveredNotification(for: rowID)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await MailAppleScriptBridge.setReadStatus(rowID: rowID, isRead: true)
                try? await Task.sleep(for: .milliseconds(500))
                self.finishReadOverride(rowID: rowID, token: readToken, succeeded: true, fallbackIsRead: false)
                self.refreshNow()
            } catch {
                self.sessionKeptUnreadMessages.removeValue(forKey: rowID)
                self.finishReadOverride(rowID: rowID, token: readToken, succeeded: false, fallbackIsRead: false)
                self.refreshNow()
                self.showToast("标记已读失败：请在系统设置 → 自动化中允许控制「邮件」")
            }
        }
        return true
    }

    private func refreshMenuBarVerificationCodes(
        for candidates: [MailMessageSummary],
        topUnreadIDs: Set<Int64>,
        activeReader: EnvelopeIndexReader
    ) {
        let now = Date()
        let recentWindowCutoff = now.addingTimeInterval(-15 * 60)

        // Pass 1 (synchronous, 0ms): inspect subject + in-memory cache so popover renders immediately.
        // Always extract codes for all visible unread preview rows (<= 5) regardless of age,
        // plus any recent 15-minute inbox messages (including read).
        var toParseFromDisk: [MailMessageSummary] = []
        for msg in candidates {
            if let subjectCode = EmlxParser.extractVerificationCode(from: msg.subject) {
                cacheVerificationCode(subjectCode, for: msg.id)
                continue
            }
            if cachedVerificationCodes[msg.id] != nil {
                continue
            }
            if topUnreadIDs.contains(msg.id) || msg.dateReceived >= recentWindowCutoff {
                toParseFromDisk.append(msg)
            }
        }

        commitMenuBarVerificationCodes(
            candidates: candidates,
            topUnreadIDs: topUnreadIDs,
            recentWindowCutoff: recentWindowCutoff
        )

        guard !toParseFromDisk.isEmpty, let parser = emlxParser else {
            menuBarCodeTask?.cancel()
            menuBarCodeTask = nil
            return
        }

        let limitedToParse = Array(toParseFromDisk.prefix(10))
        menuBarCodeGeneration &+= 1
        let generation = menuBarCodeGeneration
        menuBarCodeTask?.cancel()
        menuBarCodeTask = Task { [weak self] in
            var parsedResults: [(id: Int64, code: String?)] = []
            parsedResults.reserveCapacity(limitedToParse.count)
            for msg in limitedToParse {
                if Task.isCancelled { return }
                let body = await parser.loadBody(for: msg.id)
                if Task.isCancelled { return }
                if body.loadStatus == .ready {
                    parsedResults.append((msg.id, body.verificationCode))
                }
            }
            guard !Task.isCancelled, let self,
                  self.menuBarCodeGeneration == generation,
                  self.reader === activeReader else {
                return
            }
            for item in parsedResults {
                self.cacheVerificationCode(item.code, for: item.id)
            }
            let liveCandidates = candidates.filter { !self.pendingRemovedIDs.contains($0.id) }
            self.commitMenuBarVerificationCodes(
                candidates: liveCandidates,
                topUnreadIDs: topUnreadIDs,
                recentWindowCutoff: recentWindowCutoff
            )
        }
    }

    private func commitMenuBarVerificationCodes(
        candidates: [MailMessageSummary],
        topUnreadIDs: Set<Int64>,
        recentWindowCutoff: Date
    ) {
        var unreadCodes: [Int64: String] = [:]
        var latestRecentReadBanner: RecentVerificationCode?

        for msg in candidates {
            guard !pendingRemovedIDs.contains(msg.id),
                  let cachedEntry = cachedVerificationCodes[msg.id],
                  let code = cachedEntry,
                  !code.isEmpty else {
                continue
            }
            let effectiveRead = pendingReadOverrides[msg.id]?.isRead ?? msg.isRead
            if topUnreadIDs.contains(msg.id) && !effectiveRead {
                unreadCodes[msg.id] = code
            }
            // Promote a standalone top banner only for fresh (< 15 min) codes that are not
            // already displayed with an inline copy button in the unread list below.
            if latestRecentReadBanner == nil && msg.dateReceived >= recentWindowCutoff && unreadCodes[msg.id] == nil {
                latestRecentReadBanner = RecentVerificationCode(
                    messageID: msg.id,
                    code: code,
                    sender: msg.displaySender,
                    subject: msg.subject,
                    dateReceived: msg.dateReceived,
                    isUnread: !effectiveRead
                )
            }
        }

        if menuBarUnreadVerificationCodes != unreadCodes {
            menuBarUnreadVerificationCodes = unreadCodes
        }
        if menuBarRecentVerificationCode != latestRecentReadBanner {
            menuBarRecentVerificationCode = latestRecentReadBanner
        }
    }

    func openMessageFromMenuBar(_ rowID: Int64) {
        jumpToMessage(rowID: rowID)
    }

    func jumpToMessage(rowID: Int64) {
        MailPilotAppDelegate.shared?.showMainWindow()
        autoMarkReadTask?.cancel()
        autoMarkReadTask = nil
        autoMarkReadTargetID = nil
        searchDebounceTask?.cancel()
        pendingJumpMessageID = rowID
        pinnedJumpMessageID = rowID
        suppressAutoSelectFirstMessage = false

        suppressFilterReload = true
        sidebarSelection = .allInbox
        searchQuery = ""
        filterUnreadOnly = false
        filterHasAttachments = false
        filterDateRange = .all
        currentPageLimit = 200
        suppressFilterReload = false

        reloadMessages()
    }

    private func observeAppLifecycle() {
        let finishLaunching = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Re-apply badge after NSApp.setActivationPolicy(.regular) completes.
                self?.updateDockUnreadBadge()
                try? await Task.sleep(for: .milliseconds(400))
                self?.updateDockUnreadBadge()
            }
        }
        let becomeActive = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateDockUnreadBadge()
                self?.refreshNow()
            }
        }
        appLifecycleObservers = [finishLaunching, becomeActive]
    }

    var isShowingInboxScopedView: Bool {
        switch sidebarSelection {
        case .allInbox, .unread, .smartTag:
            return true
        case .flagged, .mailbox:
            return false
        }
    }

    var isUnifiedView: Bool {
        if case .mailbox = sidebarSelection {
            return false
        }
        return true
    }

    func isSectionCollapsed(_ sectionID: String) -> Bool {
        collapsedSidebarSections.contains(sectionID)
    }

    func toggleSectionCollapsed(_ sectionID: String) {
        if collapsedSidebarSections.contains(sectionID) {
            collapsedSidebarSections.remove(sectionID)
        } else {
            collapsedSidebarSections.insert(sectionID)
        }
    }

    // MARK: - Connection & Sync

    /// Triggers an immediate Mail.app fetch when the Mac wakes from sleep so new mail arrives right away.
    private func observeSystemWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                try? await MailAppleScriptBridge.triggerCheckForNewMail()
                self?.refreshNow()
            }
        }
    }

    func connectToNativeMail() {
        watcher?.stop()
        watcher = nil
        isWatchingLive = false

        do {
            let discovered = try EnvelopeIndexReader.discoverDefault()
            self.reader = discovered
            self.emlxParser = EmlxParser(mailRootURL: discovered.mailVersionURL)
            self.accessError = nil

            let mailDataDir = discovered.databaseURL.deletingLastPathComponent()
            self.watcher = MailDirectoryWatcher(directoryURL: mailDataDir) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleLiveFileChange()
                }
            }
            self.isWatchingLive = true
            self.statusText = "已实时监听 \(discovered.mailVersionURL.lastPathComponent)"
            seedInitialRowIDWatermark()
            refreshNow()
        } catch let err as MailAccessError {
            self.accessError = err
            self.statusText = "等待授权"
        } catch {
            self.accessError = .queryFailed(message: error.localizedDescription)
            self.statusText = "连接失败"
        }
    }

    /// Runs a detached operation while propagating cancellation from the calling Swift concurrency task.
    private nonisolated static func runCancellableDetached<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let detached = Task.detached(priority: priority, operation: operation)
        return try await withTaskCancellationHandler {
            try await detached.value
        } onCancel: {
            detached.cancel()
        }
    }

    func refreshNow() {
        guard let reader else {
            connectToNativeMail()
            return
        }
        // Coalesce concurrent WAL/manual refresh bursts into at most one follow-up pass.
        if isRefreshingMailboxes {
            needsFollowUpRefresh = true
            return
        }
        isRefreshingMailboxes = true
        needsFollowUpRefresh = false

        Task { [weak self] in
            defer {
                if let self {
                    self.isRefreshingMailboxes = false
                    if self.needsFollowUpRefresh {
                        self.needsFollowUpRefresh = false
                        self.refreshNow()
                    }
                }
            }
            do {
                let fetchedMailboxes = try await Self.runCancellableDetached(priority: .userInitiated) {
                    try reader.fetchMailboxes()
                }
                guard let self else { return }
                if self.mailboxes != fetchedMailboxes {
                    self.mailboxes = fetchedMailboxes
                } else {
                    self.updateDockUnreadBadge()
                }
                if self.accessError != nil {
                    self.accessError = nil
                }
                self.syncAccountsIfUnknownMailboxPresent(fetchedMailboxes)
                self.reloadMessages()
                if self.hasSeededNotificationWatermark {
                    Task { [weak self] in
                        await self?.checkAndNotifyIncomingMail()
                    }
                }
            } catch is CancellationError {
                return
            } catch let err as MailAccessError {
                self?.accessError = err
                self?.statusText = "读取失败"
            } catch {
                self?.statusText = "读取异常：\(error.localizedDescription)"
            }
        }
    }

    func reloadMessages() {
        guard let reader else { return }
        let mailboxID: Int64?
        let onlyInbox: Bool
        let onlyUnread: Bool
        let onlyFlagged: Bool
        let filterTag: MailSmartTag?

        switch sidebarSelection {
        case .allInbox:
            mailboxID = nil
            onlyInbox = true
            onlyUnread = false
            onlyFlagged = false
            filterTag = nil
        case .unread:
            mailboxID = nil
            onlyInbox = true
            onlyUnread = true
            onlyFlagged = false
            filterTag = nil
        case .flagged:
            mailboxID = nil
            onlyInbox = false
            onlyUnread = false
            onlyFlagged = true
            filterTag = nil
        case .smartTag(let tag):
            mailboxID = nil
            onlyInbox = true
            onlyUnread = false
            onlyFlagged = false
            filterTag = tag
        case .mailbox(let id):
            mailboxID = id
            onlyInbox = false
            onlyUnread = false
            onlyFlagged = false
            filterTag = nil
        }

        let query = searchQuery
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveOnlyUnread = onlyUnread || filterUnreadOnly
        let effectiveOnlyAttachments = filterHasAttachments
        let effectiveSinceDate = filterDateRange.cutoffDate
        let currentTagSettings = tagSettings
        let baseLimit = filterTag != nil ? max(400, currentPageLimit) : currentPageLimit
        let indexCoordinator = bodyIndex
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let mutationVersionAtStart = localListMutationVersion
        let jumpTargetID = pendingJumpMessageID
        let pinnedIDToInclude: Int64? = jumpTargetID ?? (
            (sidebarSelection == .allInbox && trimmedQuery.isEmpty && !hasActiveSearchFilters)
                ? pinnedJumpMessageID
                : nil
        )
        reloadTask?.cancel()
        snippetFetchTask?.cancel()

        reloadTask = Task { [weak self] in
            do {
                // Return all matching ROWIDs globally (limit: nil) BEFORE applying mailbox/inbox filters in SQL
                // so inbox hits behind thousands of non-inbox hits are never truncated to 0.
                let bodyHitIDs: [Int64] = trimmedQuery.isEmpty
                    ? []
                    : await indexCoordinator.searchRowIDs(query: trimmedQuery, limit: nil)
                guard !Task.isCancelled, let self, self.reloadGeneration == generation else { return }

                let fallbackAttachmentRowIDs: Set<Int64>? = effectiveOnlyAttachments
                    ? await indexCoordinator.fetchRowIDsWithAttachments()
                    : nil
                guard !Task.isCancelled, self.reloadGeneration == generation else { return }

                let (page, precomputedTags, pinnedFetchedMessage) = try await Self.runCancellableDetached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let preparedRules = MailTagClassifier.PreparedRules(settings: currentTagSettings)
                    let tagPredicate: ((MailMessageSummary) -> Bool)? = filterTag.map { tag in
                        { MailTagClassifier.classify($0, prepared: preparedRules).contains(tag) }
                    }
                    let result = try reader.fetchMessagePage(
                        mailboxID: mailboxID,
                        onlyInbox: onlyInbox,
                        onlyUnread: effectiveOnlyUnread,
                        onlyFlagged: onlyFlagged,
                        onlyWithAttachments: effectiveOnlyAttachments,
                        sinceDate: effectiveSinceDate,
                        searchQuery: query,
                        bodyHitIDs: bodyHitIDs,
                        fallbackAttachmentRowIDs: fallbackAttachmentRowIDs,
                        limit: baseLimit,
                        predicate: tagPredicate
                    )
                    try Task.checkCancellation()
                    var pinnedMsg: MailMessageSummary?
                    if let pinnedIDToInclude, !result.messages.contains(where: { $0.id == pinnedIDToInclude }) {
                        pinnedMsg = try? reader.fetchMessages(byRowIDs: [pinnedIDToInclude], onlyInbox: onlyInbox).first
                    }
                    try Task.checkCancellation()
                    var tagMap: [Int64: [MailSmartTag]] = [:]
                    tagMap.reserveCapacity(result.messages.count + (pinnedMsg == nil ? 0 : 1))
                    for msg in result.messages {
                        tagMap[msg.id] = MailTagClassifier.classify(msg, prepared: preparedRules)
                    }
                    if let pinnedMsg {
                        tagMap[pinnedMsg.id] = MailTagClassifier.classify(pinnedMsg, prepared: preparedRules)
                    }
                    return (result, tagMap, pinnedMsg)
                }
                guard !Task.isCancelled, self.reloadGeneration == generation else { return }

                // Reject stale DB snapshots that crossed a local archive/delete/read mutation
                // and immediately re-query so removed rows never flash back and read states never revert.
                if self.localListMutationVersion != mutationVersionAtStart {
                    self.reloadMessages()
                    return
                }

                // Apply active optimistic removals & read-state overrides right before committing synchronously.
                var filtered: [MailMessageSummary] = page.messages.compactMap { msg in
                    guard !self.pendingRemovedIDs.contains(msg.id) else { return nil }
                    if let overrideEntry = self.pendingReadOverrides[msg.id], overrideEntry.isRead != msg.isRead {
                        return MailMessageSummary(
                            id: msg.id,
                            messageIDHeader: msg.messageIDHeader,
                            subject: msg.subject,
                            senderAddress: msg.senderAddress,
                            senderName: msg.senderName,
                            dateReceived: msg.dateReceived,
                            isRead: overrideEntry.isRead,
                            isFlagged: msg.isFlagged,
                            mailboxID: msg.mailboxID,
                            mailboxName: msg.mailboxName,
                            accountID: msg.accountID
                        )
                    }
                    return msg
                }

                // Keep a jumped/pinned older inbox message present across both the initial jump and subsequent WAL reloads.
                if let pinnedIDToInclude,
                   !filtered.contains(where: { $0.id == pinnedIDToInclude }),
                   let pinnedFetchedMessage,
                   !self.pendingRemovedIDs.contains(pinnedIDToInclude) {
                    let adjustedPinned: MailMessageSummary
                    if let overrideEntry = self.pendingReadOverrides[pinnedIDToInclude], overrideEntry.isRead != pinnedFetchedMessage.isRead {
                        adjustedPinned = MailMessageSummary(
                            id: pinnedFetchedMessage.id,
                            messageIDHeader: pinnedFetchedMessage.messageIDHeader,
                            subject: pinnedFetchedMessage.subject,
                            senderAddress: pinnedFetchedMessage.senderAddress,
                            senderName: pinnedFetchedMessage.senderName,
                            dateReceived: pinnedFetchedMessage.dateReceived,
                            isRead: overrideEntry.isRead,
                            isFlagged: pinnedFetchedMessage.isFlagged,
                            mailboxID: pinnedFetchedMessage.mailboxID,
                            mailboxName: pinnedFetchedMessage.mailboxName,
                            accountID: pinnedFetchedMessage.accountID
                        )
                    } else {
                        adjustedPinned = pinnedFetchedMessage
                    }
                    filtered.append(adjustedPinned)
                    filtered.sort {
                        if $0.dateReceived != $1.dateReceived {
                            return $0.dateReceived > $1.dateReceived
                        }
                        return $0.id > $1.id
                    }
                }

                if self.sidebarSelection == .unread && trimmedQuery.isEmpty && !self.sessionKeptUnreadMessages.isEmpty {
                    let existingIDs = Set(filtered.map(\.id))
                    var mergedTags = precomputedTags
                    let keptExtras = self.sessionKeptUnreadMessages.values.filter {
                        !existingIDs.contains($0.id) && !self.pendingRemovedIDs.contains($0.id)
                    }
                    if !keptExtras.isEmpty {
                        filtered.append(contentsOf: keptExtras)
                        filtered.sort {
                            if $0.dateReceived != $1.dateReceived {
                                return $0.dateReceived > $1.dateReceived
                            }
                            return $0.id > $1.id
                        }
                        for msg in keptExtras where mergedTags[msg.id] == nil {
                            mergedTags[msg.id] = MailTagClassifier.classify(msg, settings: self.tagSettings)
                        }
                    }
                    self.cachedMessageTags = mergedTags
                } else {
                    self.cachedMessageTags = precomputedTags
                }

                // Commit message page & selection immediately before any secondary awaits.
                let messagesChanged = self.messages != filtered
                if messagesChanged {
                    self.messages = filtered
                }
                if self.hasMoreMessages != page.hasMore {
                    self.hasMoreMessages = page.hasMore
                }
                if let jumpTargetID {
                    if self.pendingJumpMessageID == jumpTargetID {
                        self.pendingJumpMessageID = nil
                    }
                    if filtered.contains(where: { $0.id == jumpTargetID }) {
                        self.suppressAutoSelectFirstMessage = false
                        self.pinnedJumpMessageID = jumpTargetID
                        self.selectedMessageID = jumpTargetID
                        if self.selectedMessageIDs != [jumpTargetID] {
                            self.selectedMessageIDs = [jumpTargetID]
                        }
                        self.scheduleAutoMarkReadIfNeeded(for: jumpTargetID)
                    } else {
                        self.pinnedJumpMessageID = nil
                        self.suppressAutoSelectFirstMessage = true
                        self.autoMarkReadTask?.cancel()
                        self.autoMarkReadTask = nil
                        self.autoMarkReadTargetID = nil
                        self.selectedMessageID = nil
                        if !self.selectedMessageIDs.isEmpty {
                            self.selectedMessageIDs = []
                        }
                        self.showToast("该邮件已不在收件箱中或已被删除")
                    }
                } else if let current = self.selectedMessageID, !filtered.contains(where: { $0.id == current }) {
                    if self.pinnedJumpMessageID == current {
                        self.pinnedJumpMessageID = nil
                        self.suppressAutoSelectFirstMessage = true
                        self.autoMarkReadTask?.cancel()
                        self.autoMarkReadTask = nil
                        self.autoMarkReadTargetID = nil
                        self.selectedMessageID = nil
                        if !self.selectedMessageIDs.isEmpty {
                            self.selectedMessageIDs = []
                        }
                    } else if let firstID = filtered.first?.id {
                        self.selectedMessageID = firstID
                        if self.selectedMessageIDs != [firstID] {
                            self.selectedMessageIDs = [firstID]
                        }
                    } else {
                        self.selectedMessageID = nil
                        if !self.selectedMessageIDs.isEmpty {
                            self.selectedMessageIDs = []
                        }
                    }
                } else if self.selectedMessageID == nil {
                    if !self.suppressAutoSelectFirstMessage, let firstID = filtered.first?.id {
                        self.selectedMessageID = firstID
                        if self.selectedMessageIDs != [firstID] {
                            self.selectedMessageIDs = [firstID]
                        }
                    }
                } else if let current = self.selectedMessageID {
                    self.scheduleAutoMarkReadIfNeeded(for: current)
                }

                // Prune any vanished IDs from multi-selection after committing single selection.
                let validFilteredIDs = Set(filtered.map(\.id))
                let prunedSelection = self.selectedMessageIDs.intersection(validFilteredIDs)
                if self.selectedMessageIDs != prunedSelection {
                    self.selectedMessageIDs = prunedSelection
                }

                // Incrementally hydrate missing/pending snippets in the background without blocking list display.
                self.refreshVisibleSnippets(for: filtered.map(\.id))

                if trimmedQuery.isEmpty && (messagesChanged || indexCoordinator.needsFullSweep) {
                    indexCoordinator.scheduleIndexing(
                        visiblePriority: filtered,
                        reader: self.reader,
                        parser: self.emlxParser
                    )
                }

                let countIndexed = await indexCoordinator.refreshIndexedCount()
                guard !Task.isCancelled, self.reloadGeneration == generation else { return }
                let liveCount = self.messages.count
                let newStatus = trimmedQuery.isEmpty
                    ? "实时同步 · \(liveCount) 封（已索引 \(countIndexed) 正文）"
                    : "搜索结果 · \(liveCount)\(page.hasMore ? "+" : "") 封（已索引 \(countIndexed) 正文）"
                if self.statusText != newStatus {
                    self.statusText = newStatus
                }
            } catch is CancellationError {
                return
            } catch let err as MailAccessError {
                guard let self, self.reloadGeneration == generation else { return }
                self.accessError = err
            } catch {
                guard let self, self.reloadGeneration == generation else { return }
                self.statusText = "查询失败：\(error.localizedDescription)"
            }
        }
    }

    private func invalidateAllSnippets() {
        snippetGeneration &+= 1
        snippetFetchTask?.cancel()
        snippetFetchTask = nil
        pendingSnippetRefreshIDs.removeAll()
        if !messageSnippets.isEmpty {
            messageSnippets = [:]
        }
    }

    private func removeSnippets(for rowIDs: [Int64]) {
        guard !rowIDs.isEmpty else { return }
        snippetGeneration &+= 1
        snippetFetchTask?.cancel()
        snippetFetchTask = nil
        for id in rowIDs {
            pendingSnippetRefreshIDs.remove(id)
        }
        if !messageSnippets.isEmpty {
            var updated = messageSnippets
            var changed = false
            for id in rowIDs where updated.removeValue(forKey: id) != nil {
                changed = true
            }
            if changed {
                messageSnippets = updated
            }
        }
        if !pendingSnippetRefreshIDs.isEmpty && !messages.isEmpty {
            refreshVisibleSnippets(for: messages.map(\.id))
        }
    }

    private func handleIndexedRowIDsUpdated(_ updatedIDs: [Int64]) {
        guard !updatedIDs.isEmpty, !messages.isEmpty else { return }
        let visibleSet = Set(messages.map(\.id))
        var addedAny = false
        for id in updatedIDs where visibleSet.contains(id) {
            if pendingSnippetRefreshIDs.insert(id).inserted {
                addedAny = true
            }
        }
        guard addedAny || !pendingSnippetRefreshIDs.isEmpty else { return }
        refreshVisibleSnippets(for: messages.map(\.id))
    }

    private func refreshVisibleSnippets(for visibleIDs: [Int64]) {
        let visibleSet = Set(visibleIDs)
        // Drop cached & pending snippet entries for rows no longer in the active list.
        if messageSnippets.keys.contains(where: { !visibleSet.contains($0) }) {
            messageSnippets = messageSnippets.filter { visibleSet.contains($0.key) }
        }
        if !pendingSnippetRefreshIDs.isEmpty {
            pendingSnippetRefreshIDs = pendingSnippetRefreshIDs.intersection(visibleSet)
        }

        let pendingSnapshot = pendingSnippetRefreshIDs
        let idsToFetch = visibleIDs.filter { pendingSnapshot.contains($0) || messageSnippets[$0] == nil }
        guard !idsToFetch.isEmpty else { return }

        let indexCoordinator = bodyIndex
        snippetGeneration &+= 1
        let gen = snippetGeneration
        snippetFetchTask?.cancel()
        snippetFetchTask = Task { [weak self] in
            let rawSnippets = await indexCoordinator.fetchSnippets(for: idsToFetch, maxChars: 180)
            guard !Task.isCancelled, let self, self.snippetGeneration == gen else { return }
            let currentVisible = Set(self.messages.map(\.id))
            var merged = self.messageSnippets
            var changed = false
            for id in idsToFetch {
                self.pendingSnippetRefreshIDs.remove(id)
                guard currentVisible.contains(id) else { continue }
                if let raw = rawSnippets[id] {
                    let cleaned = Self.cleanListSnippet(raw)
                    if merged[id] != cleaned {
                        merged[id] = cleaned
                        changed = true
                    }
                }
            }
            if changed {
                self.messageSnippets = merged
            }
        }
    }

    private static func cleanListSnippet(_ raw: String) -> String? {
        var text = raw
        // BodyIndexCoordinator appends attachment filenames using the unambiguous record separator "\n\u{001E}[附件] ".
        if let range = text.range(of: "\n\u{001E}[附件] ") {
            text = String(text[..<range.lowerBound])
        } else if let range = text.range(of: "\u{001E}[附件] ") {
            text = String(text[..<range.lowerBound])
        }
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= 120 {
            return collapsed
        }
        return String(collapsed.prefix(120)) + "…"
    }

    func loadMoreMessages() {
        let effectiveCurrent: Int
        if case .smartTag = sidebarSelection {
            effectiveCurrent = max(400, currentPageLimit)
        } else {
            effectiveCurrent = currentPageLimit
        }
        currentPageLimit = effectiveCurrent + 200
        reloadMessages()
    }

    private func handleLiveFileChange() {
        // Keep EmlxParser's existing path cache warm (fast O(1) bucket lookup finds new .emlx without rescanning).
        refreshNow()
        Task { [weak self] in
            await self?.checkAndNotifyIncomingMail()
        }
    }

    private func scheduleSearchReload() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            reloadMessages()
        }
    }

    // MARK: - Smart Tags

    func tags(for message: MailMessageSummary) -> [MailSmartTag] {
        cachedMessageTags[message.id] ?? MailTagClassifier.classify(message, settings: tagSettings)
    }

    private func recomputeCachedTags() {
        let prepared = MailTagClassifier.PreparedRules(settings: tagSettings)
        var fresh: [Int64: [MailSmartTag]] = [:]
        fresh.reserveCapacity(messages.count)
        for msg in messages {
            fresh[msg.id] = MailTagClassifier.classify(msg, prepared: prepared)
        }
        cachedMessageTags = fresh
    }

    func setTag(_ tag: MailSmartTag, enabled: Bool) {
        if enabled {
            tagSettings.enabledTagIDs.insert(tag.rawValue)
        } else {
            tagSettings.enabledTagIDs.remove(tag.rawValue)
        }
    }

    func setCustomKeywords(_ keywords: String, for tag: MailSmartTag) {
        tagSettings.customKeywords[tag.rawValue] = keywords
    }

    func resetTagSettings() {
        tagSettings = MailTagSettings()
        showToast("已恢复默认标签配置")
    }

    private func saveTagSettings() {
        if let data = try? JSONEncoder().encode(tagSettings) {
            UserDefaults.standard.set(data, forKey: Self.tagSettingsStorageKey)
        }
    }

    // MARK: - Body Loading & LRU Cache

    private func cachedBody(for id: Int64) -> CachedRenderedBody? {
        guard let entry = recentBodyCache[id] else { return nil }
        if let idx = recentBodyOrder.firstIndex(of: id) {
            recentBodyOrder.remove(at: idx)
        }
        recentBodyOrder.append(id)
        return entry
    }

    private func storeCachedBody(_ entry: CachedRenderedBody, for id: Int64) {
        let body = entry.body
        guard body.loadStatus == .ready else { return }
        let approxBytes = body.plainText.utf8.count
            + (body.rawHTML?.utf8.count ?? 0)
            + body.attachments.reduce(0) { $0 + ($1.inlineData?.count ?? 0) }
        guard approxBytes <= Self.maxCacheableBodyBytes else { return }
        if let idx = recentBodyOrder.firstIndex(of: id) {
            recentBodyOrder.remove(at: idx)
        }
        recentBodyOrder.append(id)
        recentBodyCache[id] = entry
        while recentBodyOrder.count > Self.maxRecentBodyCacheEntries {
            let evicted = recentBodyOrder.removeFirst()
            recentBodyCache.removeValue(forKey: evicted)
        }
    }

    private func loadSelectedMessageBody() {
        ai.resetForSelectedMessage(id: selectedMessageID)
        autoMarkReadTask?.cancel()
        autoMarkReadTask = nil
        autoMarkReadTargetID = nil
        bodyLoadTask?.cancel()
        bodyLoadTask = nil
        recipientsLoadTask?.cancel()
        recipientsLoadTask = nil
        // Immediately clear previous email's body & recipients so Reply/Forward/Attachments/AI can never read stale content.
        selectedBody = nil
        selectedBodyMessageID = nil
        selectedMessageRecipients = []
        selectedPlainAttributedText = AttributedString("")
        selectedBodyHasRemoteResources = false

        guard let id = selectedMessageID, let parser = emlxParser else {
            isLoadingBody = false
            return
        }
        if let reader {
            recipientsLoadTask = Task { [weak self] in
                let fetched = await Task.detached(priority: .userInitiated) {
                    (try? reader.fetchRecipients(for: id)) ?? []
                }.value
                guard !Task.isCancelled, let self, self.selectedMessageID == id else { return }
                self.selectedMessageRecipients = fetched
            }
        }
        if let cached = cachedBody(for: id) {
            selectedBody = cached.body
            selectedBodyMessageID = id
            selectedPlainAttributedText = cached.attributedPlain
            selectedBodyHasRemoteResources = cached.hasRemoteResources
            isLoadingBody = false
        } else {
            isLoadingBody = true
            bodyLoadTask = Task { [weak self] in
                do {
                    let rendered = try await Self.runCancellableDetached(priority: .userInitiated) { () async throws -> CachedRenderedBody in
                        try Task.checkCancellation()
                        let parsed = await parser.loadBody(for: id)
                        try Task.checkCancellation()
                        let attrPlain = MailBodyPresentationHelper.linkify(parsed.plainText)
                        let hasRemote = parsed.rawHTML.map { MailBodyPresentationHelper.containsRemoteResourceURL($0) } ?? false
                        return CachedRenderedBody(body: parsed, attributedPlain: attrPlain, hasRemoteResources: hasRemote)
                    }
                    guard !Task.isCancelled, let self, self.selectedMessageID == id else { return }
                    self.storeCachedBody(rendered, for: id)
                    self.selectedBody = rendered.body
                    self.selectedBodyMessageID = id
                    self.selectedPlainAttributedText = rendered.attributedPlain
                    self.selectedBodyHasRemoteResources = rendered.hasRemoteResources
                    self.isLoadingBody = false
                } catch is CancellationError {
                    return
                } catch {
                    if let self, self.selectedMessageID == id {
                        self.isLoadingBody = false
                    }
                }
            }
        }

        scheduleAutoMarkReadIfNeeded(for: id)
    }

    private func scheduleAutoMarkReadIfNeeded(for id: Int64) {
        guard let msg = messages.first(where: { $0.id == id }), !msg.isRead else { return }
        if autoMarkReadTargetID == id && autoMarkReadTask != nil {
            return
        }
        autoMarkReadTask?.cancel()
        autoMarkReadTargetID = id
        autoMarkReadTask = Task { [weak self] in
            defer {
                if let self, self.autoMarkReadTargetID == id {
                    self.autoMarkReadTargetID = nil
                    self.autoMarkReadTask = nil
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, self.selectedMessageID == id else { return }
            let readToken = self.beginReadOverride(rowID: id, isRead: true)
            self.updateLocalReadState(rowID: id, isRead: true)
            if self.sidebarSelection == .unread,
               let updated = self.messages.first(where: { $0.id == id }) {
                self.sessionKeptUnreadMessages[id] = updated
            }
            // Detach the Mail.app sync from `autoMarkReadTask` so selecting another email after 500ms
            // never cancels the AppleScript write or the follow-up badge/index refresh.
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await MailAppleScriptBridge.setReadStatus(rowID: id, isRead: true)
                    try? await Task.sleep(for: .milliseconds(500))
                    self.finishReadOverride(rowID: id, token: readToken, succeeded: true, fallbackIsRead: false)
                    self.refreshNow()
                } catch {
                    self.sessionKeptUnreadMessages.removeValue(forKey: id)
                    self.finishReadOverride(rowID: id, token: readToken, succeeded: false, fallbackIsRead: false)
                    self.showToast("自动标已读失败：请在系统设置 → 自动化中允许控制「邮件」")
                }
            }
        }
    }

    // MARK: - System Settings & Utilities

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func copyToClipboard(_ text: String, label: String = "已复制") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(label)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
            showToast(launchAtLoginEnabled ? "已开启登录时自动启动" : "已关闭登录时自动启动")
        } catch {
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
            showToast("设置开机自启失败：\(error.localizedDescription)")
        }
    }

    func showToast(
        _ message: String,
        actionTitle: String? = nil,
        duration: Double = 2.5,
        action: (() -> Void)? = nil
    ) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastActionTitle = actionTitle
        toastActionHandler = action
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            if self.toastMessage == message {
                self.toastMessage = nil
                self.toastActionTitle = nil
                self.toastActionHandler = nil
            }
        }
    }

    func performToastAction() {
        let handler = toastActionHandler
        toastDismissTask?.cancel()
        toastMessage = nil
        toastActionTitle = nil
        toastActionHandler = nil
        handler?()
    }
}
