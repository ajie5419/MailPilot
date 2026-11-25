import AppKit
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI
import UniformTypeIdentifiers

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

extension AppViewModel {
    // MARK: - Account Lookups & Customizations

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

    func accountBadgeColor(for accountID: String) -> Color {
        let key = accountID.uppercased()
        if let color = cachedAccountLookup[key]?.color {
            return color
        }
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
        let hash = abs(key.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return palette[hash % palette.count]
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

    func saveAccountCustomizations() {
        if let data = try? JSONEncoder().encode(accountCustomizations) {
            UserDefaults.standard.set(data, forKey: Self.accountCustomizationsKey)
        }
    }

    // MARK: - Sender Resolution & Account Sync

    func preferredSenderEmail() -> String {
        if !defaultSendAccountID.isEmpty,
           let email = accountEmail(for: defaultSendAccountID), !email.isEmpty {
            return email
        }
        return accountEmails.first ?? ""
    }

    /// Resolves the exact sender email for a message's originating account.
    /// Returns `nil` when the originating account is missing/unavailable rather than silently switching to another account.
    func senderEmail(forOriginAccountID accountID: String) -> String? {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty, normalized != "LOCAL" else { return nil }
        if let email = accountEmail(for: normalized), !email.isEmpty {
            return email
        }
        if let matched = accounts.first(where: { $0.id.uppercased() == normalized }), !matched.email.isEmpty {
            return matched.email
        }
        return nil
    }

    func formattedSenderHeader(for rawEmail: String) -> String? {
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

    func signature(forSenderEmail rawEmail: String) -> String? {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return nil }
        if let matchedGroup = groupedMailboxes.first(where: { $0.email?.caseInsensitiveCompare(email) == .orderedSame }) {
            let sig = customization(for: matchedGroup.id).signature.trimmingCharacters(in: .whitespacesAndNewlines)
            return sig.isEmpty ? nil : sig
        }
        return nil
    }

    func refreshAccountEmailsIfEmpty() {
        guard accountEmails.isEmpty else { return }
        Task {
            let fetched = await MailAppleScriptBridge.fetchAccountEmails()
            self.accountEmails = fetched
            if self.compose.draft.fromEmail.isEmpty, let first = fetched.first {
                self.compose.draft.fromEmail = first
            }
        }
    }

    /// Re-fetches Mail.app accounts whenever a newly added account UUID (e.g. Outlook/Exchange)
    /// appears in `Envelope Index` after launch.
    func syncAccountsIfUnknownMailboxPresent(_ mailboxes: [MailboxInfo]) {
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

    // MARK: - Sidebar Grouping Cache

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

    /// Rebuilds grouped sidebar mailboxes and O(1) account lookup cache only when accounts or mailboxes change.
    func rebuildAccountGroupingCache() {
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
        var lookup: [String: CachedAccountMeta] = [:]
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
                lookup[key] = CachedAccountMeta(
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
                lookup[key] = CachedAccountMeta(
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
}
