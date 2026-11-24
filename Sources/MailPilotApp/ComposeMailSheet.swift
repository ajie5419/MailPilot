import AppKit
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

enum ComposeMode: String {
    case new = "写新邮件"
    case reply = "回复邮件"
    case forward = "转发邮件"
}

struct ComposeDraftState {
    var id: UUID = UUID()
    var revision: Int = 0
    var mode: ComposeMode = .new
    var fromEmail: String = ""
    var toText: String = ""
    var ccText: String = ""
    var subject: String = ""
    var body: String = ""
    var attachmentURLs: [URL] = []
    var isSending: Bool = false
    var isAIPolishing: Bool = false
    var pendingAIPolish: String? = nil
    var polishBaseRevision: Int? = nil
    var missingOriginAccountWarning: String? = nil
}

struct ComposeMailSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var compose: ComposeCoordinator

    init(viewModel: AppViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._compose = ObservedObject(wrappedValue: viewModel.compose)
    }

    private var requiresExplicitSenderSelection: Bool {
        !viewModel.accountEmails.isEmpty &&
        compose.draft.fromEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        compose.draft.missingOriginAccountWarning != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Header
            HStack(spacing: 10) {
                Label(compose.draft.mode.rawValue, systemImage: "square.and.pencil")
                    .font(.headline)
                if !compose.draft.fromEmail.isEmpty {
                    Text(compose.draft.fromEmail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .lineLimit(1)
                }
                Spacer()
                Button("取消") {
                    compose.close()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(compose.draft.isSending)

                Button("存草稿") {
                    compose.saveDraft()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(compose.draft.isSending)

                Button {
                    compose.sendMail()
                } label: {
                    if compose.draft.isSending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("发送中...")
                        }
                    } else {
                        Label("发送", systemImage: "paperplane.fill")
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    compose.draft.isSending ||
                    requiresExplicitSenderSelection ||
                    compose.draft.toText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            if let warning = compose.draft.missingOriginAccountWarning,
               compose.draft.fromEmail.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
                Divider()
            }

            // Recipient & Subject Fields
            VStack(spacing: 0) {
                if !viewModel.accountEmails.isEmpty {
                    composeRow(label: "发件人") {
                        Picker("", selection: $compose.draft.fromEmail) {
                            Text(compose.draft.missingOriginAccountWarning == nil ? "默认账号" : "请选择发件账号...").tag("")
                            ForEach(viewModel.accountEmails, id: \.self) { email in
                                Text(email).tag(email)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                        .disabled(compose.draft.isSending)
                        Spacer()
                    }
                    Divider().padding(.leading, 72)
                }

                composeRow(label: "收件人") {
                    TextField("多个邮箱请用逗号分隔", text: $compose.draft.toText)
                        .textFieldStyle(.plain)
                        .disabled(compose.draft.isSending)
                }
                Divider().padding(.leading, 72)

                composeRow(label: "抄送") {
                    TextField("可选，多个邮箱请用逗号分隔", text: $compose.draft.ccText)
                        .textFieldStyle(.plain)
                        .disabled(compose.draft.isSending)
                }
                Divider().padding(.leading, 72)

                composeRow(label: "主题") {
                    TextField("输入邮件主题", text: $compose.draft.subject)
                        .textFieldStyle(.plain)
                        .font(.callout.weight(.medium))
                        .disabled(compose.draft.isSending)
                }
            }
            .background(.background)

            Divider()

            // Attachments Strip (if any)
            if !compose.draft.attachmentURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(compose.draft.attachmentURLs, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: "paperclip")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .lineLimit(1)
                                Button {
                                    compose.removeAttachment(url)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .disabled(compose.draft.isSending)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(.bar.opacity(0.4))
                Divider()
            }

            // Body Editor (track revisions on user edit so AI polish never overwrites manual typing)
            TextEditor(
                text: Binding(
                    get: { compose.draft.body },
                    set: { newValue in
                        if compose.draft.body != newValue {
                            compose.draft.body = newValue
                            compose.draft.revision += 1
                        }
                    }
                )
            )
            .font(.body)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(compose.draft.isSending)

            // AI Polish Preview Panel (explicit adopt/discard so AI never clobbers user's draft)
            if let preview = compose.draft.pendingAIPolish, !preview.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label(
                            compose.draft.isAIPolishing ? "AI 润色预览（生成中...）" : "AI 润色建议（原稿已保留）",
                            systemImage: "sparkles"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                        Spacer()
                        if compose.draft.isAIPolishing {
                            Button("停止") {
                                compose.cancelAIPolish()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        } else {
                            Button("放弃") {
                                compose.discardPendingAIPolish()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button("采纳替换正文") {
                                compose.applyPendingAIPolish()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                    }
                    ScrollView {
                        Text(preview)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 115)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.purple.opacity(0.06))
            }

            Divider()

            // Bottom Action Bar
            HStack(spacing: 10) {
                Button {
                    compose.pickAttachments()
                } label: {
                    Label("添加附件", systemImage: "paperclip")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(compose.draft.isSending)

                Button {
                    compose.polishBodyWithAI()
                } label: {
                    if compose.draft.isAIPolishing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("AI 润色中...")
                        }
                    } else {
                        Label("AI 润色 / 补全", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(compose.draft.isAIPolishing || compose.draft.isSending)

                Spacer()

                Text("⌘↩ 提交给系统 Mail.app 发送")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .frame(width: 680, height: 580)
    }

    private func composeRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            content()
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}
