#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

struct AIAssistantPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var ai: AIAssistantController

    init(viewModel: AppViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._ai = ObservedObject(wrappedValue: viewModel.ai)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Label("AI 助手", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if ai.aiConfig.maskSensitiveData {
                    Text("已脱敏")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.14), in: Capsule())
                        .foregroundStyle(.green)
                }
                Button {
                    viewModel.settingsTab = .ai
                    viewModel.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("打开 AI 订阅与模型设置")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Model & Provider Picker Bar
            HStack(spacing: 6) {
                Menu {
                    Section("当前模式模型") {
                        if ai.aiConfig.authMode == .subscriptionCLI {
                            Button {
                                ai.selectModel("")
                            } label: {
                                if ai.aiConfig.cliModelOverride.isEmpty {
                                    Label("默认模型（跟随订阅）", systemImage: "checkmark")
                                } else {
                                    Text("默认模型（跟随订阅）")
                                }
                            }
                        }
                        ForEach(ai.availableModels) { option in
                            Button {
                                ai.selectModel(option.id)
                            } label: {
                                let title = option.displayName == option.id ? option.id : "\(option.displayName) (\(option.id))"
                                if ai.activeModelDisplayName == option.id {
                                    Label(title, systemImage: "checkmark")
                                } else {
                                    Text(title)
                                }
                            }
                        }

                        Button {
                            ai.refreshAvailableModels()
                        } label: {
                            Label("刷新最新模型列表", systemImage: "arrow.clockwise")
                        }
                    }

                    Divider()

                    Section("快捷切换订阅 / 通道") {
                        Button("ChatGPT 订阅（浏览器登录）") {
                            ai.aiConfig.authMode = .chatGPT
                        }
                        ForEach(SubscriptionCLIProvider.allCases) { provider in
                            Button {
                                ai.switchCLIProvider(provider)
                            } label: {
                                let installed = ai.cliStatuses.first(where: { $0.provider == provider })?.isInstalled == true
                                let suffix = installed ? "" : "（未安装）"
                                if ai.aiConfig.authMode == .subscriptionCLI && ai.aiConfig.cliProvider == provider {
                                    Label("\(provider.shortBadge)\(suffix)", systemImage: "checkmark")
                                } else {
                                    Text("\(provider.shortBadge)\(suffix)")
                                }
                            }
                        }

                        Button {
                            ai.aiConfig.authMode = .oauthPKCE
                        } label: {
                            if ai.aiConfig.authMode == .oauthPKCE {
                                Label("浏览器 OAuth 登录", systemImage: "checkmark")
                            } else {
                                Text("浏览器 OAuth 登录")
                            }
                        }

                        Button {
                            ai.aiConfig.authMode = .apiKey
                        } label: {
                            if ai.aiConfig.authMode == .apiKey {
                                Label("API Key / 本地模型", systemImage: "checkmark")
                            } else {
                                Text("API Key / 本地模型")
                            }
                        }
                    }

                    Divider()

                    Button("更多模型与登录设置...") {
                        viewModel.settingsTab = .ai
                        viewModel.showSettings = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                        Text(ai.activeAIBadge)
                            .font(.caption.weight(.medium))
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(ai.activeModelDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Quick Actions
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        ai.summarizeSelectedEmail()
                    } label: {
                        Label("总结邮件", systemImage: "text.alignleft")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.selectedMessage == nil || ai.isAIThinking)

                    Button {
                        ai.generateReplyDraft(tone: "专业简洁")
                    } label: {
                        Label("起草回复", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.selectedMessage == nil || ai.isAIThinking)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let draft = ai.lastGeneratedDraft {
                    Button {
                        ai.sendDraftToMailApp(body: draft)
                    } label: {
                        Label("填入应用内回复窗口并发送", systemImage: "paperplane.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            Divider()

            // Conversation Feed
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if ai.aiMessages.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "sparkles")
                                    .font(.title2)
                                    .foregroundStyle(Color.accentColor.opacity(0.8))
                                Text("随时帮你总结邮件、起草回复，或解答当前邮件中的细节问题。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .padding(.horizontal, 16)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.top, 8)
                        }

                        ForEach(ai.aiMessages.filter { !$0.content.isEmpty }) { msg in
                            if msg.role == .user {
                                HStack {
                                    Spacer(minLength: 24)
                                    Text(msg.content)
                                        .font(.callout)
                                        .foregroundStyle(.white)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .id(msg.id)
                            } else {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Label(
                                            msg.isError ? "请求失败" : "AI 摘要",
                                            systemImage: msg.isError ? "exclamationmark.triangle.fill" : "sparkles"
                                        )
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(msg.isError ? Color.orange : Color.accentColor)
                                        Spacer()
                                        Button {
                                            viewModel.copyToClipboard(msg.content, label: "已复制内容")
                                        } label: {
                                            Image(systemName: "doc.on.doc")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                        .help("复制结果")
                                    }

                                    MarkdownBlockView(text: msg.content)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(.separator.opacity(0.55), lineWidth: 0.7)
                                )
                                .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
                                .id(msg.id)
                            }
                        }

                        if ai.isAIThinking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("AI 思考中...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: ai.aiMessages.count) { _, _ in
                    if let last = ai.aiMessages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Prompt Input
            HStack(spacing: 8) {
                TextField("问这封邮件任何问题...", text: $ai.aiInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        ai.sendCustomAIQuestion()
                    }
                    .disabled(ai.isAIThinking)

                Button {
                    ai.sendCustomAIQuestion()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(ai.aiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ai.isAIThinking)
            }
            .padding(10)
        }
        .background(.background)
    }
}
