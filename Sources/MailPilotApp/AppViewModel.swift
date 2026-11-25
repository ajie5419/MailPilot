import AppKit
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

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
    case notifications = "桌面通知"
    case permissions = "系统权限"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .ai: return "sparkles"
        case .accounts: return "at.circle.fill"
        case .tags: return "tag.fill"
        case .notifications: return "bell.badge.fill"
        case .permissions: return "lock.shield.fill"
        }
    }
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
            currentPageLimit = 200
            reloadMessages()
        }
    }
    @Published var searchQuery: String = "" {
        didSet {
            if searchQuery != oldValue {
                currentPageLimit = 200
                scheduleSearchReload()
            }
        }
    }
    @Published var searchFocusTrigger: Int = 0

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
    @Published var currentPageLimit: Int = 200
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
            if let id = selectedMessageID, selectedMessageIDs.count <= 1, selectedMessageIDs != [id] {
                selectedMessageIDs = [id]
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
    private var searchDebounceTask: Task<Void, Never>?
    private var autoMarkReadTask: Task<Void, Never>?
    private var autoMarkReadTargetID: Int64?
    private var watcher: MailDirectoryWatcher?
    private var wakeObserver: NSObjectProtocol?
    private var appLifecycleObservers: [NSObjectProtocol] = []
    private var isRefreshingMailboxes = false
    private var needsFollowUpRefresh = false
    private var cachedMessageTags: [Int64: [MailSmartTag]] = [:]
    private var recentBodyCache: [Int64: CachedRenderedBody] = [:]
    private var recentBodyOrder: [Int64] = []
    /// Keeps messages auto-marked as read during the current `.unread` session visible so reading never jumps away.
    private var sessionKeptUnreadMessages: [Int64: MailMessageSummary] = [:]

    private static let maxRecentBodyCacheEntries = 8
    private static let maxCacheableBodyBytes = 2 * 1024 * 1024
    private static let notificationsEnabledKey = "MailPilot.NotificationsEnabled.v1"
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
                guard let self else { return }
                MailPilotAppDelegate.shared?.showMainWindow()
                self.sidebarSelection = .allInbox
                self.searchQuery = ""
                self.reloadMessages()
                self.selectedMessageID = rowID
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
        notificationManager.syncBadgeCount(totalInboxUnreadCount)
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
        let currentTagSettings = tagSettings
        let baseLimit = filterTag != nil ? max(400, currentPageLimit) : currentPageLimit
        let indexCoordinator = bodyIndex
        reloadTask?.cancel()

        reloadTask = Task { [weak self] in
            do {
                // Return all matching ROWIDs globally (limit: nil) BEFORE applying mailbox/inbox filters in SQL
                // so inbox hits behind thousands of non-inbox hits are never truncated to 0.
                let bodyHitIDs: [Int64] = trimmedQuery.isEmpty
                    ? []
                    : await indexCoordinator.searchRowIDs(query: trimmedQuery, limit: nil)

                let (page, precomputedTags) = try await Self.runCancellableDetached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let tagPredicate: ((MailMessageSummary) -> Bool)? = filterTag.map { tag in
                        { MailTagClassifier.classify($0, settings: currentTagSettings).contains(tag) }
                    }
                    let result = try reader.fetchMessagePage(
                        mailboxID: mailboxID,
                        onlyInbox: onlyInbox,
                        onlyUnread: onlyUnread,
                        onlyFlagged: onlyFlagged,
                        searchQuery: query,
                        bodyHitIDs: bodyHitIDs,
                        limit: baseLimit,
                        predicate: tagPredicate
                    )
                    try Task.checkCancellation()
                    var tagMap: [Int64: [MailSmartTag]] = [:]
                    tagMap.reserveCapacity(result.messages.count)
                    for msg in result.messages {
                        tagMap[msg.id] = MailTagClassifier.classify(msg, settings: currentTagSettings)
                    }
                    return (result, tagMap)
                }
                guard !Task.isCancelled, let self else { return }
                var filtered = self.pendingRemovedIDs.isEmpty
                    ? page.messages
                    : page.messages.filter { !self.pendingRemovedIDs.contains($0.id) }
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
                let messagesChanged = self.messages != filtered
                if messagesChanged {
                    self.messages = filtered
                }
                if self.hasMoreMessages != page.hasMore {
                    self.hasMoreMessages = page.hasMore
                }
                let countIndexed = await indexCoordinator.refreshIndexedCount()
                let newStatus = trimmedQuery.isEmpty
                    ? "实时同步 · \(filtered.count) 封（已索引 \(countIndexed) 正文）"
                    : "搜索结果 · \(filtered.count)\(page.hasMore ? "+" : "") 封（已索引 \(countIndexed) 正文）"
                if self.statusText != newStatus {
                    self.statusText = newStatus
                }
                if let current = self.selectedMessageID, !filtered.contains(where: { $0.id == current }) {
                    self.selectedMessageID = filtered.first?.id
                } else if self.selectedMessageID == nil {
                    self.selectedMessageID = filtered.first?.id
                } else if let current = self.selectedMessageID {
                    // If a notification click selected `current` before `reloadMessages()` populated `messages`,
                    // ensure auto-mark-read runs once the unread message appears in `messages`.
                    self.scheduleAutoMarkReadIfNeeded(for: current)
                }
                if trimmedQuery.isEmpty && (messagesChanged || indexCoordinator.needsFullSweep) {
                    indexCoordinator.scheduleIndexing(
                        visiblePriority: filtered,
                        reader: self.reader,
                        parser: self.emlxParser
                    )
                }
            } catch is CancellationError {
                return
            } catch let err as MailAccessError {
                self?.accessError = err
            } catch {
                self?.statusText = "查询失败：\(error.localizedDescription)"
            }
        }
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
        var fresh: [Int64: [MailSmartTag]] = [:]
        fresh.reserveCapacity(messages.count)
        for msg in messages {
            fresh[msg.id] = MailTagClassifier.classify(msg, settings: tagSettings)
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
                    self.refreshNow()
                } catch {
                    self.sessionKeptUnreadMessages.removeValue(forKey: id)
                    self.updateLocalReadState(rowID: id, isRead: false)
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

    func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if self.toastMessage == message {
                self.toastMessage = nil
            }
        }
    }
}
