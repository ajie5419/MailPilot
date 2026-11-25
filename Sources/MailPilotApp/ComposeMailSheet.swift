import AppKit
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI
import UniformTypeIdentifiers

enum ComposeMode: String {
    case new = "写新邮件"
    case reply = "回复邮件"
    case replyAll = "全部回复"
    case forward = "转发邮件"
}

enum ComposeRecipientField: Hashable {
    case to
    case cc
    case bcc
}

enum ComposeAttachmentStatus: Equatable {
    case preparing(progress: Double, detail: String)
    case ready(sizeBytes: Int64)
    case attaching
    case attached
    case failed(reason: String)

    var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isAttaching: Bool {
        if case .attaching = self { return true }
        return false
    }

    var isAttached: Bool {
        if case .attached = self { return true }
        return false
    }

    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

struct ComposeAttachmentItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var filename: String
    var status: ComposeAttachmentStatus
    var sizeBytes: Int64?

    init(
        id: UUID = UUID(),
        url: URL,
        filename: String? = nil,
        status: ComposeAttachmentStatus = .preparing(progress: 0.05, detail: "准备中…"),
        sizeBytes: Int64? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename ?? url.lastPathComponent
        self.status = status
        self.sizeBytes = sizeBytes
    }

    var fileExtension: String {
        url.pathExtension.lowercased()
    }

    var formattedSize: String? {
        guard let bytes = sizeBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ComposeFeedbackBanner: Equatable {
    enum Kind: Equatable {
        case progress(Double?)
        case success
        case warning
        case error
        case info
    }

    let id: UUID
    let kind: Kind
    let message: String
    let detail: String?

    init(id: UUID = UUID(), kind: Kind, message: String, detail: String? = nil) {
        self.id = id
        self.kind = kind
        self.message = message
        self.detail = detail
    }
}

struct ComposeDraftState {
    static let recommendedMaxTotalBytes: Int64 = 25 * 1024 * 1024

    var id: UUID = UUID()
    var revision: Int = 0
    var mode: ComposeMode = .new
    var fromEmail: String = ""
    var toText: String = ""
    var ccText: String = ""
    var bccText: String = ""
    var showBCCField: Bool = false
    var subject: String = ""
    var body: String = ""
    var appliedSignature: String? = nil
    var initialToText: String = ""
    var initialCCText: String = ""
    var initialSubject: String = ""
    var initialBody: String = ""
    var attachments: [ComposeAttachmentItem] = []
    var isSending: Bool = false
    var sendPhaseLabel: String? = nil
    var isAIPolishing: Bool = false
    var pendingAIPolish: String? = nil
    var polishBaseRevision: Int? = nil
    var missingOriginAccountWarning: String? = nil
    var feedbackBanner: ComposeFeedbackBanner? = nil
    var showDiscardConfirmation: Bool = false

    var hasUnsavedChanges: Bool {
        if !attachments.isEmpty { return true }
        if !bccText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if toText != initialToText || ccText != initialCCText || subject != initialSubject { return true }
        if body != initialBody { return true }
        return false
    }

    var isPreparingAttachments: Bool {
        attachments.contains { $0.status.isPreparing }
    }

    var failedAttachmentsCount: Int {
        attachments.filter { $0.status.failureReason != nil }.count
    }

    var readyAttachmentsCount: Int {
        attachments.filter { $0.status.isReady || $0.status.isAttaching || $0.status.isAttached }.count
    }

    var totalAttachmentBytes: Int64 {
        attachments.reduce(0) { sum, item in
            if item.status.failureReason != nil { return sum }
            return sum + (item.sizeBytes ?? 0)
        }
    }

    var formattedTotalAttachmentSize: String {
        ByteCountFormatter.string(fromByteCount: totalAttachmentBytes, countStyle: .file)
    }

    var exceedsRecommendedAttachmentLimit: Bool {
        totalAttachmentBytes > Self.recommendedMaxTotalBytes
    }
}

private final class ComposeDropTargetState: ObservableObject {
    @Published var isTargeted = false
}

struct ComposeMailSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var compose: ComposeCoordinator
    @StateObject private var dropState = ComposeDropTargetState()
    @FocusState private var focusedRecipientField: ComposeRecipientField?

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
        ZStack {
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
                        compose.requestClose()
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
                    .disabled(compose.draft.isSending || compose.draft.isPreparingAttachments)

                    Button {
                        compose.sendMail()
                    } label: {
                        if compose.draft.isSending {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(compose.draft.sendPhaseLabel ?? "发送中...")
                            }
                        } else if compose.draft.isPreparingAttachments {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("准备附件中...")
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
                        compose.draft.isPreparingAttachments ||
                        requiresExplicitSenderSelection ||
                        compose.draft.toText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)

                Divider()

                // Discard Confirmation Strip (prevents accidental loss of unsaved drafts)
                if compose.draft.showDiscardConfirmation {
                    discardConfirmationBar
                    Divider()
                }

                // Inline Feedback Banner (always visible inside the modal sheet)
                if let banner = compose.draft.feedbackBanner {
                    feedbackBannerView(banner)
                    Divider()
                }

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
                            Picker(
                                "",
                                selection: Binding(
                                    get: { compose.draft.fromEmail },
                                    set: { compose.updateSenderEmail($0) }
                                )
                            ) {
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
                        TextField("输入姓名或邮箱，多个请用逗号分隔", text: $compose.draft.toText)
                            .textFieldStyle(.plain)
                            .focused($focusedRecipientField, equals: .to)
                            .disabled(compose.draft.isSending)
                            .onChange(of: compose.draft.toText) { _, newValue in
                                if focusedRecipientField == .to {
                                    compose.updateRecipientSuggestions(for: .to, text: newValue)
                                }
                            }
                            .onSubmit {
                                compose.acceptFirstContactSuggestion(for: .to)
                            }
                    }
                    if compose.activeRecipientField == .to && !compose.contactSuggestions.isEmpty {
                        contactSuggestionsStrip(for: .to)
                    }
                    Divider().padding(.leading, 72)

                    composeRow(label: "抄送") {
                        TextField("可选，多个邮箱请用逗号分隔", text: $compose.draft.ccText)
                            .textFieldStyle(.plain)
                            .focused($focusedRecipientField, equals: .cc)
                            .disabled(compose.draft.isSending)
                            .onChange(of: compose.draft.ccText) { _, newValue in
                                if focusedRecipientField == .cc {
                                    compose.updateRecipientSuggestions(for: .cc, text: newValue)
                                }
                            }
                            .onSubmit {
                                compose.acceptFirstContactSuggestion(for: .cc)
                            }

                        if !compose.draft.showBCCField && compose.draft.bccText.isEmpty {
                            Button {
                                compose.draft.showBCCField = true
                                focusedRecipientField = .bcc
                            } label: {
                                Text("+ 密送")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(compose.draft.isSending)
                            .help("添加密送（BCC）收件人")
                        }
                    }
                    if compose.activeRecipientField == .cc && !compose.contactSuggestions.isEmpty {
                        contactSuggestionsStrip(for: .cc)
                    }

                    if compose.draft.showBCCField || !compose.draft.bccText.isEmpty {
                        Divider().padding(.leading, 72)
                        composeRow(label: "密送") {
                            TextField("可选，收件人彼此不可见", text: $compose.draft.bccText)
                                .textFieldStyle(.plain)
                                .focused($focusedRecipientField, equals: .bcc)
                                .disabled(compose.draft.isSending)
                                .onChange(of: compose.draft.bccText) { _, newValue in
                                    if focusedRecipientField == .bcc {
                                        compose.updateRecipientSuggestions(for: .bcc, text: newValue)
                                    }
                                }
                                .onSubmit {
                                    compose.acceptFirstContactSuggestion(for: .bcc)
                                }
                        }
                        if compose.activeRecipientField == .bcc && !compose.contactSuggestions.isEmpty {
                            contactSuggestionsStrip(for: .bcc)
                        }
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
                .onChange(of: focusedRecipientField) { _, newField in
                    if let newField {
                        let text: String
                        switch newField {
                        case .to: text = compose.draft.toText
                        case .cc: text = compose.draft.ccText
                        case .bcc: text = compose.draft.bccText
                        }
                        compose.updateRecipientSuggestions(for: newField, text: text)
                    } else {
                        compose.clearContactSuggestions()
                    }
                }

                Divider()

                // Attachments Section (with live progress, size, status, retry & remove)
                if !compose.draft.attachments.isEmpty {
                    attachmentsSection
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
                        if compose.draft.attachments.isEmpty {
                            Label("添加附件", systemImage: "paperclip")
                        } else {
                            Label("添加附件（\(compose.draft.attachments.count)）", systemImage: "paperclip")
                        }
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

                    Text("支持联系人联想与拖拽附件 · ⌘↩ 发送")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }

            if dropState.isTargeted && !compose.draft.isSending {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    )
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(Color.accentColor)
                            Text("松开以添加为邮件附件")
                                .font(.headline)
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    )
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 700, height: 610)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropState.isTargeted) { providers in
            guard !compose.draft.isSending else { return false }
            return compose.handleDroppedProviders(providers)
        }
    }

    private var discardConfirmationBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("当前草稿尚未发送，是否保存到草稿箱？")
                .font(.caption.weight(.medium))
            Spacer()
            Button("继续编辑") {
                compose.draft.showDiscardConfirmation = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("放弃草稿", role: .destructive) {
                compose.forceClose()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("存为草稿") {
                compose.draft.showDiscardConfirmation = false
                compose.saveDraft()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(compose.draft.isPreparingAttachments)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.11))
    }

    private func contactSuggestionsStrip(for field: ComposeRecipientField) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(compose.contactSuggestions) { contact in
                    Button {
                        compose.selectContactSuggestion(contact, for: field)
                    } label: {
                        HStack(spacing: 4) {
                            if !contact.name.isEmpty && contact.name.caseInsensitiveCompare(contact.address) != .orderedSame {
                                Text(contact.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(contact.address)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(contact.address)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 0.7)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 78)
            .padding(.trailing, 16)
            .padding(.vertical, 6)
        }
        .background(Color.accentColor.opacity(0.05))
    }

    private func feedbackBannerView(_ banner: ComposeFeedbackBanner) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                switch banner.kind {
                case .progress:
                    ProgressView()
                        .controlSize(.small)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .warning:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .error:
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                case .info:
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(banner.message)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail = banner.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if case .progress = banner.kind {
                    EmptyView()
                } else {
                    Button {
                        compose.dismissBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("关闭提示")
                }
            }

            if case .progress(let fraction) = banner.kind {
                if let fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(bannerBackgroundColor(for: banner.kind))
    }

    private func bannerBackgroundColor(for kind: ComposeFeedbackBanner.Kind) -> Color {
        switch kind {
        case .progress: return Color.accentColor.opacity(0.08)
        case .success: return Color.green.opacity(0.10)
        case .warning: return Color.orange.opacity(0.11)
        case .error: return Color.red.opacity(0.11)
        case .info: return Color.accentColor.opacity(0.07)
        }
    }

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label {
                    Text("附件（\(compose.draft.readyAttachmentsCount)/\(compose.draft.attachments.count)）")
                        .font(.caption.weight(.medium))
                } icon: {
                    Image(systemName: "paperclip")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                if compose.draft.totalAttachmentBytes > 0 {
                    Text("· \(compose.draft.formattedTotalAttachmentSize)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if compose.draft.exceedsRecommendedAttachmentLimit {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("超过 25 MB，部分邮箱可能拒收")
                            .font(.caption2)
                    }
                    .foregroundStyle(.orange)
                }

                if compose.draft.failedAttachmentsCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                        Text("\(compose.draft.failedAttachmentsCount) 个失败")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.red)
                }

                Spacer()

                if !compose.draft.isSending {
                    Button {
                        compose.pickAttachments()
                    } label: {
                        Label("继续添加", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(compose.draft.attachments) { item in
                        attachmentChip(item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .background(.bar.opacity(0.4))
    }

    private func attachmentChip(_ item: ComposeAttachmentItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                attachmentLeadingIcon(for: item)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.filename)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)

                    attachmentStatusSubtitle(for: item)
                }

                if item.status.failureReason != nil && !compose.draft.isSending {
                    Button {
                        compose.retryAttachment(item.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("重新读取此附件")
                }

                Button {
                    compose.removeAttachment(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(compose.draft.isSending)
                .help(item.status.isPreparing ? "取消添加" : "移除附件")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)

            if case .preparing(let progress, _) = item.status {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: max(4, proxy.size.width * min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 2.5)
            }
        }
        .background(chipBackgroundColor(for: item.status), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(chipBorderColor(for: item.status), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(attachmentTooltip(for: item))
    }

    @ViewBuilder
    private func attachmentLeadingIcon(for item: ComposeAttachmentItem) -> some View {
        switch item.status {
        case .preparing, .attaching:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 18, height: 18)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.red)
                .frame(width: 18, height: 18)
        case .ready, .attached:
            Image(systemName: iconForExtension(item.fileExtension))
                .font(.system(size: 13))
                .foregroundStyle(colorForExtension(item.fileExtension))
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private func attachmentStatusSubtitle(for item: ComposeAttachmentItem) -> some View {
        switch item.status {
        case .preparing(let progress, let detail):
            Text("\(detail) \(Int((progress * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
        case .ready:
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text(item.formattedSize ?? "已就绪")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .attaching:
            Text("正在附加到邮件…")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
        case .attached:
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text("已附加")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        case .failed(let reason):
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
        }
    }

    private func chipBackgroundColor(for status: ComposeAttachmentStatus) -> Color {
        switch status {
        case .failed:
            return Color.red.opacity(0.08)
        case .preparing, .attaching:
            return Color.accentColor.opacity(0.06)
        case .ready, .attached:
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    private func chipBorderColor(for status: ComposeAttachmentStatus) -> Color {
        switch status {
        case .failed:
            return Color.red.opacity(0.45)
        case .preparing, .attaching:
            return Color.accentColor.opacity(0.35)
        case .ready, .attached:
            return Color.primary.opacity(0.12)
        }
    }

    private func attachmentTooltip(for item: ComposeAttachmentItem) -> String {
        switch item.status {
        case .preparing(let progress, let detail):
            return "\(item.filename) · \(detail) \(Int((progress * 100).rounded()))%"
        case .ready:
            let size = item.formattedSize ?? "未知大小"
            return "\(item.filename)（\(size)）· 已校验就绪\n\(item.url.path)"
        case .attaching:
            return "\(item.filename) · 正在交给系统 Mail.app 附加…"
        case .attached:
            return "\(item.filename) · 已成功附加"
        case .failed(let reason):
            return "\(item.filename) · 失败：\(reason)\n点击刷新图标重试或移除"
        }
    }

    private func iconForExtension(_ ext: String) -> String {
        switch ext {
        case "pdf": return "doc.richtext.fill"
        case "doc", "docx", "pages": return "doc.text.fill"
        case "xls", "xlsx", "csv", "numbers": return "tablecells.fill"
        case "ppt", "pptx", "key": return "play.rectangle.fill"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return "photo.fill"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox.fill"
        default: return "doc.fill"
        }
    }

    private func colorForExtension(_ ext: String) -> Color {
        switch ext {
        case "pdf": return .red
        case "doc", "docx", "pages": return .blue
        case "xls", "xlsx", "csv", "numbers": return .green
        case "ppt", "pptx", "key": return .orange
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return .purple
        case "zip", "rar", "7z", "tar", "gz": return .brown
        default: return .secondary
        }
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
