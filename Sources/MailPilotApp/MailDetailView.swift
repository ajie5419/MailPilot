import AppKit
import CryptoKit
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI
import WebKit

struct MailDetailView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var ai: AIAssistantController
    @StateObject private var recipientExpandState = RecipientExpandState()
    @StateObject private var inlineCardHeightState = InlineCardHeightState()

    init(viewModel: AppViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._ai = ObservedObject(wrappedValue: viewModel.ai)
    }

    var body: some View {
        if let message = viewModel.selectedMessage {
            let loadedBody = viewModel.currentLoadedBody
            let activeHTML: String? = (!viewModel.isLoadingBody && !viewModel.preferPlainText)
                ? loadedBody?.rawHTML.flatMap { $0.isEmpty ? nil : $0 }
                : nil
            let shouldBlockRemote = viewModel.blockRemoteImages && !viewModel.allowedRemoteContentMessageIDs.contains(message.id)
            let hasBlockedRemote = activeHTML != nil && shouldBlockRemote && viewModel.selectedBodyHasRemoteResources

            VStack(spacing: 0) {
                headerBar(for: message, hasBlockedRemote: hasBlockedRemote)
                Divider()
                    .opacity(0.75)

                if ai.showInlineSummary {
                    inlineSummaryCard
                }

                if let loadedBody, let code = loadedBody.verificationCode {
                    verificationBanner(code: code)
                    Divider()
                        .opacity(0.6)
                }

                if let loadedBody, !loadedBody.attachments.isEmpty {
                    attachmentsBar(loadedBody.attachments)
                    Divider()
                        .opacity(0.6)
                }

                // Keep a single warm WKWebView mounted across email switches & plain-text toggles
                // so WebKit's WebContent subprocess is never torn down and cold-booted per click.
                ZStack {
                    HTMLMailWebView(
                        html: activeHTML,
                        blockRemoteContent: shouldBlockRemote,
                        releaseDOMWhenNil: !viewModel.isLoadingBody && loadedBody != nil
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(activeHTML != nil ? 1 : 0)
                    .allowsHitTesting(activeHTML != nil)

                    if viewModel.isLoadingBody || loadedBody == nil {
                        ProgressView("正在解析本地 .emlx 正文...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.background)
                    } else if activeHTML == nil {
                        ScrollView {
                            Text(viewModel.selectedPlainAttributedText)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20)
                        }
                        .background(.background)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "选择一封邮件",
                systemImage: "envelope.open",
                description: Text("收信与推送由 macOS 原生 Mail.app 驱动，选择邮件即可阅读或用 AI 总结。")
            )
        }
    }

    private func headerBar(for message: MailMessageSummary, hasBlockedRemote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(message.subject)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                // Clean borderless SF Symbols action cluster
                HStack(spacing: 2) {
                    DetailHeaderIconButton(systemImage: "arrowshape.turn.up.left", helpText: "回复（⌘R）") {
                        viewModel.openComposeReply(for: message)
                    }
                    DetailHeaderIconButton(systemImage: "arrowshape.turn.up.left.2", helpText: "全部回复（⌥⌘R）") {
                        viewModel.openComposeReplyAll(for: message)
                    }
                    DetailHeaderIconButton(systemImage: "arrowshape.turn.up.right", helpText: "转发（⇧⌘F）") {
                        viewModel.openComposeForward(for: message)
                    }

                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 4)

                    DetailHeaderIconButton(systemImage: "archivebox", helpText: "归档（⌃⌘A）") {
                        viewModel.archiveMessage(message)
                    }
                    DetailHeaderIconButton(systemImage: "trash", helpText: "删除（⌘⌫）", isDestructive: true) {
                        viewModel.deleteMessage(message)
                    }

                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 4)

                    Menu {
                        if viewModel.currentLoadedBody?.rawHTML != nil {
                            Button {
                                viewModel.preferPlainText.toggle()
                            } label: {
                                Label(
                                    viewModel.preferPlainText ? "切换为 HTML 富文本" : "切换为纯文本",
                                    systemImage: viewModel.preferPlainText ? "doc.richtext" : "doc.plaintext"
                                )
                            }
                        }
                        Button {
                            viewModel.toggleReadStatus(for: message)
                        } label: {
                            Label(
                                message.isRead ? "标记为未读" : "标记为已读",
                                systemImage: message.isRead ? "envelope.badge" : "envelope.open"
                            )
                        }
                        Button {
                            viewModel.toggleFlaggedStatus(for: message)
                        } label: {
                            Label(
                                message.isFlagged ? "取消旗标" : "添加旗标",
                                systemImage: message.isFlagged ? "flag.slash" : "flag"
                            )
                        }
                        Divider()
                        Button {
                            viewModel.openInNativeMail(message)
                        } label: {
                            Label("在系统 Mail.app 中打开", systemImage: "arrow.up.forward.app")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 24)
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("更多操作（纯文本切换 / 标未读 / 旗标）")
                }
            }

            HStack(spacing: 10) {
                SenderAvatarView(name: message.displaySender, email: message.senderAddress, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.displaySender)
                        .font(.subheadline.weight(.medium))
                    Text(message.senderAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(message.dateReceived.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let acctName = viewModel.accountDisplayName(for: message.accountID) {
                        HStack(spacing: 5) {
                            AccountLogoView(
                                accountID: message.accountID,
                                email: viewModel.accountEmail(for: message.accountID),
                                customIconPath: viewModel.accountCustomIconPath(for: message.accountID),
                                presetLogoID: viewModel.accountPresetLogoID(for: message.accountID),
                                sfSymbolName: viewModel.accountSFSymbolName(for: message.accountID),
                                fallbackColor: viewModel.accountBadgeColor(for: message.accountID),
                                size: 13
                            )
                            Text("\(acctName) · \(message.mailboxName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .help(viewModel.accountEmail(for: message.accountID) ?? acctName)
                    }
                }
            }

            if !viewModel.selectedMessageRecipients.isEmpty {
                recipientsSummaryBar(viewModel.selectedMessageRecipients)
            }

            compactActionStrip(for: message, hasBlockedRemote: hasBlockedRemote)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(.background)
        .onChange(of: message.id) { _, _ in
            recipientExpandState.isExpanded = false
        }
    }

    private func recipientsSummaryBar(_ recipients: [MailRecipientInfo]) -> some View {
        let toList = recipients.filter { !$0.isCC }
        let ccList = recipients.filter { $0.isCC }
        let totalCount = recipients.count

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !toList.isEmpty {
                    Text("收件人：")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                    Text(
                        recipientExpandState.isExpanded
                            ? toList.map(\.formattedDisplay).joined(separator: "、")
                            : toList.prefix(3).map(\.formattedDisplay).joined(separator: "、")
                                + (toList.count > 3 ? " 等 \(toList.count) 人" : "")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(recipientExpandState.isExpanded ? nil : 1)
                    .textSelection(.enabled)
                }

                if !recipientExpandState.isExpanded && !ccList.isEmpty {
                    Text("· 抄送 \(ccList.count) 人")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }

                Spacer(minLength: 4)

                if totalCount > 1 || !ccList.isEmpty {
                    Button {
                        recipientExpandState.isExpanded.toggle()
                    } label: {
                        HStack(spacing: 2) {
                            Text(recipientExpandState.isExpanded ? "收起" : "详情")
                            Image(systemName: recipientExpandState.isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if recipientExpandState.isExpanded && !ccList.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("抄送：")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                    Text(ccList.map(\.formattedDisplay).joined(separator: "、"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 40)
        .padding(.top, 1)
    }

    private func verificationBanner(code: String) -> some View {
        HStack {
            Image(systemName: "key.fill")
                .foregroundStyle(.blue)
            Text("识别到验证码：")
                .font(.callout)
            Text(code)
                .font(.callout.monospaced().bold())
                .textSelection(.enabled)
            Spacer()
            Button("一键复制") {
                viewModel.copyToClipboard(code, label: "已复制验证码 \(code)")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }

    private func attachmentsBar(_ attachments: [MailAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    Button {
                        viewModel.openAttachment(att)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: iconForAttachment(att))
                                .font(.system(size: 13))
                                .foregroundStyle(colorForAttachment(att))
                                .frame(width: 22, height: 22)
                                .background(colorForAttachment(att).opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                            Text(att.filename)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("· \(att.formattedSize)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.6)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("\(att.filename)（\(att.formattedSize)）· 点击打开，右键可另存为")
                    .contextMenu {
                        if AttachmentTextExtractor.isSupportedForAI(att) {
                            Button {
                                ai.analyzeAttachment(att)
                            } label: {
                                Label("用 AI 解读此附件", systemImage: "sparkles")
                            }
                            Divider()
                        }
                        Button("打开预览") {
                            viewModel.openAttachment(att)
                        }
                        Button("另存为...") {
                            viewModel.saveAttachmentAs(att)
                        }
                        Button("在访达中显示") {
                            viewModel.revealAttachmentInFinder(att)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
        .background(.background)
    }

    private func iconForAttachment(_ att: MailAttachment) -> String {
        switch att.fileExtension {
        case "pdf": return "doc.richtext.fill"
        case "doc", "docx", "pages": return "doc.text.fill"
        case "xls", "xlsx", "csv", "numbers": return "tablecells.fill"
        case "ppt", "pptx", "key": return "play.rectangle.fill"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return "photo.fill"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox.fill"
        default: return "doc.fill"
        }
    }

    private func colorForAttachment(_ att: MailAttachment) -> Color {
        switch att.fileExtension {
        case "pdf": return .red
        case "doc", "docx", "pages": return .blue
        case "xls", "xlsx", "csv", "numbers": return .green
        case "ppt", "pptx", "key": return .orange
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return .purple
        case "zip", "rar", "7z", "tar", "gz": return .brown
        default: return .secondary
        }
    }

    private func compactActionStrip(for message: MailMessageSummary, hasBlockedRemote: Bool) -> some View {
        let isSummarizing = ai.isInlineSummarizing && ai.inlineCardMode == .summary
        let isTranslating = ai.isInlineSummarizing && ai.inlineCardMode == .translation
        let isShowingTranslation = ai.showInlineSummary && ai.inlineCardMode == .translation

        return HStack(spacing: 6) {
            if isSummarizing {
                Button {
                    ai.stopInlineSummary()
                } label: {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("停止总结")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("停止正在生成的摘要")
            } else {
                Button {
                    ai.summarizeSelectedEmailInline()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("总结邮件")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoadingBody)
                .opacity(viewModel.isLoadingBody ? 0.5 : 1)
                .help("使用 AI 生成当前邮件摘要")
            }

            if isTranslating {
                Button {
                    ai.stopInlineSummary()
                } label: {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("停止翻译")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("停止正在进行的翻译")
            } else {
                Button {
                    ai.translateSelectedEmailInline()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 10.5, weight: .medium))
                        Text("翻译邮件")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(isShowingTranslation ? Color.accentColor : .primary.opacity(0.84))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(
                        isShowingTranslation ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoadingBody)
                .opacity(viewModel.isLoadingBody ? 0.5 : 1)
                .help("将当前邮件智能翻译（外文译为中文，中文译为英文）")
            }

            Spacer(minLength: 8)

            if hasBlockedRemote {
                HStack(spacing: 5) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text("已拦截远程图")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("显示") {
                        viewModel.allowedRemoteContentMessageIDs.insert(message.id)
                    }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .help("仅对当前邮件加载远程图片")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.primary.opacity(0.045), in: Capsule())
            } else {
                Button {
                    viewModel.settingsTab = .ai
                    viewModel.showSettings = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.system(size: 10))
                        Text("\(ai.activeAIBadge) · \(ai.activeModelDisplayName)")
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("点击配置模型或订阅账号")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.032), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var inlineSummaryCard: some View {
        let isTranslation = ai.inlineCardMode == .translation

        return VStack(alignment: .leading, spacing: 0) {
            // Card Header Strip
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: isTranslation ? "globe" : "sparkles")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 21, height: 21)

                Text(isTranslation ? "AI 翻译" : "AI 摘要")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                if isTranslation {
                    Menu {
                        ForEach(TranslationTargetLanguage.allCases) { lang in
                            Button {
                                ai.translateSelectedEmailInline(target: lang)
                            } label: {
                                if ai.translationTarget == lang {
                                    Label(lang.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(lang.rawValue)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(ai.translationTarget.rawValue)
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("切换目标翻译语言")
                }

                if ai.isInlineSummarizing {
                    ProgressView()
                        .controlSize(.mini)
                    Button {
                        ai.stopInlineSummary()
                    } label: {
                        Label("停止", systemImage: "stop.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(isTranslation ? "停止翻译" : "停止生成摘要")
                }

                Spacer()

                if !ai.inlineSummaryText.isEmpty && !ai.isInlineSummarizing {
                    Button {
                        if isTranslation {
                            ai.translateSelectedEmailInline(forceRefresh: true)
                        } else {
                            ai.summarizeSelectedEmailInline(forceRefresh: true)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(isTranslation ? "重新翻译" : "重新生成摘要")
                    .accessibilityLabel(isTranslation ? "重新翻译" : "重新生成摘要")

                    Button {
                        viewModel.copyToClipboard(
                            ai.inlineSummaryText,
                            label: isTranslation ? "已复制译文" : "已复制摘要"
                        )
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(isTranslation ? "复制译文" : "复制摘要")
                    .accessibilityLabel(isTranslation ? "复制译文" : "复制摘要")
                }

                Button {
                    ai.closeInlineCard()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isTranslation ? "收起译文" : "收起摘要")
                .accessibilityLabel(isTranslation ? "收起译文" : "收起摘要")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.045), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )

            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)

            // Card Body: stable ScrollView bounded by measured content height (max 240pt)
            // so multi-line outputs never push the email body off-screen or swap containers mid-stream.
            ScrollView {
                inlineCardBodyContent(isTranslation: isTranslation)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear {
                                    inlineCardHeightState.update(proxy.size.height)
                                }
                                .onChange(of: proxy.size.height) { _, newHeight in
                                    inlineCardHeightState.update(newHeight)
                                }
                        }
                    )
            }
            .frame(height: inlineCardHeightState.clampedHeight(maxHeight: isTranslation ? 240 : 210))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.primary.opacity(0.015), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.11), Color.primary.opacity(0.07)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        )
        .shadow(color: Color.black.opacity(0.055), radius: 10, x: 0, y: 3)
        .shadow(color: Color.black.opacity(0.025), radius: 2, x: 0, y: 1)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.02))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
        }
    }

    private func inlineCardBodyContent(isTranslation: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isTranslation && !ai.inlineAttachmentNames.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                    Text("已结合附件：\(ai.inlineAttachmentNames.joined(separator: "、"))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let notice = ai.inlineNoticeText, !notice.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if ai.inlineSummaryText.isEmpty && ai.isInlineSummarizing {
                Text(isTranslation ? "正在翻译邮件…" : "正在生成邮件摘要…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                MarkdownBlockView(text: ai.inlineSummaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }

}

private final class InlineCardHeightState: ObservableObject {
    @Published var contentHeight: CGFloat = 48

    func update(_ height: CGFloat) {
        let rounded = ceil(max(44, height))
        if abs(rounded - contentHeight) >= 1 {
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(rounded - self.contentHeight) >= 1 else { return }
                self.contentHeight = rounded
            }
        }
    }

    func clampedHeight(maxHeight: CGFloat) -> CGFloat {
        min(max(44, contentHeight), maxHeight)
    }
}

private final class RecipientExpandState: ObservableObject {
    @Published var isExpanded = false
}

private final class HeaderIconHoverState: ObservableObject {
    @Published var isHovered = false
}

private struct DetailHeaderIconButton: View {
    let systemImage: String
    let helpText: String
    var isDestructive: Bool = false
    let action: () -> Void

    @StateObject private var hoverState = HeaderIconHoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDestructive && hoverState.isHovered ? Color.red : Color.secondary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            hoverState.isHovered
                                ? (isDestructive ? Color.red.opacity(0.12) : Color.primary.opacity(0.08))
                                : Color.clear
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hoverState.isHovered = $0 }
        .help(helpText)
    }
}

enum MailBodyPresentationHelper {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let remoteResourceRegex = try? NSRegularExpression(
        pattern: #"(?i)(src|href|background)\s*=\s*["']?https?://|url\(\s*["']?https?://"#
    )

    /// Detects URLs inside plain-text emails off the main thread once per email load.
    static func linkify(_ plain: String) -> AttributedString {
        var attributed = AttributedString(plain)
        guard let detector = linkDetector else {
            return attributed
        }
        let nsRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        for match in detector.matches(in: plain, options: [], range: nsRange) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: plain),
                  let attrRange = Range(stringRange, in: attributed) else {
                continue
            }
            attributed[attrRange].link = url
            attributed[attrRange].foregroundColor = .accentColor
            attributed[attrRange].underlineStyle = .single
        }
        return attributed
    }

    static func containsRemoteResourceURL(_ rawHTML: String) -> Bool {
        guard let regex = remoteResourceRegex else { return false }
        let range = NSRange(rawHTML.startIndex..<rawHTML.endIndex, in: rawHTML)
        return regex.firstMatch(in: rawHTML, range: range) != nil
    }
}

/// Renders rich HTML email content via a single persistent WKWebView with isolated non-persistent storage,
/// default CSP remote-resource blocking (preserving inline `data:` / `cid:` images),
/// and strict external-link-only navigation policy.
private struct HTMLMailWebView: NSViewRepresentable {
    let html: String?
    let blockRemoteContent: Bool
    let releaseDOMWhenNil: Bool

    private static let stripRemoteRegexes: [(regex: NSRegularExpression, replacement: String)] = [
        (#"(?i)<iframe[\s\S]*?</iframe\s*>"#, ""),
        (#"(?i)<iframe[^>]*>"#, ""),
        (#"(?i)<link[^>]+href\s*=\s*["']?https?://[^>]*>"#, ""),
        (#"(?i)(\s(?:src|srcset|background|poster)\s*=\s*)(?:"https?://[^"]*"|'https?://[^']*'|https?://[^\s>]+)"#, "$1\"\""),
        (#"(?i)url\(\s*["']?https?://[^)]*\)"#, "url()")
    ].compactMap { pattern, rep in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, rep) }
    }
    private static let metaStripRegexes: [NSRegularExpression] = [
        #"(?i)<meta[^>]+http-equiv\s*=\s*["']?refresh["']?[^>]*>"#,
        #"(?i)<meta[^>]+http-equiv\s*=\s*["']?content-security-policy["']?[^>]*>"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let shellStripRegexes: [NSRegularExpression] = [
        #"(?i)<!doctype[^>]*>"#,
        #"(?i)</?html[^>]*>"#,
        #"(?i)</?head[^>]*>"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Keep a crisp light canvas for HTML emails so dark-colored text/logos remain readable in macOS Dark Mode.
        webView.setValue(true, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .white
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let html else {
            if releaseDOMWhenNil && context.coordinator.lastRenderKey != "EMPTY" {
                context.coordinator.lastRenderKey = "EMPTY"
                webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
            }
            return
        }
        let digest = SHA256.hash(data: Data(html.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let renderKey = "\(blockRemoteContent ? "B" : "A"):\(html.utf8.count):\(digest)"
        guard context.coordinator.lastRenderKey != renderKey else { return }
        context.coordinator.lastRenderKey = renderKey

        let preparedHTML = Self.prepareReadableHTML(from: html, blockRemoteContent: blockRemoteContent)
        let shouldBlock = blockRemoteContent
        let controller = webView.configuration.userContentController

        // Enforce network-layer blocking via WebKit's native WKContentRuleList BEFORE loading HTML.
        // Fail-closed: if rule compilation fails, strip all remote resource URLs from the HTML before loading
        // so zero external requests can leak on error paths.
        if shouldBlock {
            Self.loadBlockRuleList { ruleList in
                guard context.coordinator.lastRenderKey == renderKey else { return }
                controller.removeAllContentRuleLists()
                if let ruleList {
                    controller.add(ruleList)
                    webView.loadHTMLString(preparedHTML, baseURL: nil)
                } else {
                    let stripped = Self.stripRemoteResourceURLs(from: preparedHTML)
                    webView.loadHTMLString(stripped, baseURL: nil)
                }
            }
        } else {
            controller.removeAllContentRuleLists()
            webView.loadHTMLString(preparedHTML, baseURL: nil)
        }
    }

    /// Fail-closed HTML sanitizer used when `WKContentRuleList` is unavailable:
    /// removes remote `http(s)://` subresource URLs (`src`, `srcset`, `background`, `poster`, `url(...)`, `<link>`, `<iframe>`)
    /// while preserving inline `data:` images and clickable `<a href="...">` links.
    private static func stripRemoteResourceURLs(from html: String) -> String {
        var out = html
        for (regex, replacement) in stripRemoteRegexes {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: replacement)
        }
        return out
    }

    private static let remoteBlockRulesJSON = """
    [
      {
        "trigger": {
          "url-filter": "^https?://.*",
          "resource-type": ["image", "style-sheet", "script", "font", "media", "raw", "svg-document", "popup"]
        },
        "action": { "type": "block" }
      }
    ]
    """

    @MainActor private static var cachedBlockRuleList: WKContentRuleList?

    private static func loadBlockRuleList(completion: @escaping @MainActor (WKContentRuleList?) -> Void) {
        if let cached = cachedBlockRuleList {
            completion(cached)
            return
        }
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "com.mailpilot.block-remote-resources.v1",
            encodedContentRuleList: remoteBlockRulesJSON
        ) { ruleList, _ in
            Task { @MainActor in
                if let ruleList {
                    cachedBlockRuleList = ruleList
                }
                completion(ruleList)
            }
        }
    }

    /// Ensures HTML emails always have a readable light canvas, strips meta-refresh & sender CSP tags,
    /// and safely prepends Content-Security-Policy (without relying on regex-matching commented `<head>` tags).
    private static func prepareReadableHTML(from rawHTML: String, blockRemoteContent: Bool) -> String {
        var sanitizedHTML = rawHTML
        for regex in metaStripRegexes {
            let range = NSRange(sanitizedHTML.startIndex..<sanitizedHTML.endIndex, in: sanitizedHTML)
            sanitizedHTML = regex.stringByReplacingMatches(in: sanitizedHTML, range: range, withTemplate: "")
        }

        let cspMeta: String
        if blockRemoteContent {
            cspMeta = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; media-src data:; frame-src 'none'; object-src 'none';">"#
        } else {
            cspMeta = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https: http:; style-src 'unsafe-inline' https: http:; font-src data: https: http:; media-src data: https: http:; frame-src 'none'; object-src 'none';">"#
        }

        let lower = sanitizedHTML.lowercased()
        let hasCustomStyling = lower.contains("<style") || lower.contains("font-family")

        let baseCSS: String
        if hasCustomStyling {
            baseCSS = """
            \(cspMeta)
            <style id="mailpilot-canvas-style">
            :root { color-scheme: light; }
            html, body { background-color: #ffffff; color: #1d1d1f; }
            </style>
            """
        } else {
            baseCSS = """
            \(cspMeta)
            <style id="mailpilot-default-style">
            :root { color-scheme: light; }
            html, body {
                background-color: #ffffff;
                color: #1d1d1f;
                font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Helvetica Neue", sans-serif;
                font-size: 14px;
                line-height: 1.65;
                margin: 0;
                padding: 18px 22px;
                word-wrap: break-word;
                -webkit-font-smoothing: antialiased;
            }
            img { max-width: 100%; height: auto; }
            </style>
            """
        }

        // Always wrap with our own leading `<!doctype html><html><head>` containing the CSP meta tag first
        // (after stripping untrusted outer doctype/html/head shells) so malformed markup or comments can never
        // cause `<meta http-equiv="Content-Security-Policy">` to be ignored or placed after resource tags.
        var bodyOnly = sanitizedHTML
        for regex in shellStripRegexes {
            let range = NSRange(bodyOnly.startIndex..<bodyOnly.endIndex, in: bodyOnly)
            bodyOnly = regex.stringByReplacingMatches(in: bodyOnly, range: range, withTemplate: "")
        }
        return "<!doctype html><html><head><meta charset=\"utf-8\">\(baseCSS)</head><body>\(bodyOnly)</body></html>"
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastRenderKey: String = ""

        private static func isAllowedExternalURL(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https" || scheme == "mailto"
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                if Self.isAllowedExternalURL(url) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }

            // Only allow the initial local `loadHTMLString` main-frame load (`about:blank`).
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
            let urlString = navigationAction.request.url?.absoluteString.lowercased() ?? ""
            if isMainFrame && (urlString == "about:blank" || urlString.isEmpty) {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, Self.isAllowedExternalURL(url) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}
