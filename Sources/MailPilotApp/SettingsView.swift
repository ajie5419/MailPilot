#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var ai: AIAssistantController
    @ObservedObject var bodyIndex: BodyIndexCoordinator

    init(viewModel: AppViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._ai = ObservedObject(wrappedValue: viewModel.ai)
        self._bodyIndex = ObservedObject(wrappedValue: viewModel.bodyIndex)
    }

    private var appVersionLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
    }

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
                Text("MailPilot \(appVersionLabel)")
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
            ai.refreshAuthStatuses()
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
            .disabled(ai.isChatGPTSigningIn || ai.isChatGPTSigningOut || ai.isTestingChatGPT || ai.isAIThinking)

            // Active Mode Configuration Card
            settingsCard {
                switch ai.aiConfig.authMode {
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
                Toggle(isOn: $ai.aiConfig.maskSensitiveData) {
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
        let isSignedIn = ai.chatGPTAccount?.signedIn == true
        let isPlanEnabled = ai.chatGPTAccount?.planEnabled == true
        let isBusy = ai.isChatGPTSigningIn || ai.isChatGPTSigningOut || ai.isTestingChatGPT || ai.isAIThinking

        return VStack(alignment: .leading, spacing: 14) {
            // Header row: Title + concise status pill + usage link
            HStack(spacing: 8) {
                Text("ChatGPT 订阅")
                    .font(.headline)

                if isSignedIn {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isPlanEnabled ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(isPlanEnabled ? "已授权" : "未授权额度")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isPlanEnabled ? Color.green : Color.orange)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background((isPlanEnabled ? Color.green : Color.orange).opacity(0.11), in: Capsule())
                } else {
                    Text("未登录")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
                }

                Spacer()

                Link(destination: URL(string: "https://chatgpt.com/settings/usage")!) {
                    HStack(spacing: 3) {
                        Text("用量与授权")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.caption)
                }
            }

            Text("通过 OpenAI 官方页面授权使用订阅额度；仅在你主动触发 AI 功能时发送邮件内容。")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Account section
            VStack(alignment: .leading, spacing: 10) {
                if !ai.chatGPTAccounts.isEmpty {
                    HStack(spacing: 10) {
                        Text("账号")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { ai.chatGPTAccount?.id ?? "" },
                            set: { ai.selectChatGPTAccount($0) }
                        )) {
                            ForEach(ai.chatGPTAccounts) { account in
                                Text(account.label + (account.signedIn ? "" : "（已退出）")).tag(account.id)
                            }
                        }
                        .labelsHidden()
                        .disabled(isBusy)
                    }
                }

                HStack(spacing: 8) {
                    if ai.isChatGPTSigningIn {
                        ProgressView().controlSize(.small)
                        Text("等待浏览器完成授权…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { ai.cancelChatGPTSignIn() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else if isSignedIn && isPlanEnabled {
                        Button("重新授权") { ai.startChatGPTSignIn() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isBusy)
                        Button("添加账号") { ai.startChatGPTSignIn(newAccount: true) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isBusy)
                        Spacer()
                        Button("退出登录", role: .destructive) { ai.signOutChatGPT() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(ai.isChatGPTSigningOut)
                    } else {
                        Button(isSignedIn ? "重新授权订阅额度" : "使用 ChatGPT 登录") {
                            ai.startChatGPTSignIn()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(isBusy)
                        if !ai.chatGPTAccounts.isEmpty {
                            Button("添加账号") { ai.startChatGPTSignIn(newAccount: true) }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .disabled(isBusy)
                        }
                        if isSignedIn {
                            Spacer()
                            Button("退出登录", role: .destructive) { ai.signOutChatGPT() }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .disabled(ai.isChatGPTSigningOut)
                        }
                    }
                }

                if let message = ai.chatGPTStatusMessage, !message.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 1)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            // Model & Connection Verification section
            if isSignedIn && isPlanEnabled {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("模型")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .leading)

                        Picker("", selection: Binding(
                            get: { ai.aiConfig.chatGPTModel ?? "" },
                            set: { ai.aiConfig.chatGPTModel = $0 }
                        )) {
                            if ai.aiConfig.chatGPTModel == nil {
                                Text("请选择模型").tag("")
                            }
                            ForEach(ai.availableModels) { option in
                                Text(option.displayName).tag(option.id)
                            }
                        }
                        .labelsHidden()
                        .disabled(isBusy)

                        Button {
                            ai.refreshAvailableModels()
                        } label: {
                            if ai.isLoadingModels {
                                ProgressView().controlSize(.mini)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isBusy || ai.isLoadingModels)
                        .help("刷新可用模型列表")

                        Button {
                            ai.testChatGPTConnection()
                        } label: {
                            HStack(spacing: 5) {
                                if ai.isTestingChatGPT {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "bolt.horizontal.fill")
                                        .font(.caption)
                                }
                                Text(ai.isTestingChatGPT ? "验证中…" : "验证连接")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(ai.aiConfig.chatGPTModel == nil || isBusy)
                    }

                    // Immediate, high-visibility connection test feedback directly below the action row
                    switch ai.chatGPTTestState {
                    case .idle:
                        Text("点击「验证连接」会发送一条极短测试消息（不含邮件内容），确认当前模型可正常响应。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    case .testing:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在向 \(ai.aiConfig.chatGPTModel ?? "模型") 发送不含邮件内容的测试请求…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    case .success(let detail):
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout)
                            Text(detail)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.green.opacity(0.28), lineWidth: 0.75)
                        )
                    case .failure(let detail):
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.red.opacity(0.28), lineWidth: 0.75)
                        )
                    }
                }
            }
        }
    }

    private func modeCard(mode: AIAuthMode, icon: String, title: String, subtitle: String) -> some View {
        let isSelected = ai.aiConfig.authMode == mode
        return Button {
            ai.aiConfig.authMode = mode
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.16), lineWidth: isSelected ? 1.4 : 0.75)
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
                    ai.refreshAuthStatuses()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(spacing: 8) {
                ForEach(SubscriptionCLIProvider.allCases) { provider in
                    let status = ai.cliStatuses.first(where: { $0.provider == provider })
                    let isSelected = ai.aiConfig.cliProvider == provider
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
                                ai.openCLILoginInTerminal(provider)
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
                        ai.aiConfig.cliProvider = provider
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
                        ai.refreshAvailableModels()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                HStack(spacing: 8) {
                    Picker("", selection: $ai.aiConfig.cliModelOverride) {
                        Text("默认模型（跟随订阅）").tag("")
                        ForEach(ai.availableModels) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)

                    TextField("或输入自定义模型名", text: $ai.aiConfig.cliModelOverride)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("自定义可执行路径（可选）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("留空自动探测 Homebrew / ~/.local/bin", text: $ai.aiConfig.cliCustomPath)
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
                Picker("", selection: $ai.aiConfig.oauth.kind) {
                    ForEach(OAuthProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
                .onChange(of: ai.aiConfig.oauth.kind) { _, newKind in
                    if newKind == .openRouter {
                        ai.aiConfig.oauth.authorizationURL = "https://openrouter.ai/auth"
                        ai.aiConfig.oauth.tokenURL = "https://openrouter.ai/api/v1/auth/keys"
                        ai.aiConfig.oauth.apiBaseURL = "https://openrouter.ai/api/v1"
                    }
                    ai.refreshAuthStatuses()
                }
            }

            HStack {
                if let bundle = ai.oauthTokenBundle {
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
                        ai.signOutOAuth()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        ai.startOAuthSignIn()
                    } label: {
                        if ai.isOAuthSigningIn {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("等待浏览器授权...")
                            }
                        } else {
                            Label("通过浏览器登录订阅账号", systemImage: "safari")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ai.isOAuthSigningIn)
                    Spacer()
                }
            }

            if let msg = ai.oauthStatusMessage {
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
                    Picker("", selection: $ai.aiConfig.oauth.model) {
                        ForEach(ai.currentSuggestedModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    TextField("自定义模型", text: $ai.aiConfig.oauth.model)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if ai.aiConfig.oauth.kind == .customPKCE {
                VStack(alignment: .leading, spacing: 8) {
                    labeledField("Authorization URL", text: $ai.aiConfig.oauth.authorizationURL)
                    labeledField("Token URL", text: $ai.aiConfig.oauth.tokenURL)
                    labeledField("Client ID", text: $ai.aiConfig.oauth.clientID)
                    labeledField("API Base URL", text: $ai.aiConfig.oauth.apiBaseURL)
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
                    ai.applyAPIPreset(baseURL: "http://localhost:11434/v1", model: "qwen2.5:14b")
                }
                Button("DeepSeek") {
                    ai.applyAPIPreset(baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
                }
                Button("OpenAI") {
                    ai.applyAPIPreset(baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            labeledField("Base URL", text: Binding(
                get: { ai.aiConfig.baseURL },
                set: { ai.updateAPIBaseURL($0) }
            ))
            labeledField("Model", text: $ai.aiConfig.model)
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key（按服务域名隔离加密存入系统钥匙串，本地 Ollama 可留空）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("sk-...", text: Binding(
                    get: { ai.aiConfig.apiKey },
                    set: { ai.updateAPIKey($0) }
                ))
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

                            Divider()

                            // 5. Account Signature
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("默认发件签名")
                                        .font(.callout.weight(.medium))
                                    Spacer()
                                    Text("写信、回复、转发时自动附在正文末尾")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                TextEditor(
                                    text: Binding(
                                        get: { viewModel.customization(for: activeGroup.id).signature },
                                        set: { val in viewModel.updateCustomization(for: activeGroup.id) { $0.signature = val } }
                                    )
                                )
                                .font(.callout)
                                .frame(height: 70)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(.separator, lineWidth: 0.7)
                                )
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
            Text("隐私与网络安全")
                .font(.title3.weight(.semibold))

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $viewModel.blockRemoteImages) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("默认拦截邮件远程图片与外部资源")
                                .font(.callout.weight(.medium))
                            Text("防止追踪像素泄露 IP 与阅读时间；内嵌截图（cid:）仍正常显示，单封邮件可按需临时放行")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    Toggle(isOn: Binding(
                        get: { viewModel.allowOnlineBrandAvatars },
                        set: { viewModel.allowOnlineBrandAvatars = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("允许联网获取发件人品牌头像")
                                .font(.callout.weight(.medium))
                            Text("关闭时仅使用本地字母头像与内置品牌图标，不向第三方图标服务外发发件人域名")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本地正文全文搜索缓存")
                                .font(.callout.weight(.medium))
                            Text("当前已索引 \(bodyIndex.indexedBodyCount) 封邮件正文（仅保存在本机缓存，绝不改动原邮件库）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let errorMsg = bodyIndex.errorMessage, !errorMsg.isEmpty {
                                Text("最近索引异常：\(errorMsg)")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        if bodyIndex.errorMessage != nil {
                            Button("重试索引") {
                                viewModel.retryBodySearchIndexing()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        Button("重建索引") {
                            viewModel.rebuildBodySearchIndex()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("清空缓存") {
                            viewModel.clearBodySearchIndex()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

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
