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

    private var requiresExplicitSenderSelection: Bool {
        !viewModel.accountEmails.isEmpty &&
        viewModel.composeDraft.fromEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        viewModel.composeDraft.missingOriginAccountWarning != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Header
            HStack(spacing: 10) {
                Label(viewModel.composeDraft.mode.rawValue, systemImage: "square.and.pencil")
                    .font(.headline)
                if !viewModel.composeDraft.fromEmail.isEmpty {
                    Text(viewModel.composeDraft.fromEmail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .lineLimit(1)
                }
                Spacer()
                Button("取消") {
                    viewModel.closeComposeSheet()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.composeDraft.isSending)

                Button("存草稿") {
                    viewModel.saveComposedDraft()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.composeDraft.isSending)

                Button {
                    viewModel.sendComposedMail()
                } label: {
                    if viewModel.composeDraft.isSending {
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
                    viewModel.composeDraft.isSending ||
                    requiresExplicitSenderSelection ||
                    viewModel.composeDraft.toText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            if let warning = viewModel.composeDraft.missingOriginAccountWarning,
               viewModel.composeDraft.fromEmail.isEmpty {
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
                        Picker("", selection: $viewModel.composeDraft.fromEmail) {
                            Text(viewModel.composeDraft.missingOriginAccountWarning == nil ? "默认账号" : "请选择发件账号...").tag("")
                            ForEach(viewModel.accountEmails, id: \.self) { email in
                                Text(email).tag(email)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                        .disabled(viewModel.composeDraft.isSending)
                        Spacer()
                    }
                    Divider().padding(.leading, 72)
                }

                composeRow(label: "收件人") {
                    TextField("多个邮箱请用逗号分隔", text: $viewModel.composeDraft.toText)
                        .textFieldStyle(.plain)
                        .disabled(viewModel.composeDraft.isSending)
                }
                Divider().padding(.leading, 72)

                composeRow(label: "抄送") {
                    TextField("可选，多个邮箱请用逗号分隔", text: $viewModel.composeDraft.ccText)
                        .textFieldStyle(.plain)
                        .disabled(viewModel.composeDraft.isSending)
                }
                Divider().padding(.leading, 72)

                composeRow(label: "主题") {
                    TextField("输入邮件主题", text: $viewModel.composeDraft.subject)
                        .textFieldStyle(.plain)
                        .font(.callout.weight(.medium))
                        .disabled(viewModel.composeDraft.isSending)
                }
            }
            .background(.background)

            Divider()

            // Attachments Strip (if any)
            if !viewModel.composeDraft.attachmentURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.composeDraft.attachmentURLs, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: "paperclip")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .lineLimit(1)
                                Button {
                                    viewModel.removeComposeAttachment(url)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .disabled(viewModel.composeDraft.isSending)
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
                    get: { viewModel.composeDraft.body },
                    set: { newValue in
                        if viewModel.composeDraft.body != newValue {
                            viewModel.composeDraft.body = newValue
                            viewModel.composeDraft.revision += 1
                        }
                    }
                )
            )
            .font(.body)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(viewModel.composeDraft.isSending)

            // AI Polish Preview Panel (explicit adopt/discard so AI never clobbers user's draft)
            if let preview = viewModel.composeDraft.pendingAIPolish, !preview.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label(
                            viewModel.composeDraft.isAIPolishing ? "AI 润色预览（生成中...）" : "AI 润色建议（原稿已保留）",
                            systemImage: "sparkles"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                        Spacer()
                        if viewModel.composeDraft.isAIPolishing {
                            Button("停止") {
                                viewModel.cancelComposeAIPolish()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        } else {
                            Button("放弃") {
                                viewModel.discardPendingAIPolish()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button("采纳替换正文") {
                                viewModel.applyPendingAIPolish()
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
                    viewModel.pickComposeAttachments()
                } label: {
                    Label("添加附件", systemImage: "paperclip")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.composeDraft.isSending)

                Button {
                    viewModel.polishComposeBodyWithAI()
                } label: {
                    if viewModel.composeDraft.isAIPolishing {
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
                .disabled(viewModel.composeDraft.isAIPolishing || viewModel.composeDraft.isSending)

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
