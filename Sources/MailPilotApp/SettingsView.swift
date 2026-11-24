#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar Navigation
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        viewModel.settingsTab = tab
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(viewModel.settingsTab == tab ? .white : tabColor(tab))
                                .frame(width: 24, height: 24)
                                .background(
                                    viewModel.settingsTab == tab ? tabColor(tab) : tabColor(tab).opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                            Text(tab.rawValue)
                                .font(.callout.weight(viewModel.settingsTab == tab ? .semibold : .regular))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            viewModel.settingsTab == tab ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("MailPilot 0.1")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .padding(12)
            .frame(width: 168)
            .background(.quaternary.opacity(0.35))

            Divider()

            // Right Detail Content
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch viewModel.settingsTab {
                    case .ai:
                        aiSettingsContent
                    case .accounts:
                        accountsSettingsContent
                    case .tags:
                        tagSettingsContent
                    case .notifications:
                        notificationSettingsContent
                    case .permissions:
                        permissionSettingsContent
                    }
                }
                .padding(22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
        .onAppear {
            viewModel.refreshAuthStatuses()
            viewModel.refreshNotificationStatus()
        }
        .sheet(isPresented: $viewModel.showIconPickerSheet) {
            AccountIconPickerSheet(viewModel: viewModel)
        }
    }

    // MARK: - AI Tab

    private var aiSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI 模型与订阅登录")
                .font(.title3.weight(.semibold))

            // Mode Cards
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                modeCard(
                    mode: .chatGPT,
                    icon: "person.crop.circle",
                    title: "ChatGPT 订阅",
                    subtitle: "浏览器登录 · 原生直连"
                )
                modeCard(
                    mode: .subscriptionCLI,
                    icon: "terminal.fill",
                    title: "订阅 CLI",
                    subtitle: "复用 Claude / ChatGPT"
                )
                modeCard(
                    mode: .oauthPKCE,
                    icon: "safari.fill",
                    title: "OAuth 登录",
                    subtitle: "浏览器授权存钥匙串"
                )
                modeCard(
                    mode: .apiKey,
                    icon: "key.fill",
                    title: "API / 本地",
                    subtitle: "Ollama / DeepSeek"
                )
            }
            .disabled(viewModel.isChatGPTSigningIn || viewModel.isChatGPTSigningOut || viewModel.isTestingChatGPT || viewModel.isAIThinking)

            // Active Mode Configuration Card
            settingsCard {
                switch viewModel.aiConfig.authMode {
                case .chatGPT:
                    chatGPTConfigCardBody
                case .subscriptionCLI:
                    cliConfigCardBody
                case .oauthPKCE:
                    oauthConfigCardBody
                case .apiKey:
                    apiKeyConfigCardBody
                }
            }

            // Privacy Card
            settingsCard {
                Toggle(isOn: $viewModel.aiConfig.maskSensitiveData) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("发送前本地隐私脱敏")
                            .font(.callout.weight(.medium))
                        Text("自动隐藏手机号、邮箱地址、银行卡号及 API 密钥后再发送给云端模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var chatGPTConfigCardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("使用你的 ChatGPT 订阅")
                .font(.headline)
            Text("通过 OpenAI 官方页面授权，使用符合条件账号的订阅额度。邮件只在你使用 AI 功能时发送；登录和验证连接不会发送邮件。")
                .font(.caption).foregroundStyle(.secondary)

            if !viewModel.chatGPTAccounts.isEmpty {
                Picker("账号", selection: Binding(
                    get: { viewModel.chatGPTAccount?.id ?? "" },
                    set: { viewModel.selectChatGPTAccount($0) }
                )) {
                    ForEach(viewModel.chatGPTAccounts) { account in
                        Text(account.label + (account.signedIn ? "" : "（已退出）")).tag(account.id)
                    }
                }
                .disabled(viewModel.isChatGPTSigningIn || viewModel.isChatGPTSigningOut || viewModel.isTestingChatGPT || viewModel.isAIThinking)
            }
            if let account = viewModel.chatGPTAccount, account.signedIn {
                Label(account.planEnabled ? "已登录 · 已授权订阅额度" : "已登录 · 未授权订阅额度",
                      systemImage: account.planEnabled ? "checkmark.seal.fill" : "exclamationmark.circle")
                    .foregroundStyle(account.planEnabled ? Color.green : Color.orange)
                    .font(.callout)
            }
            HStack {
                if viewModel.isChatGPTSigningIn {
                    ProgressView().controlSize(.small)
                    Text("等待浏览器授权…").font(.callout)
                    Button("取消") { viewModel.cancelChatGPTSignIn() }
                } else {
                    Button(viewModel.chatGPTAccount?.signedIn == true ? "重新授权 ChatGPT" : "使用 ChatGPT 登录") {
                        viewModel.startChatGPTSignIn()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isChatGPTSigningOut || viewModel.isAIThinking || viewModel.isTestingChatGPT)
                    if !viewModel.chatGPTAccounts.isEmpty {
                        Button("添加账号") { viewModel.startChatGPTSignIn(newAccount: true) }
                            .disabled(viewModel.isChatGPTSigningOut || viewModel.isAIThinking || viewModel.isTestingChatGPT)
                    }
                    if viewModel.chatGPTAccount?.signedIn == true {
                        Button("退出登录") { viewModel.signOutChatGPT() }
                            .disabled(viewModel.isChatGPTSigningOut)
                    }
                }
            }
            if let message = viewModel.chatGPTStatusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if viewModel.chatGPTAccount?.signedIn == true && viewModel.chatGPTAccount?.planEnabled == true {
                Divider()
                HStack {
                    Picker("模型", selection: Binding(
                        get: { viewModel.aiConfig.chatGPTModel ?? "" },
                        set: { viewModel.aiConfig.chatGPTModel = $0 }
                    )) {
                        if viewModel.aiConfig.chatGPTModel == nil { Text("请刷新模型列表").tag("") }
                        ForEach(viewModel.availableModels) { option in Text(option.displayName).tag(option.id) }
                    }
                    Button { viewModel.refreshAvailableModels() } label: { Image(systemName: "arrow.clockwise") }
                        .help("刷新此账号的可用模型")
                    if viewModel.isLoadingModels { ProgressView().controlSize(.small) }
                }
                .disabled(viewModel.isChatGPTSigningIn || viewModel.isChatGPTSigningOut || viewModel.isTestingChatGPT || viewModel.isAIThinking)
                Button(viewModel.isTestingChatGPT ? "验证中…" : "验证连接") { viewModel.testChatGPTConnection() }
                    .disabled(viewModel.aiConfig.chatGPTModel == nil || viewModel.isTestingChatGPT || viewModel.isAIThinking || viewModel.isChatGPTSigningOut || viewModel.isChatGPTSigningIn)
                Text("验证会发送一条简短测试消息，并占用少量订阅额度。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Link("查看 ChatGPT 使用量与应用授权", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                .font(.caption)
        }
    }

    private func modeCard(mode: AIAuthMode, icon: String, title: String, subtitle: String) -> some View {
        let isSelected = viewModel.aiConfig.authMode == mode
        return Button {
            viewModel.aiConfig.authMode = mode
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 1.5 : 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private var cliConfigCardBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择本机订阅服务")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("刷新检测") {
                    viewModel.refreshAuthStatuses()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(spacing: 8) {
                ForEach(SubscriptionCLIProvider.allCases) { provider in
                    let status = viewModel.cliStatuses.first(where: { $0.provider == provider })
                    let isSelected = viewModel.aiConfig.cliProvider == provider
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .font(.callout.weight(isSelected ? .medium : .regular))
                            Text(status?.executablePath ?? "未检测到 \(provider.rawValue)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(status?.isInstalled == true ? Color.green : Color.secondary)
                        }
                        Spacer()
                        if status?.isInstalled == true {
                            Button("终端登录") {
                                viewModel.openCLILoginInTerminal(provider)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.07) : Color.secondary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.aiConfig.cliProvider = provider
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("模型选择（自动同步最新模型）")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("刷新模型") {
                        viewModel.refreshAvailableModels()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                HStack(spacing: 8) {
                    Picker("", selection: $viewModel.aiConfig.cliModelOverride) {
                        Text("默认模型（跟随订阅）").tag("")
                        ForEach(viewModel.availableModels) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)

                    TextField("或输入自定义模型名", text: $viewModel.aiConfig.cliModelOverride)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("自定义可执行路径（可选）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("留空自动探测 Homebrew / ~/.local/bin", text: $viewModel.aiConfig.cliCustomPath)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var oauthConfigCardBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("OAuth 平台")
                    .font(.callout.weight(.medium))
                Spacer()
                Picker("", selection: $viewModel.aiConfig.oauth.kind) {
                    ForEach(OAuthProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
                .onChange(of: viewModel.aiConfig.oauth.kind) { _, newKind in
                    if newKind == .openRouter {
                        viewModel.aiConfig.oauth.authorizationURL = "https://openrouter.ai/auth"
                        viewModel.aiConfig.oauth.tokenURL = "https://openrouter.ai/api/v1/auth/keys"
                        viewModel.aiConfig.oauth.apiBaseURL = "https://openrouter.ai/api/v1"
                    }
                    viewModel.refreshAuthStatuses()
                }
            }

            HStack {
                if let bundle = viewModel.oauthTokenBundle {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("已登录：\(bundle.accountLabel ?? "订阅账号")", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.callout.weight(.medium))
                        Text("令牌已加密保存于 macOS 系统钥匙串")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("退出登录", role: .destructive) {
                        viewModel.signOutOAuth()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        viewModel.startOAuthSignIn()
                    } label: {
                        if viewModel.isOAuthSigningIn {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("等待浏览器授权...")
                            }
                        } else {
                            Label("通过浏览器登录订阅账号", systemImage: "safari")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isOAuthSigningIn)
                    Spacer()
                }
            }

            if let msg = viewModel.oauthStatusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("模型名称")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Picker("", selection: $viewModel.aiConfig.oauth.model) {
                        ForEach(viewModel.currentSuggestedModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    TextField("自定义模型", text: $viewModel.aiConfig.oauth.model)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if viewModel.aiConfig.oauth.kind == .customPKCE {
                VStack(alignment: .leading, spacing: 8) {
                    labeledField("Authorization URL", text: $viewModel.aiConfig.oauth.authorizationURL)
                    labeledField("Token URL", text: $viewModel.aiConfig.oauth.tokenURL)
                    labeledField("Client ID", text: $viewModel.aiConfig.oauth.clientID)
                    labeledField("API Base URL", text: $viewModel.aiConfig.oauth.apiBaseURL)
                }
            }
        }
    }

    private var apiKeyConfigCardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("快捷预设：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("本地 Ollama") {
                    viewModel.aiConfig.baseURL = "http://localhost:11434/v1"
                    viewModel.aiConfig.model = "qwen2.5:14b"
                    viewModel.aiConfig.apiKey = ""
                }
                Button("DeepSeek") {
                    viewModel.aiConfig.baseURL = "https://api.deepseek.com/v1"
                    viewModel.aiConfig.model = "deepseek-chat"
                }
                Button("OpenAI") {
                    viewModel.aiConfig.baseURL = "https://api.openai.com/v1"
                    viewModel.aiConfig.model = "gpt-4o-mini"
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            labeledField("Base URL", text: $viewModel.aiConfig.baseURL)
            labeledField("Model", text: $viewModel.aiConfig.model)
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key（本地 Ollama 可留空）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("sk-...", text: $viewModel.aiConfig.apiKey)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Accounts Tab

    private var accountsSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("邮箱账号设置")
                .font(.title3.weight(.semibold))

            if viewModel.groupedMailboxes.isEmpty {
                settingsCard {
                    Text("尚未检测到邮箱账号，请先在系统 Mail.app 登录邮箱并授予完全磁盘访问权限。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Multi-row adaptive grid so all accounts are visible at once without horizontal scrolling
                let columns = [GridItem(.adaptive(minimum: 125, maximum: 180), spacing: 8)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(viewModel.groupedMailboxes) { group in
                        let isSelected = viewModel.selectedSettingsAccountID == group.id
                        Button {
                            viewModel.selectedSettingsAccountID = group.id
                        } label: {
                            HStack(spacing: 6) {
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
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 1.2 : 0.6)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let activeGroup = viewModel.groupedMailboxes.first(where: { $0.id == viewModel.selectedSettingsAccountID }) ?? viewModel.groupedMailboxes.first {
                    Text("基本信息")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)

                    settingsCard {
                        VStack(spacing: 14) {
                            // 1. Sender Display Name
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("发件人名称")
                                        .font(.callout.weight(.medium))
                                    Text("收件人看到的名字")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                TextField(
                                    "例如：Jay Zhao",
                                    text: Binding(
                                        get: { viewModel.customization(for: activeGroup.id).senderDisplayName },
                                        set: { val in viewModel.updateCustomization(for: activeGroup.id) { $0.senderDisplayName = val } }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                            }

                            Divider()

                            // 2. Sidebar Display Name
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("侧栏显示名称")
                                        .font(.callout.weight(.medium))
                                    Text(activeGroup.email ?? "留空显示默认邮箱")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                TextField(
                                    "留空显示完整邮箱",
                                    text: Binding(
                                        get: { viewModel.customization(for: activeGroup.id).sidebarName },
                                        set: { val in viewModel.updateCustomization(for: activeGroup.id) { $0.sidebarName = val } }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                            }

                            Divider()

                            // 3. Account Icon
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("账户图标")
                                        .font(.callout.weight(.medium))
                                    Text("显示在侧边栏和账户列表中")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                AccountLogoView(
                                    accountID: activeGroup.id,
                                    email: activeGroup.email,
                                    customIconPath: activeGroup.customIconPath,
                                    presetLogoID: activeGroup.presetLogoID,
                                    sfSymbolName: activeGroup.sfSymbolName,
                                    fallbackColor: viewModel.accountBadgeColor(for: activeGroup.id),
                                    size: 26
                                )
                                Button("选择图标...") {
                                    viewModel.openIconPicker(for: activeGroup)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Divider()

                            // 4. Default Send Account
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("设为默认发件账户")
                                        .font(.callout.weight(.medium))
                                    Text("在「全部收件箱」里写邮件时使用")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { viewModel.defaultSendAccountID.uppercased() == activeGroup.id.uppercased() },
                                        set: { isOn in
                                            viewModel.defaultSendAccountID = isOn ? activeGroup.id : ""
                                        }
                                    )
                                )
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tags Tab

    private var tagSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("智能邮件标签")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("恢复默认") {
                    viewModel.resetTagSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            settingsCard {
                Toggle(isOn: $viewModel.tagSettings.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用智能邮件标签")
                            .font(.callout.weight(.medium))
                        Text("根据发件人与主题零延迟自动归类，在邮件列表与左侧边栏展示")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            if viewModel.tagSettings.isEnabled {
                settingsCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("标签规则与自定义关键词")
                            .font(.callout.weight(.semibold))

                        ForEach(MailSmartTag.allCases) { tag in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 10) {
                                    SmartTagPill(tag: tag)
                                    Text(tag.descriptionText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Toggle(
                                        "",
                                        isOn: Binding(
                                            get: { viewModel.tagSettings.isTagEnabled(tag) },
                                            set: { viewModel.setTag(tag, enabled: $0) }
                                        )
                                    )
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                }

                                if viewModel.tagSettings.isTagEnabled(tag) {
                                    TextField(
                                        "追加关键词（逗号分隔，例如：阿里云, 顺丰）",
                                        text: Binding(
                                            get: { viewModel.tagSettings.customKeywords[tag.rawValue] ?? "" },
                                            set: { viewModel.setCustomKeywords($0, for: tag) }
                                        )
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                }
                            }

                            if tag != MailSmartTag.allCases.last {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Notifications Tab

    private var notificationSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("桌面通知")
                .font(.title3.weight(.semibold))

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $viewModel.notificationsEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("由 MailPilot 弹出新邮件桌面横幅")
                                .font(.callout.weight(.medium))
                            Text("自动识别验证码并在通知中展示，点击通知直达对应邮件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("系统通知权限状态")
                                .font(.callout)
                            Text(viewModel.notificationAuthStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("发送测试通知") {
                            viewModel.sendTestNotification()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("系统通知设置") {
                            viewModel.openNotificationSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            settingsCard {
                Label("开启 MailPilot 通知后，可以在「系统设置 → 通知 → 邮件」中关闭系统 Mail.app 的横幅，避免重复弹窗（只需保持 Mail.app 后台运行不按 ⌘Q 退出即可）。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Permissions Tab

    private var permissionSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("macOS 系统权限")
                .font(.title3.weight(.semibold))

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("完全磁盘访问权限")
                                .font(.callout.weight(.medium))
                            Text("用于严格只读访问 ~/Library/Mail 原生邮件索引与正文")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("前往设置") {
                            viewModel.openFullDiskAccessSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动化控制「邮件」App")
                                .font(.callout.weight(.medium))
                            Text("用于自动标记已读、添加旗标、创建回复草稿及触发收信")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("前往设置") {
                            viewModel.openAutomationSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.45), lineWidth: 0.6)
        )
    }

    private func labeledField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func tabColor(_ tab: SettingsTab) -> Color {
        switch tab {
        case .ai: return .purple
        case .accounts: return .indigo
        case .tags: return .teal
        case .notifications: return .orange
        case .permissions: return .blue
        }
    }
}
