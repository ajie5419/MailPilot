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
    var mode: ComposeMode = .new
    var fromEmail: String = ""
    var toText: String = ""
    var ccText: String = ""
    var subject: String = ""
    var body: String = ""
    var attachmentURLs: [URL] = []
    var isSending: Bool = false
    var isAIPolishing: Bool = false
}

struct ComposeMailSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Top Header
            HStack(spacing: 10) {
                Label(viewModel.composeDraft.mode.rawValue, systemImage: "square.and.pencil")
                    .font(.headline)
                Spacer()
                Button("取消") {
                    viewModel.showComposeSheet = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.small)

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
                    viewModel.composeDraft.toText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Recipient & Subject Fields
            VStack(spacing: 0) {
                if !viewModel.accountEmails.isEmpty {
                    composeRow(label: "发件人") {
                        Picker("", selection: $viewModel.composeDraft.fromEmail) {
                            Text("默认账号").tag("")
                            ForEach(viewModel.accountEmails, id: \.self) { email in
                                Text(email).tag(email)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                        Spacer()
                    }
                    Divider().padding(.leading, 72)
                }

                composeRow(label: "收件人") {
                    TextField("多个邮箱请用逗号分隔", text: $viewModel.composeDraft.toText)
                        .textFieldStyle(.plain)
                }
                Divider().padding(.leading, 72)

                composeRow(label: "抄送") {
                    TextField("可选，多个邮箱请用逗号分隔", text: $viewModel.composeDraft.ccText)
                        .textFieldStyle(.plain)
                }
                Divider().padding(.leading, 72)

                composeRow(label: "主题") {
                    TextField("输入邮件主题", text: $viewModel.composeDraft.subject)
                        .textFieldStyle(.plain)
                        .font(.callout.weight(.medium))
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

            // Body Editor
            TextEditor(text: $viewModel.composeDraft.body)
                .font(.body)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                .disabled(viewModel.composeDraft.isAIPolishing)

                Spacer()

                Text("⌘↩ 直接发送 · 由系统 Mail.app 后台安全投递")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .frame(width: 660, height: 540)
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
