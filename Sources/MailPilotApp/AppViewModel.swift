import AppKit
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct AccountMailboxGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let email: String?
    let customIconPath: String?
    let presetLogoID: String?
    let sfSymbolName: String?
    let mailboxes: [MailboxInfo]

    var totalUnread: Int {
        // Exclude Gmail's `All Mail` (`所有邮件`) mirror as well as Trash/Drafts so account unread counts aren't double-counted,
        // while keeping `垃圾邮件` (Junk/Spam) unreads visible.
        let excluded: Set<String> = ["所有邮件", "废纸篓", "草稿"]
        return mailboxes
            .filter { !excluded.contains($0.displayName) }
            .reduce(0) { $0 + $1.unreadCount }
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

@MainActor
final class AppViewModel: ObservableObject {
    @Published var sidebarSelection: SidebarSelection = .allInbox {
        didSet { reloadMessages() }
    }
    @Published var searchQuery: String = "" {
        didSet { scheduleSearchReload() }
    }

    @Published var mailboxes: [MailboxInfo] = [] {
        didSet {
            rebuildAccountGroupingCache()
            updateDockUnreadBadge()
        }
    }
    @Published var groupedMailboxes: [AccountMailboxGroup] = []
    @Published var messages: [MailMessageSummary] = []
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
    @Published var selectedBody: ParsedMailBody?
    @Published var isLoadingBody = false

    @Published var accessError: MailAccessError?
    @Published var statusText: String = "正在连接原生 Mail.app 索引..."
    @Published var isWatchingLive = false
    @Published var showAIPanel = false
    @Published var showSettings = false
    @Published var showComposeSheet = false
    @Published var composeDraft = ComposeDraftState()
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
    @Published var inlineSummaryText: String = ""
    @Published var isInlineSummarizing = false
    @Published var showInlineSummary = false
    @Published var settingsTab: SettingsTab = .ai
    @Published var preferPlainText = false
    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Self.notificationsEnabledKey)
        }
    }
    @Published var tagSettings: MailTagSettings {
        didSet {
            saveTagSettings()
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
    @Published var notificationAuthStatusText: String = "检测中..."

    // AI State
    @Published var aiConfig: AIConfig {
        didSet {
            saveAIConfig()
            refreshAuthStatuses()
            refreshAvailableModels()
        }
    }
    @Published var cliStatuses: [SubscriptionCLIStatus] = []
    @Published var availableModels: [ModelOption] = []
    @Published var isLoadingModels = false
    @Published var oauthTokenBundle: OAuthTokenBundle?
    @Published var isOAuthSigningIn = false
    @Published var oauthStatusMessage: String?
    @Published var chatGPTAccounts: [ChatGPTAccount] = []
    @Published var chatGPTAccount: ChatGPTAccount?
    @Published var chatGPTStatusMessage: String?
    @Published var isChatGPTSigningIn = false
    @Published var isChatGPTSigningOut = false
    @Published var isTestingChatGPT = false
    private var chatGPTLoginTask: Task<Void, Never>?
    private var modelLoadTask: Task<Void, Never>?
    @Published var aiMessages: [AIChatMessage] = []
    @Published var aiInput: String = ""
    @Published var isAIThinking = false
    @Published var lastGeneratedDraft: String?
    @Published var toastMessage: String?

    private var reader: EnvelopeIndexReader?
    private var emlxParser: EmlxParser?
    private let bodySearchIndex = BodySearchIndex()
    private var bodyIndexingTask: Task<Void, Never>?
    private var watcher: MailDirectoryWatcher?
    private var wakeObserver: NSObjectProtocol?
    private let notificationManager = NotificationManager()
    private var lastSeenMaxRowID: Int64?
    private var summaryCache: [Int64: String] = [:]
    private let aiService = AIService()
    private var searchDebounceTask: Task<Void, Never>?
    private var autoMarkReadTask: Task<Void, Never>?

    private static let aiConfigStorageKey = "MailPilot.AIConfig.v2"
    private static let notificationsEnabledKey = "MailPilot.NotificationsEnabled.v1"
    private static let tagSettingsStorageKey = "MailPilot.TagSettings.v1"
    private static let collapsedSectionsStorageKey = "MailPilot.CollapsedSidebarSections.v1"
    private static let accountCustomizationsKey = "MailPilot.AccountCustomizations.v1"
    private static let defaultSendAccountKey = "MailPilot.DefaultSendAccountID.v1"

    init() {
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
        if let data = UserDefaults.standard.data(forKey: Self.aiConfigStorageKey),
           let decoded = try? JSONDecoder().decode(AIConfig.self, from: data) {
            var migrated = decoded
            if !UserDefaults.standard.bool(forKey: "MailPilot.ChatGPTMigration.v1"),
               decoded.authMode == .subscriptionCLI && decoded.cliProvider == .codex {
                migrated.authMode = .chatGPT
            }
            self.aiConfig = migrated
        } else {
            self.aiConfig = AIConfig()
        }
        UserDefaults.standard.set(true, forKey: "MailPilot.ChatGPTMigration.v1")
        saveAIConfig()
        notificationManager.onSelectMessage = { [weak self] rowID in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sidebarSelection = .allInbox
                self.searchQuery = ""
                self.reloadMessages()
                self.selectedMessageID = rowID
            }
        }
        refreshAuthStatuses()
        refreshAvailableModels()
        requestNotificationPermissionOnLaunch()
        connectToNativeMail()
        observeSystemWake()
        Task {
            let fetchedAccounts = await MailAppleScriptBridge.fetchAccounts()
            self.accounts = fetchedAccounts
            let emails = await MailAppleScriptBridge.fetchAccountEmails()
            self.accountEmails = emails.isEmpty ? fetchedAccounts.map(\.email).filter { !$0.isEmpty } : emails
        }
    }

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

    var activeAIBadge: String {
        switch aiConfig.authMode {
        case .chatGPT:
            return chatGPTAccount?.signedIn == true ? "ChatGPT 已登录" : "ChatGPT 未登录"
        case .subscriptionCLI:
            return aiConfig.cliProvider.shortBadge
        case .oauthPKCE:
            return oauthTokenBundle != nil ? "OAuth 已登录" : "OAuth 未登录"
        case .apiKey:
            return aiConfig.baseURL.contains("localhost") ? "本地模型" : "API Key"
        }
    }

    var activeModelDisplayName: String {
        switch aiConfig.authMode {
        case .chatGPT:
            return aiConfig.chatGPTModel ?? "未选择模型"
        case .subscriptionCLI:
            let custom = aiConfig.cliModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? "默认模型" : custom
        case .oauthPKCE:
            let m = aiConfig.oauth.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? "未选择" : m
        case .apiKey:
            let m = aiConfig.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? "未选择" : m
        }
    }

    func refreshAvailableModels() {
        modelLoadTask?.cancel()
        let configSnapshot = aiConfig
        isLoadingModels = true
        modelLoadTask = Task {
            do {
                let fetched: [ModelOption]
                if configSnapshot.authMode == .chatGPT {
                    let account = try await ChatGPTService.shared.selectedAccount()
                    fetched = account?.signedIn == true && account?.planEnabled == true
                        ? try await ChatGPTService.shared.models() : []
                } else {
                    fetched = await ModelCatalogService.fetchAvailableModels(config: configSnapshot)
                }
                guard !Task.isCancelled, self.aiConfig == configSnapshot else { return }
                self.availableModels = fetched
                self.isLoadingModels = false
                if configSnapshot.authMode == .chatGPT {
                    if !fetched.contains(where: { $0.id == self.aiConfig.chatGPTModel }),
                       self.aiConfig.chatGPTModel != fetched.first?.id {
                        self.aiConfig.chatGPTModel = fetched.first?.id
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.availableModels = []
                self.isLoadingModels = false
                self.chatGPTStatusMessage = error.localizedDescription
            }
        }
    }

    var currentSuggestedModels: [String] {
        if !availableModels.isEmpty {
            return availableModels.map(\.id)
        }
        return aiConfig.authMode == .chatGPT ? [] : aiConfig.cliProvider.suggestedModels
    }

    func selectModel(_ model: String) {
        switch aiConfig.authMode {
        case .chatGPT:
            aiConfig.chatGPTModel = model
        case .subscriptionCLI:
            aiConfig.cliModelOverride = model
        case .oauthPKCE:
            aiConfig.oauth.model = model
        case .apiKey:
            aiConfig.model = model
        }
    }

    func switchCLIProvider(_ provider: SubscriptionCLIProvider) {
        aiConfig.authMode = .subscriptionCLI
        aiConfig.cliProvider = provider
        aiConfig.cliModelOverride = ""
    }

    func refreshAuthStatuses() {
        if aiConfig.authMode == .subscriptionCLI { cliStatuses = SubscriptionCLIBridge.detectAll() }
        Task { await refreshChatGPTAccounts() }
        oauthTokenBundle = KeychainStore.loadToken(
            account: OAuthSubscriptionManager.keychainAccount(for: aiConfig.oauth.kind)
        )
    }

    func refreshChatGPTAccounts() async {
        do {
            chatGPTAccounts = try await ChatGPTService.shared.accounts()
            chatGPTAccount = try await ChatGPTService.shared.selectedAccount()
        } catch { chatGPTStatusMessage = error.localizedDescription }
    }

    func startChatGPTSignIn(newAccount: Bool = false) {
        guard !isChatGPTSigningIn, !isChatGPTSigningOut else { return }
        isChatGPTSigningIn = true
        chatGPTStatusMessage = "请在浏览器中登录，并允许 MailPilot 使用 ChatGPT 订阅。"
        chatGPTLoginTask = Task {
            defer { isChatGPTSigningIn = false; chatGPTLoginTask = nil }
            do {
                try await ChatGPTService.shared.signIn(newAccount: newAccount) { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
                await refreshChatGPTAccounts()
                chatGPTStatusMessage = chatGPTAccount?.planEnabled == true
                    ? "登录成功。请选择模型，再点击「验证连接」。"
                    : "已登录，但尚未授权使用订阅额度。请重新授权。"
                refreshAvailableModels()
            } catch is CancellationError { chatGPTStatusMessage = "已取消登录。" }
            catch { chatGPTStatusMessage = error.localizedDescription }
        }
    }

    func cancelChatGPTSignIn() { chatGPTLoginTask?.cancel() }

    func selectChatGPTAccount(_ id: String) {
        modelLoadTask?.cancel()
        Task {
            do {
                try await ChatGPTService.shared.selectAccount(id)
                await refreshChatGPTAccounts()
                aiConfig.chatGPTModel = nil
                chatGPTStatusMessage = nil
                refreshAvailableModels()
            } catch { chatGPTStatusMessage = error.localizedDescription }
        }
    }

    func signOutChatGPT() {
        guard !isChatGPTSigningOut else { return }
        isChatGPTSigningOut = true
        modelLoadTask?.cancel()
        Task {
            defer { isChatGPTSigningOut = false }
            do {
                let revoked = try await ChatGPTService.shared.signOut()
                await refreshChatGPTAccounts()
                availableModels = []
                aiConfig.chatGPTModel = nil
                chatGPTStatusMessage = revoked ? "已退出 ChatGPT 登录。"
                    : "已清除本机登录信息，但未确认远程撤销。请在 ChatGPT 设置中断开 MailPilot。"
            } catch { chatGPTStatusMessage = error.localizedDescription }
        }
    }

    func testChatGPTConnection() {
        guard !isTestingChatGPT else { return }
        isTestingChatGPT = true
        chatGPTStatusMessage = "正在发送不含邮件内容的测试请求…"
        let model = aiConfig.chatGPTModel ?? ""
        Task {
            defer { isTestingChatGPT = false }
            do {
                _ = try await ChatGPTService.shared.chat(model: model, instructions: "", history: [],
                    message: "Reply with exactly OK.", onPartial: nil)
                chatGPTStatusMessage = "连接验证成功，已收到完整模型回答。"
            } catch { chatGPTStatusMessage = error.localizedDescription }
        }
    }

    func openCLILoginInTerminal(_ provider: SubscriptionCLIProvider) {
        SubscriptionCLIBridge.openTerminalForLogin(provider: provider)
        showToast("已打开终端运行 `\(provider.loginCommandHint)`，完成登录后即可直接使用")
    }

    func startOAuthSignIn() {
        guard !isOAuthSigningIn else { return }
        isOAuthSigningIn = true
        oauthStatusMessage = "正在等待浏览器完成授权..."

        let config = aiConfig.oauth
        Task {
            do {
                let bundle = try await OAuthSubscriptionManager.signIn(config: config) { url in
                    Task { @MainActor in
                        NSWorkspace.shared.open(url)
                    }
                }
                self.oauthTokenBundle = bundle
                self.oauthStatusMessage = "已登录：\(bundle.accountLabel ?? "订阅账号")"
                self.showToast("OAuth 订阅登录成功，令牌已安全存入系统钥匙串")
            } catch {
                self.oauthStatusMessage = error.localizedDescription
                self.showToast(error.localizedDescription)
            }
            self.isOAuthSigningIn = false
        }
    }

    func signOutOAuth() {
        OAuthSubscriptionManager.signOut(kind: aiConfig.oauth.kind)
        oauthTokenBundle = nil
        oauthStatusMessage = "已退出登录并清除钥匙串凭据"
        showToast("已退出 OAuth 登录")
    }

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
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
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

    private var cachedAccountLookup: [String: (title: String, shortName: String, email: String?, customIconPath: String?, presetLogoID: String?, sfSymbolName: String?, color: Color)] = [:]
    private var reloadTask: Task<Void, Never>?
    private var pendingRemovedIDs: Set<Int64> = []

    /// Returns only the username part before `@` (or user's custom sidebar name if set) in O(1).
    func accountShortUsername(for accountID: String) -> String? {
        let key = accountID.uppercased()
        if key == "LOCAL" { return "我的 Mac" }
        return cachedAccountLookup[key]?.shortName
    }

    func accountDisplayName(for accountID: String) -> String? {
        let key = accountID.uppercased()
        if key == "LOCAL" { return "我的 Mac" }
        return cachedAccountLookup[key]?.title
    }

    func accountEmail(for accountID: String) -> String? {
        let key = accountID.uppercased()
        if key == "LOCAL" { return nil }
        return cachedAccountLookup[key]?.email
    }

    func accountCustomIconPath(for accountID: String) -> String? {
        cachedAccountLookup[accountID.uppercased()]?.customIconPath
    }

    func accountPresetLogoID(for accountID: String) -> String? {
        cachedAccountLookup[accountID.uppercased()]?.presetLogoID
    }

    func accountSFSymbolName(for accountID: String) -> String? {
        cachedAccountLookup[accountID.uppercased()]?.sfSymbolName
    }

    func openIconPicker(for group: AccountMailboxGroup) {
        let custom = customization(for: group.id)
        iconPickerState = AccountIconPickerState(
            accountID: group.id,
            email: group.email,
            customIconPath: custom.customIconPath,
            presetLogoID: custom.presetLogoID,
            sfSymbolName: custom.sfSymbolName
        )
        showIconPickerSheet = true
    }

    func pickCustomIconForPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let iconsDir = appSupport.appendingPathComponent("MailPilot/AccountIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let safeKey = iconPickerState.accountID.uppercased().replacingOccurrences(of: "/", with: "_")
        let destURL = iconsDir.appendingPathComponent("\(safeKey)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            iconPickerState.customIconPath = destURL.path
            iconPickerState.presetLogoID = nil
            iconPickerState.sfSymbolName = nil
            SenderAvatarLoader.shared.invalidateCustomIcon(at: destURL.path)
        } catch {
            showToast("读取图标失败：\(error.localizedDescription)")
        }
    }

    func saveIconPickerSelection() {
        let acctID = iconPickerState.accountID
        let oldPath = customization(for: acctID).customIconPath
        let newPath = iconPickerState.customIconPath
        updateCustomization(for: acctID) {
            $0.customIconPath = newPath
            $0.presetLogoID = iconPickerState.presetLogoID
            $0.sfSymbolName = iconPickerState.sfSymbolName
        }
        if let oldPath, oldPath != newPath {
            try? FileManager.default.removeItem(atPath: oldPath)
            SenderAvatarLoader.shared.invalidateCustomIcon(at: oldPath)
        }
        showIconPickerSheet = false
        showToast("已保存账户图标")
    }

    func customization(for accountID: String) -> AccountCustomization {
        accountCustomizations[accountID.uppercased()] ?? AccountCustomization()
    }

    func updateCustomization(for accountID: String, _ transform: (inout AccountCustomization) -> Void) {
        let key = accountID.uppercased()
        var current = accountCustomizations[key] ?? AccountCustomization()
        transform(&current)
        accountCustomizations[key] = current
    }

    func pickCustomIcon(for accountID: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let iconsDir = appSupport.appendingPathComponent("MailPilot/AccountIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let safeKey = accountID.uppercased().replacingOccurrences(of: "/", with: "_")
        let destURL = iconsDir.appendingPathComponent("\(safeKey)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            let oldPath = customization(for: accountID).customIconPath
            updateCustomization(for: accountID) { $0.customIconPath = destURL.path }
            if let oldPath, oldPath != destURL.path {
                try? FileManager.default.removeItem(atPath: oldPath)
                SenderAvatarLoader.shared.invalidateCustomIcon(at: oldPath)
            }
            SenderAvatarLoader.shared.invalidateCustomIcon(at: destURL.path)
            showToast("已更新账户图标")
        } catch {
            showToast("保存图标失败：\(error.localizedDescription)")
        }
    }

    func clearCustomIcon(for accountID: String) {
        let oldPath = customization(for: accountID).customIconPath
        updateCustomization(for: accountID) { $0.customIconPath = nil }
        if let oldPath {
            try? FileManager.default.removeItem(atPath: oldPath)
            SenderAvatarLoader.shared.invalidateCustomIcon(at: oldPath)
        }
        showToast("已恢复默认服务商图标")
    }

    private func saveAccountCustomizations() {
        if let data = try? JSONEncoder().encode(accountCustomizations) {
            UserDefaults.standard.set(data, forKey: Self.accountCustomizationsKey)
        }
    }

    /// Returns the full email address for sidebar & detail header (never strips `.com`),
    /// while `accountShortUsername` handles the username-only badge in the message list.
    private func disambiguatedAccountName(for account: MailAccountInfo) -> String {
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? account.displayTitle : email
    }

    private static func emailDomain(_ email: String) -> String {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let atIdx = lower.lastIndex(of: "@") else { return "zzz" }
        return String(lower[lower.index(after: atIdx)...])
    }

    func accountBadgeColor(for accountID: String) -> Color {
        let key = accountID.uppercased()
        if let color = cachedAccountLookup[key]?.color {
            return color
        }
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
        let hash = abs(key.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return palette[hash % palette.count]
    }

    /// Rebuilds grouped sidebar mailboxes and O(1) account lookup cache only when accounts or mailboxes change.
    private func rebuildAccountGroupingCache() {
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id.uppercased(), $0) })
        let byAccount = Dictionary(grouping: mailboxes, by: { $0.accountID.uppercased() })

        let unmatchedKeys = byAccount.keys.filter { $0 != "LOCAL" && accountMap[$0] == nil }.sorted()
        let matchedAccountIDs = Set(byAccount.keys.compactMap { accountMap[$0]?.id.uppercased() })
        let unmatchedAccounts = accounts.filter { !matchedAccountIDs.contains($0.id.uppercased()) }
        var fallbackMap: [String: MailAccountInfo] = [:]
        for (idx, key) in unmatchedKeys.enumerated() where idx < unmatchedAccounts.count {
            fallbackMap[key] = unmatchedAccounts[idx]
        }

        let sortedKeys = byAccount.keys.sorted { lhs, rhs in
            if lhs == "LOCAL" { return false }
            if rhs == "LOCAL" { return true }
            let leftAcct = accountMap[lhs] ?? fallbackMap[lhs]
            let rightAcct = accountMap[rhs] ?? fallbackMap[rhs]
            let leftDomain = Self.emailDomain(leftAcct?.email ?? "")
            let rightDomain = Self.emailDomain(rightAcct?.email ?? "")
            if leftDomain != rightDomain {
                return leftDomain.localizedCaseInsensitiveCompare(rightDomain) == .orderedAscending
            }
            let leftName = leftAcct?.email.isEmpty == false ? (leftAcct?.email ?? lhs) : (leftAcct?.displayTitle ?? lhs)
            let rightName = rightAcct?.email.isEmpty == false ? (rightAcct?.email ?? rhs) : (rightAcct?.displayTitle ?? rhs)
            return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }

        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
        var groups: [AccountMailboxGroup] = []
        var lookup: [String: (title: String, shortName: String, email: String?, customIconPath: String?, presetLogoID: String?, sfSymbolName: String?, color: Color)] = [:]
        var anonymousIndex = 1

        for (idx, key) in sortedKeys.enumerated() {
            guard let items = byAccount[key], !items.isEmpty else { continue }
            let sortedItems = items.sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                if a.unreadCount != b.unreadCount { return a.unreadCount > b.unreadCount }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
            let color = palette[idx % palette.count]
            let custom = accountCustomizations[key]
            let customSidebar = custom?.sidebarName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let iconPath = custom?.customIconPath
            let presetLogo = custom?.presetLogoID
            let sfSymbol = custom?.sfSymbolName

            if key == "LOCAL" {
                continue
            } else if let acct = accountMap[key] ?? fallbackMap[key] {
                let defaultTitle = disambiguatedAccountName(for: acct)
                let finalTitle = customSidebar.isEmpty ? defaultTitle : customSidebar
                let emailOpt = acct.email.isEmpty ? nil : acct.email
                let defaultShort = emailOpt.map { $0.split(separator: "@", maxSplits: 1).first.map(String.init) ?? defaultTitle } ?? defaultTitle
                let finalShort = customSidebar.isEmpty ? defaultShort : customSidebar
                groups.append(
                    AccountMailboxGroup(
                        id: key,
                        title: finalTitle,
                        email: emailOpt,
                        customIconPath: iconPath,
                        presetLogoID: presetLogo,
                        sfSymbolName: sfSymbol,
                        mailboxes: sortedItems
                    )
                )
                lookup[key] = (
                    title: finalTitle,
                    shortName: finalShort,
                    email: emailOpt,
                    customIconPath: iconPath,
                    presetLogoID: presetLogo,
                    sfSymbolName: sfSymbol,
                    color: color
                )
            } else {
                let fallbackTitle = customSidebar.isEmpty ? "邮箱账号 \(anonymousIndex)" : customSidebar
                groups.append(
                    AccountMailboxGroup(
                        id: key,
                        title: fallbackTitle,
                        email: nil,
                        customIconPath: iconPath,
                        presetLogoID: presetLogo,
                        sfSymbolName: sfSymbol,
                        mailboxes: sortedItems
                    )
                )
                lookup[key] = (
                    title: fallbackTitle,
                    shortName: fallbackTitle,
                    email: nil,
                    customIconPath: iconPath,
                    presetLogoID: presetLogo,
                    sfSymbolName: sfSymbol,
                    color: color
                )
                anonymousIndex += 1
            }
        }
        self.cachedAccountLookup = lookup
        self.groupedMailboxes = groups
        if selectedSettingsAccountID.isEmpty, let first = groups.first {
            selectedSettingsAccountID = first.id
        }
    }

    // MARK: - Connection & Sync

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

    private var isFetchingAccounts = false
    private var lastAccountsFetchAt: Date = .distantPast

    func refreshNow() {
        guard let reader else {
            connectToNativeMail()
            return
        }
        Task { [weak self] in
            do {
                let fetchedMailboxes = try await Task.detached(priority: .userInitiated) {
                    try reader.fetchMailboxes()
                }.value
                guard let self else { return }
                self.mailboxes = fetchedMailboxes
                self.accessError = nil
                self.syncAccountsIfUnknownMailboxPresent(fetchedMailboxes)
                self.reloadMessages()
            } catch let err as MailAccessError {
                self?.accessError = err
                self?.statusText = "读取失败"
            } catch {
                self?.statusText = "读取异常：\(error.localizedDescription)"
            }
        }
    }

    /// Re-fetches Mail.app accounts whenever a newly added account UUID (e.g. Outlook/Exchange)
    /// appears in `Envelope Index` after launch.
    private func syncAccountsIfUnknownMailboxPresent(_ mailboxes: [MailboxInfo]) {
        let knownIDs = Set(accounts.map { $0.id.uppercased() })
        let hasUnknown = mailboxes.contains { mb in
            let id = mb.accountID.uppercased()
            return id != "LOCAL" && !knownIDs.contains(id)
        }
        guard hasUnknown, !isFetchingAccounts, Date().timeIntervalSince(lastAccountsFetchAt) > 3 else {
            return
        }
        isFetchingAccounts = true
        lastAccountsFetchAt = Date()
        Task { [weak self] in
            guard let self else { return }
            let fetched = await MailAppleScriptBridge.fetchAccounts()
            if !fetched.isEmpty {
                self.accounts = fetched
                let emails = fetched.map(\.email).filter { !$0.isEmpty }
                if !emails.isEmpty {
                    self.accountEmails = emails
                }
            }
            self.isFetchingAccounts = false
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
        let limit = filterTag != nil ? 400 : 200
        let ftsIndex = bodySearchIndex
        reloadTask?.cancel()

        reloadTask = Task { [weak self] in
            do {
                let bodyHitIDs: [Int64] = trimmedQuery.isEmpty
                    ? []
                    : await ftsIndex.searchRowIDs(query: trimmedQuery, limit: 150)

                let fetched = try await Task.detached(priority: .userInitiated) {
                    var rows = try reader.fetchMessages(
                        mailboxID: mailboxID,
                        onlyInbox: onlyInbox,
                        onlyUnread: onlyUnread,
                        onlyFlagged: onlyFlagged,
                        searchQuery: query,
                        limit: limit
                    )
                    // Merge full-text body search hits from local FTS5 cache
                    if !bodyHitIDs.isEmpty {
                        let existingIDs = Set(rows.map(\.id))
                        let extraIDs = bodyHitIDs.filter { !existingIDs.contains($0) }
                        if !extraIDs.isEmpty, let extraRows = try? reader.fetchMessages(byRowIDs: extraIDs) {
                            let filteredExtra = extraRows.filter { msg in
                                if let mbID = mailboxID, msg.mailboxID != mbID { return false }
                                if onlyInbox, msg.mailboxName != "收件箱" { return false }
                                if onlyUnread, msg.isRead { return false }
                                if onlyFlagged, !msg.isFlagged { return false }
                                return true
                            }
                            rows.append(contentsOf: filteredExtra)
                            rows.sort { $0.dateReceived > $1.dateReceived }
                        }
                    }
                    if let filterTag {
                        rows = rows.filter { MailTagClassifier.classify($0, settings: currentTagSettings).contains(filterTag) }
                    }
                    return rows
                }.value
                guard !Task.isCancelled, let self else { return }
                let filtered = self.pendingRemovedIDs.isEmpty
                    ? fetched
                    : fetched.filter { !self.pendingRemovedIDs.contains($0.id) }
                self.messages = filtered
                self.statusText = trimmedQuery.isEmpty
                    ? "实时同步中 · \(filtered.count) 封邮件"
                    : "全文搜索 · \(filtered.count) 封结果"
                if let current = self.selectedMessageID, !filtered.contains(where: { $0.id == current }) {
                    self.selectedMessageID = filtered.first?.id
                } else if self.selectedMessageID == nil {
                    self.selectedMessageID = filtered.first?.id
                }
                if trimmedQuery.isEmpty {
                    self.scheduleBackgroundBodyIndexing(for: filtered)
                }
            } catch let err as MailAccessError {
                self?.accessError = err
            } catch {
                self?.statusText = "查询失败：\(error.localizedDescription)"
            }
        }
    }

    /// Incrementally indexes `.emlx` plain-text bodies into local FTS5 cache in the background.
    private func scheduleBackgroundBodyIndexing(for candidates: [MailMessageSummary]) {
        guard let parser = emlxParser, !candidates.isEmpty else { return }
        let snapshot = Array(candidates.prefix(120))
        let ftsIndex = bodySearchIndex
        bodyIndexingTask?.cancel()
        bodyIndexingTask = Task.detached(priority: .background) {
            let ids = snapshot.map(\.id)
            let alreadyIndexed = await ftsIndex.indexedRowIDs(in: ids)
            let missing = snapshot.filter { !alreadyIndexed.contains($0.id) }
            guard !missing.isEmpty else { return }

            var batch: [(rowID: Int64, subject: String, sender: String, body: String)] = []
            for msg in missing {
                if Task.isCancelled { break }
                let parsed = await parser.loadBody(for: msg.id)
                batch.append((
                    rowID: msg.id,
                    subject: msg.subject,
                    sender: "\(msg.senderName) \(msg.senderAddress)",
                    body: parsed.plainText
                ))
                if batch.count >= 25 {
                    await ftsIndex.upsertBatch(batch)
                    batch.removeAll()
                }
            }
            if !batch.isEmpty {
                await ftsIndex.upsertBatch(batch)
            }
        }
    }

    private func handleLiveFileChange() {
        // Keep EmlxParser's existing path cache warm (fast O(1) bucket lookup finds new .emlx without rescanning).
        refreshNow()
        Task { [weak self] in
            await self?.checkAndNotifyIncomingMail()
        }
    }

    private func seedInitialRowIDWatermark() {
        guard let reader else { return }
        Task { [weak self] in
            let maxID = await Task.detached(priority: .utility) {
                (try? reader.fetchMessages(onlyInbox: true, limit: 50))?.map(\.id).max() ?? 0
            }.value
            self?.lastSeenMaxRowID = maxID
        }
    }

    private func checkAndNotifyIncomingMail() async {
        guard notificationsEnabled, let reader else { return }
        let recentUnread = await Task.detached(priority: .userInitiated) {
            (try? reader.fetchMessages(onlyInbox: true, onlyUnread: true, limit: 25)) ?? []
        }.value

        guard let watermark = lastSeenMaxRowID else {
            lastSeenMaxRowID = recentUnread.map(\.id).max() ?? 0
            return
        }

        let newlyArrived = recentUnread.filter { $0.id > watermark }.sorted { $0.id < $1.id }
        guard !newlyArrived.isEmpty else { return }

        if let maxID = newlyArrived.map(\.id).max() {
            lastSeenMaxRowID = max(watermark, maxID)
        }

        if newlyArrived.count > 3, let latest = newlyArrived.last {
            notificationManager.notifyBatchSummary(count: newlyArrived.count, latest: latest)
            return
        }

        for msg in newlyArrived {
            var code: String?
            if let parser = emlxParser {
                let body = await parser.loadBody(for: msg.id)
                code = body.verificationCode
            }
            notificationManager.notifyNewMail(message: msg, verificationCode: code)
        }
    }

    func requestNotificationPermissionOnLaunch() {
        Task {
            let status = await notificationManager.requestAuthorization()
            self.notificationAuthStatusText = formatAuthStatus(status)
        }
    }

    func refreshNotificationStatus() {
        Task {
            let status = await notificationManager.authorizationStatus()
            self.notificationAuthStatusText = formatAuthStatus(status)
        }
    }

    func sendTestNotification() {
        Task {
            let status = await notificationManager.requestAuthorization()
            self.notificationAuthStatusText = formatAuthStatus(status)
            if status == .authorized || status == .provisional {
                self.notificationManager.sendTestNotification()
                self.showToast("已发送测试通知")
            } else {
                self.showToast("系统通知权限未开启，请前往系统设置放行 MailPilot")
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func formatAuthStatus(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已授权"
        case .provisional: return "临时授权"
        case .denied: return "已拒绝（请在系统设置中开启）"
        case .notDetermined: return "未授权"
        @unknown default: return "未知"
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

    private func loadSelectedMessageBody() {
        aiMessages.removeAll()
        lastGeneratedDraft = nil
        autoMarkReadTask?.cancel()
        isInlineSummarizing = false

        guard let id = selectedMessageID, let parser = emlxParser else {
            selectedBody = nil
            inlineSummaryText = ""
            showInlineSummary = false
            return
        }
        if let cached = summaryCache[id] {
            inlineSummaryText = cached
            showInlineSummary = true
        } else {
            inlineSummaryText = ""
            showInlineSummary = false
        }
        isLoadingBody = true
        Task {
            let parsed = await parser.loadBody(for: id)
            guard self.selectedMessageID == id else { return }
            self.selectedBody = parsed
            self.isLoadingBody = false
        }

        // Auto-mark as read after staying on an unread message briefly.
        if let msg = messages.first(where: { $0.id == id }), !msg.isRead {
            autoMarkReadTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, self.selectedMessageID == id else { return }
                self.updateLocalReadState(rowID: id, isRead: true)
                do {
                    try await MailAppleScriptBridge.setReadStatus(rowID: id, isRead: true)
                } catch {
                    self.updateLocalReadState(rowID: id, isRead: false)
                    self.showToast("自动标已读失败：请在系统设置 → 自动化中允许控制「邮件」")
                }
            }
        }
    }

    private func updateLocalReadState(rowID: Int64, isRead: Bool) {
        guard let idx = messages.firstIndex(where: { $0.id == rowID }) else { return }
        let old = messages[idx]
        messages[idx] = MailMessageSummary(
            id: old.id,
            messageIDHeader: old.messageIDHeader,
            subject: old.subject,
            senderAddress: old.senderAddress,
            senderName: old.senderName,
            dateReceived: old.dateReceived,
            isRead: isRead,
            isFlagged: old.isFlagged,
            mailboxID: old.mailboxID,
            mailboxName: old.mailboxName,
            accountID: old.accountID
        )
    }

    // MARK: - Apple Mail Write Actions

    func triggerNativeMailFetch() {
        Task {
            do {
                try await MailAppleScriptBridge.triggerCheckForNewMail()
                showToast("已通知系统 Mail.app 立即收信")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func toggleReadStatus(for message: MailMessageSummary) {
        let nextState = !message.isRead
        updateLocalReadState(rowID: message.id, isRead: nextState)
        Task {
            do {
                try await MailAppleScriptBridge.setReadStatus(rowID: message.id, isRead: nextState)
                showToast(nextState ? "已标记为已读" : "已标记为未读")
                try? await Task.sleep(for: .milliseconds(400))
                refreshNow()
            } catch {
                updateLocalReadState(rowID: message.id, isRead: message.isRead)
                showToast(error.localizedDescription)
            }
        }
    }

    func toggleFlaggedStatus(for message: MailMessageSummary) {
        let nextState = !message.isFlagged
        Task {
            do {
                try await MailAppleScriptBridge.setFlaggedStatus(rowID: message.id, isFlagged: nextState)
                showToast(nextState ? "已添加旗标" : "已取消旗标")
                try? await Task.sleep(for: .milliseconds(400))
                refreshNow()
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func openInNativeMail(_ message: MailMessageSummary) {
        Task {
            do {
                try await MailAppleScriptBridge.openInMailApp(rowID: message.id)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func sendDraftToMailApp(body: String) {
        guard let message = selectedMessage else { return }
        openComposeReply(for: message, prefilledBody: body)
    }

    // MARK: - In-App Compose, Reply, Forward, Delete & Archive

    private func preferredSenderEmail() -> String {
        if !defaultSendAccountID.isEmpty,
           let email = accountEmail(for: defaultSendAccountID), !email.isEmpty {
            return email
        }
        return accountEmails.first ?? ""
    }

    private func formattedSenderHeader(for rawEmail: String) -> String? {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return nil }
        if let matchedGroup = groupedMailboxes.first(where: { $0.email?.caseInsensitiveCompare(email) == .orderedSame }) {
            let senderName = customization(for: matchedGroup.id).senderDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !senderName.isEmpty {
                return "\(senderName) <\(email)>"
            }
        }
        return email
    }

    func openComposeNew() {
        composeDraft = ComposeDraftState(
            mode: .new,
            fromEmail: preferredSenderEmail(),
            toText: "",
            ccText: "",
            subject: "",
            body: ""
        )
        showComposeSheet = true
        refreshAccountEmailsIfEmpty()
    }

    func openComposeReply(for message: MailMessageSummary? = nil, prefilledBody: String? = nil) {
        guard let target = message ?? selectedMessage else { return }
        let replySubject = target.subject.lowercased().hasPrefix("re:") ? target.subject : "Re: \(target.subject)"
        let quoteHeader = "\n\n---\n在 \(target.dateReceived.formatted(date: .abbreviated, time: .shortened))，\(target.displaySender) <\(target.senderAddress)> 写道：\n"
        let quoteBody = (target.id == selectedMessageID ? selectedBody?.plainText : nil)
            .map { String($0.prefix(1200)) } ?? ""
        let initialBody: String
        if let prefilledBody {
            initialBody = prefilledBody + (quoteBody.isEmpty ? "" : quoteHeader + quoteBody)
        } else {
            initialBody = quoteBody.isEmpty ? "" : "\n\n" + quoteHeader + quoteBody
        }
        composeDraft = ComposeDraftState(
            mode: .reply,
            fromEmail: accountEmails.first ?? "",
            toText: target.senderAddress,
            ccText: "",
            subject: replySubject,
            body: initialBody
        )
        showComposeSheet = true
        refreshAccountEmailsIfEmpty()
    }

    func openComposeForward(for message: MailMessageSummary? = nil) {
        guard let target = message ?? selectedMessage else { return }
        let fwdSubject = target.subject.lowercased().hasPrefix("fwd:") ? target.subject : "Fwd: \(target.subject)"
        let header = """
        

        ---------- 转发的邮件 ----------
        发件人：\(target.displaySender) <\(target.senderAddress)>
        日期：\(target.dateReceived.formatted(date: .abbreviated, time: .shortened))
        主题：\(target.subject)

        """
        let bodyText = (target.id == selectedMessageID ? selectedBody?.plainText : nil) ?? ""
        composeDraft = ComposeDraftState(
            mode: .forward,
            fromEmail: accountEmails.first ?? "",
            toText: "",
            ccText: "",
            subject: fwdSubject,
            body: header + bodyText
        )
        showComposeSheet = true
        refreshAccountEmailsIfEmpty()
    }

    func pickComposeAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            for url in panel.urls where !composeDraft.attachmentURLs.contains(url) {
                composeDraft.attachmentURLs.append(url)
            }
        }
    }

    func removeComposeAttachment(_ url: URL) {
        composeDraft.attachmentURLs.removeAll { $0 == url }
    }

    func sendComposedMail() {
        let toList = parseEmailList(composeDraft.toText)
        guard !toList.isEmpty else {
            showToast("请填写至少一个收件人邮箱")
            return
        }
        let ccList = parseEmailList(composeDraft.ccText)
        let draft = composeDraft
        composeDraft.isSending = true

        let senderHeader = formattedSenderHeader(for: draft.fromEmail)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await MailAppleScriptBridge.sendMessage(
                    from: senderHeader,
                    to: toList,
                    cc: ccList,
                    subject: draft.subject.isEmpty ? "(无主题)" : draft.subject,
                    body: draft.body,
                    attachmentURLs: draft.attachmentURLs
                )
                self.composeDraft.isSending = false
                self.showComposeSheet = false
                self.showToast("邮件已发送")
            } catch {
                self.composeDraft.isSending = false
                self.showToast("发送失败：\(error.localizedDescription)")
            }
        }
    }

    func saveComposedDraft() {
        let toList = parseEmailList(composeDraft.toText)
        let ccList = parseEmailList(composeDraft.ccText)
        let draft = composeDraft
        composeDraft.isSending = true

        let senderHeader = formattedSenderHeader(for: draft.fromEmail)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await MailAppleScriptBridge.saveDraft(
                    from: senderHeader,
                    to: toList,
                    cc: ccList,
                    subject: draft.subject.isEmpty ? "(无主题)" : draft.subject,
                    body: draft.body,
                    attachmentURLs: draft.attachmentURLs
                )
                self.composeDraft.isSending = false
                self.showComposeSheet = false
                self.showToast("已保存至草稿箱")
            } catch {
                self.composeDraft.isSending = false
                self.showToast("保存草稿失败：\(error.localizedDescription)")
            }
        }
    }

    func polishComposeBodyWithAI() {
        let currentBody = composeDraft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = composeDraft.subject
        let to = composeDraft.toText
        composeDraft.isAIPolishing = true

        let prompt: String
        if currentBody.isEmpty {
            prompt = "请根据主题「\(subject)」和收件人「\(to)」，起草一封得体、专业简洁的中文邮件正文（直接输出正文，不要附加解释）。"
        } else {
            prompt = "请帮我润色并补全以下邮件草稿，使其更自然、清晰、得体（直接输出润色后的完整正文，不要附加解释）：\n\n\(currentBody)"
        }
        let configSnapshot = aiConfig

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.aiService.chat(
                    config: configSnapshot,
                    systemPrompt: "你是一位专业高效的邮件写作助手。",
                    history: [],
                    userMessage: prompt,
                    onPartial: { [weak self] partial in
                        Task { @MainActor [weak self] in
                            self?.composeDraft.body = partial
                        }
                    }
                )
                self.composeDraft.body = result
            } catch {
                self.showToast("AI 润色失败：\(error.localizedDescription)")
            }
            self.composeDraft.isAIPolishing = false
        }
    }

    func clearMultiSelection() {
        if let current = selectedMessageID {
            selectedMessageIDs = [current]
        } else {
            selectedMessageIDs.removeAll()
        }
    }

    func batchMarkSelected(isRead: Bool) {
        let targets = messages.filter { selectedMessageIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        for msg in targets {
            updateLocalReadState(rowID: msg.id, isRead: isRead)
        }
        let ids = targets.map(\.id)
        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            for id in ids {
                do {
                    try await MailAppleScriptBridge.setReadStatus(rowID: id, isRead: isRead)
                } catch {
                    failed += 1
                }
            }
            if failed == 0 {
                self.showToast("已批量标记 \(ids.count) 封为\(isRead ? "已读" : "未读")")
            } else {
                self.showToast("批量更新完成（\(failed) 封失败）")
            }
            self.refreshNow()
        }
    }

    func batchArchiveSelected() {
        let targets = messages.filter { selectedMessageIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        for id in ids {
            pendingRemovedIDs.insert(id)
            removeMessageLocally(rowID: id)
        }
        selectedMessageIDs = selectedMessageID.map { [$0] } ?? []

        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            for id in ids {
                do {
                    try await MailAppleScriptBridge.archiveMessage(rowID: id)
                } catch {
                    failed += 1
                }
                self.pendingRemovedIDs.remove(id)
            }
            if failed == 0 {
                self.showToast("已批量归档 \(ids.count) 封邮件")
            } else {
                self.reloadMessages()
                self.showToast("批量归档完成（\(failed) 封失败）")
            }
        }
    }

    func batchDeleteSelected() {
        let targets = messages.filter { selectedMessageIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        for id in ids {
            pendingRemovedIDs.insert(id)
            removeMessageLocally(rowID: id)
        }
        selectedMessageIDs = selectedMessageID.map { [$0] } ?? []

        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            for id in ids {
                do {
                    try await MailAppleScriptBridge.deleteMessage(rowID: id)
                } catch {
                    failed += 1
                }
                self.pendingRemovedIDs.remove(id)
            }
            if failed == 0 {
                self.showToast("已批量删除 \(ids.count) 封邮件")
            } else {
                self.reloadMessages()
                self.showToast("批量删除完成（\(failed) 封失败）")
            }
        }
    }

    func deleteMessage(_ message: MailMessageSummary) {
        pendingRemovedIDs.insert(message.id)
        removeMessageLocally(rowID: message.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await MailAppleScriptBridge.deleteMessage(rowID: message.id)
                self.pendingRemovedIDs.remove(message.id)
                self.showToast("已移入废纸篓")
            } catch {
                self.pendingRemovedIDs.remove(message.id)
                self.reloadMessages()
                self.showToast("删除失败：\(error.localizedDescription)")
            }
        }
    }

    func archiveMessage(_ message: MailMessageSummary) {
        pendingRemovedIDs.insert(message.id)
        removeMessageLocally(rowID: message.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await MailAppleScriptBridge.archiveMessage(rowID: message.id)
                self.pendingRemovedIDs.remove(message.id)
                self.showToast("已归档")
            } catch {
                self.pendingRemovedIDs.remove(message.id)
                self.reloadMessages()
                self.showToast("归档失败：\(error.localizedDescription)")
            }
        }
    }

    private func removeMessageLocally(rowID: Int64) {
        guard let idx = messages.firstIndex(where: { $0.id == rowID }) else { return }
        messages.remove(at: idx)
        if selectedMessageID == rowID {
            if idx < messages.count {
                selectedMessageID = messages[idx].id
            } else {
                selectedMessageID = messages.last?.id
            }
        }
    }

    private func refreshAccountEmailsIfEmpty() {
        guard accountEmails.isEmpty else { return }
        Task {
            let fetched = await MailAppleScriptBridge.fetchAccountEmails()
            self.accountEmails = fetched
            if self.composeDraft.fromEmail.isEmpty, let first = fetched.first {
                self.composeDraft.fromEmail = first
            }
        }
    }

    private func parseEmailList(_ raw: String) -> [String] {
        raw
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "；", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - AI Assistant Actions

    /// Streams a concise summary directly into the inline card above the email body (Scheme A).
    func summarizeSelectedEmailInline() {
        guard let message = selectedMessage, let body = selectedBody else { return }
        if let cached = summaryCache[message.id], !cached.isEmpty {
            inlineSummaryText = cached
            showInlineSummary = true
            return
        }

        let targetID = message.id
        showInlineSummary = true
        isInlineSummarizing = true
        inlineSummaryText = ""

        let prompt = """
        请用中文极简总结这封邮件（总字数控制在 100 字以内，直奔重点，不要客套）：
        ## 结论
        （1 句话概括）
        ## 要点
        - （最多 3 条短句）
        ## 行动
        （如需操作写明动作，否则写「无需操作」）
        """
        let context = buildSingleEmailContext(message: message, body: body)
        let configSnapshot = aiConfig

        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.aiService.chat(
                    config: configSnapshot,
                    systemPrompt: context,
                    history: [],
                    userMessage: prompt,
                    onPartial: { [weak self] partialText in
                        Task { @MainActor [weak self] in
                            guard let self, self.selectedMessageID == targetID else { return }
                            self.inlineSummaryText = partialText
                        }
                    }
                )
                self.summaryCache[targetID] = reply
                if self.selectedMessageID == targetID {
                    self.inlineSummaryText = reply
                }
            } catch {
                if self.selectedMessageID == targetID {
                    self.inlineSummaryText = "总结失败：\(error.localizedDescription)"
                }
            }
            if self.selectedMessageID == targetID {
                self.isInlineSummarizing = false
            }
        }
    }

    func continueInlineSummaryInDrawer() {
        if !inlineSummaryText.isEmpty && !aiMessages.contains(where: { $0.content == inlineSummaryText }) {
            aiMessages.append(AIChatMessage(role: .assistant, content: inlineSummaryText))
        }
        showAIPanel = true
    }

    func summarizeSelectedEmail() {
        guard let message = selectedMessage, let body = selectedBody else { return }
        if let cached = summaryCache[message.id] {
            aiMessages.append(AIChatMessage(role: .assistant, content: cached))
            return
        }
        let prompt = """
        请用中文极简总结这封邮件（总字数控制在 100 字以内，直奔重点，不要客套）：
        ## 结论
        （1 句话概括）
        ## 要点
        - （最多 3 条短句）
        ## 行动
        （如需操作写明动作，否则写「无需操作」）
        """
        runAIQuery(
            userPrompt: prompt,
            contextOverride: buildSingleEmailContext(message: message, body: body),
            captureAsDraft: false,
            showUserBubble: false,
            cacheSummaryForRowID: message.id
        )
    }

    func generateReplyDraft(tone: String = "专业简洁") {
        guard let message = selectedMessage, let body = selectedBody else { return }
        showAIPanel = true
        let prompt = """
        请帮我起草一封回复邮件，语气要求：\(tone)。
        直接输出邮件正文内容（不要输出解释性前后缀），方便我直接放入草稿箱修改后发送。
        """
        runAIQuery(
            userPrompt: prompt,
            contextOverride: buildSingleEmailContext(message: message, body: body),
            captureAsDraft: true,
            showUserBubble: false
        )
    }

    func generateUnreadBriefing() {
        let unread = messages.filter { !$0.isRead }.prefix(20)
        guard !unread.isEmpty else {
            showToast("当前列表没有未读邮件")
            return
        }
        let digest = unread.enumerated().map { idx, item in
            "\(idx + 1). [\(item.mailboxName)] 发件人: \(item.displaySender) <\(item.senderAddress)> | 主题: \(item.subject) | 时间: \(item.dateReceived.formatted(date: .abbreviated, time: .shortened))"
        }.joined(separator: "\n")

        let prompt = "请根据以下未读邮件列表，按紧急程度分类汇总一份中文简报，并指出最需要优先处理的前 3 封：\n\n\(digest)"
        runAIQuery(
            userPrompt: prompt,
            contextOverride: "你是一位高效的中文邮件助理，擅长对收件箱进行优先级分级。",
            captureAsDraft: false,
            showUserBubble: false
        )
    }

    func sendCustomAIQuestion() {
        let question = aiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        aiInput = ""

        let context: String
        if let message = selectedMessage, let body = selectedBody {
            context = buildSingleEmailContext(message: message, body: body)
        } else {
            context = "你是一位高效的中文邮件助理。"
        }
        runAIQuery(userPrompt: question, contextOverride: context, captureAsDraft: false, showUserBubble: true)
    }

    private func runAIQuery(
        userPrompt: String,
        contextOverride: String,
        captureAsDraft: Bool,
        showUserBubble: Bool,
        cacheSummaryForRowID: Int64? = nil
    ) {
        let historySnapshot = aiMessages
        if showUserBubble {
            aiMessages.append(AIChatMessage(role: .user, content: userPrompt))
        }
        let placeholderID = UUID()
        aiMessages.append(AIChatMessage(id: placeholderID, role: .assistant, content: ""))
        isAIThinking = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.aiService.chat(
                    config: self.aiConfig,
                    systemPrompt: contextOverride,
                    history: historySnapshot,
                    userMessage: userPrompt,
                    onPartial: { [weak self] partialText in
                        Task { @MainActor [weak self] in
                            self?.updateAssistantMessage(id: placeholderID, content: partialText)
                        }
                    }
                )
                self.updateAssistantMessage(id: placeholderID, content: reply)
                if captureAsDraft {
                    self.lastGeneratedDraft = reply
                }
                if let rowID = cacheSummaryForRowID {
                    self.summaryCache[rowID] = reply
                }
            } catch {
                self.updateAssistantMessage(id: placeholderID, content: "请求失败：\(error.localizedDescription)")
            }
            self.isAIThinking = false
        }
    }

    private func updateAssistantMessage(id: UUID, content: String) {
        guard let idx = aiMessages.firstIndex(where: { $0.id == id }) else { return }
        let old = aiMessages[idx]
        aiMessages[idx] = AIChatMessage(id: old.id, role: old.role, content: content, createdAt: old.createdAt)
    }

    private func buildSingleEmailContext(message: MailMessageSummary, body: ParsedMailBody) -> String {
        let clippedBody = String(body.plainText.prefix(4000))
        return """
        你是 MailPilot 内置的邮件 AI 助手。以下是用户当前阅读的邮件上下文：
        - 主题：\(message.subject)
        - 发件人：\(message.displaySender) <\(message.senderAddress)>
        - 收件时间：\(message.dateReceived.formatted(date: .complete, time: .shortened))
        - 所属邮箱：\(message.mailboxName)

        邮件正文：
        \(clippedBody)
        """
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

    // MARK: - Attachment Actions

    func materializeAttachmentURL(_ attachment: MailAttachment) -> URL? {
        if let local = attachment.localFileURL, FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        guard let data = attachment.inlineData else { return nil }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = caches
            .appendingPathComponent("MailPilot/Attachments", isDirectory: true)
            .appendingPathComponent("\(selectedMessageID ?? 0)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let safeName = attachment.filename.replacingOccurrences(of: "/", with: "_")
        let targetURL = folder.appendingPathComponent(safeName)
        do {
            try data.write(to: targetURL, options: .atomic)
            return targetURL
        } catch {
            showToast("导出附件失败：\(error.localizedDescription)")
            return nil
        }
    }

    func openAttachment(_ attachment: MailAttachment) {
        guard let url = materializeAttachmentURL(attachment) else {
            showToast("无法打开附件：本地文件尚未缓存")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealAttachmentInFinder(_ attachment: MailAttachment) {
        guard let url = materializeAttachmentURL(attachment) else {
            showToast("无法定位附件")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func saveAttachmentAs(_ attachment: MailAttachment) {
        guard let sourceURL = materializeAttachmentURL(attachment) else {
            showToast("无法保存附件")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        if panel.runModal() == .OK, let dest = panel.url {
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: sourceURL, to: dest)
                showToast("已保存附件到 \(dest.lastPathComponent)")
            } catch {
                showToast("保存失败：\(error.localizedDescription)")
            }
        }
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

    private func saveAIConfig() {
        if let data = try? JSONEncoder().encode(aiConfig) {
            UserDefaults.standard.set(data, forKey: Self.aiConfigStorageKey)
        }
    }
}
