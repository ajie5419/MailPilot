#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

extension SettingsView {
    // MARK: - AI Tab

    var aiSettingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        isSelected ? BrandPalette.coral : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                        .font(.callout)
                        .foregroundStyle(BrandPalette.coral)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                BrandPalette.floatingCardFill(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? BrandPalette.coral : BrandPalette.floatingCardBorder(for: colorScheme),
                        lineWidth: isSelected ? 1.5 : 0.85
                    )
            )
            .shadow(color: BrandPalette.floatingCardShadow(for: colorScheme), radius: 6, y: 2)
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

}
