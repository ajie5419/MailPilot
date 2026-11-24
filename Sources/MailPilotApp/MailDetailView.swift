import AppKit
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI
import WebKit

struct MailDetailView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        if let message = viewModel.selectedMessage {
            VStack(spacing: 0) {
                headerBar(for: message)
                Divider()

                inlineAIActionBar
                Divider()

                if viewModel.showInlineSummary {
                    inlineSummaryCard
                    Divider()
                }

                if let code = viewModel.selectedBody?.verificationCode {
                    verificationBanner(code: code)
                    Divider()
                }

                if let attachments = viewModel.selectedBody?.attachments, !attachments.isEmpty {
                    attachmentsBar(attachments)
                    Divider()
                }

                if viewModel.isLoadingBody {
                    ProgressView("正在解析本地 .emlx 正文...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !viewModel.preferPlainText, let html = viewModel.selectedBody?.rawHTML, !html.isEmpty {
                    HTMLMailWebView(html: html)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(linkifiedAttributedText(viewModel.selectedBody?.plainText ?? ""))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
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

    private func headerBar(for message: MailMessageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(message.subject)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                HStack(spacing: 6) {
                    Button {
                        viewModel.openComposeReply(for: message)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left")
                    }
                    .help("回复（⌘R）")

                    Button {
                        viewModel.openComposeForward(for: message)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.right")
                    }
                    .help("转发（⇧⌘F）")

                    Button {
                        viewModel.archiveMessage(message)
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .help("归档（⌃⌘A）")

                    Button {
                        viewModel.deleteMessage(message)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("删除（⌘⌫）")

                    if viewModel.selectedBody?.rawHTML != nil {
                        Button {
                            viewModel.preferPlainText.toggle()
                        } label: {
                            Label(
                                viewModel.preferPlainText ? "纯文本" : "富文本",
                                systemImage: viewModel.preferPlainText ? "doc.plaintext" : "doc.richtext"
                            )
                        }
                        .help(viewModel.preferPlainText ? "当前为纯文本，点击切换为 HTML 富文本" : "当前为 HTML 富文本，点击切换为纯文本")
                    }

                    Button {
                        viewModel.toggleReadStatus(for: message)
                    } label: {
                        Image(systemName: message.isRead ? "envelope.badge" : "envelope.open")
                    }
                    .help(message.isRead ? "标记为未读" : "标记为已读")

                    Button {
                        viewModel.toggleFlaggedStatus(for: message)
                    } label: {
                        Image(systemName: message.isFlagged ? "flag.fill" : "flag")
                            .foregroundStyle(message.isFlagged ? .orange : .primary)
                    }
                    .help(message.isFlagged ? "取消旗标" : "添加旗标")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                VStack(alignment: .trailing, spacing: 2) {
                    Text(message.dateReceived.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let acctName = viewModel.accountDisplayName(for: message.accountID) {
                        AccountBadgePill(
                            accountID: message.accountID,
                            label: "\(acctName) · \(message.mailboxName)",
                            email: viewModel.accountEmail(for: message.accountID),
                            customIconPath: viewModel.accountCustomIconPath(for: message.accountID),
                            presetLogoID: viewModel.accountPresetLogoID(for: message.accountID),
                            sfSymbolName: viewModel.accountSFSymbolName(for: message.accountID),
                            fallbackColor: viewModel.accountBadgeColor(for: message.accountID)
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(.background)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(attachments.count) 个附件（点击直接打开，右键可另存为）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { att in
                        Button {
                            viewModel.openAttachment(att)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: iconForAttachment(att))
                                    .font(.system(size: 15))
                                    .foregroundStyle(colorForAttachment(att))
                                    .frame(width: 24, height: 24)
                                    .background(colorForAttachment(att).opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(att.filename)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(att.formattedSize)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: 180, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.7)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar.opacity(0.45))
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

    private var inlineAIActionBar: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.summarizeSelectedEmailInline()
            } label: {
                Label(
                    viewModel.isInlineSummarizing ? "总结中..." : "总结邮件",
                    systemImage: "sparkles"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isLoadingBody || viewModel.isInlineSummarizing)

            Button {
                viewModel.generateReplyDraft(tone: "专业简洁")
            } label: {
                Label("起草回复", systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isLoadingBody || viewModel.isAIThinking)

            Button {
                viewModel.showAIPanel.toggle()
            } label: {
                Label(viewModel.showAIPanel ? "收起对话" : "追问 AI", systemImage: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Button {
                viewModel.settingsTab = .ai
                viewModel.showSettings = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption2)
                    Text("\(viewModel.activeAIBadge) · \(viewModel.activeModelDisplayName)")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("点击配置模型或订阅账号")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar.opacity(0.6))
    }

    private var inlineSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("AI 摘要", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                if viewModel.isInlineSummarizing {
                    ProgressView().controlSize(.mini)
                }

                Spacer()

                if !viewModel.inlineSummaryText.isEmpty {
                    Button {
                        viewModel.copyToClipboard(viewModel.inlineSummaryText, label: "已复制摘要")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("复制摘要")

                    Button {
                        viewModel.continueInlineSummaryInDrawer()
                    } label: {
                        Text("继续追问")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                }

                Button {
                    viewModel.showInlineSummary = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("收起摘要")
            }

            if viewModel.inlineSummaryText.isEmpty && viewModel.isInlineSummarizing {
                Text("正在生成邮件摘要...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                MarkdownBlockView(text: viewModel.inlineSummaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background)
    }

    /// Detects URLs inside plain-text emails and converts them into clickable links.
    private func linkifiedAttributedText(_ plain: String) -> AttributedString {
        var attributed = AttributedString(plain)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
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
}

/// Renders rich HTML email content via WKWebView and opens clicked links (including target="_blank") in the system browser.
private struct HTMLMailWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
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
        guard context.coordinator.lastLoadedHTML != html else { return }
        context.coordinator.lastLoadedHTML = html
        webView.loadHTMLString(Self.prepareReadableHTML(from: html), baseURL: nil)
    }

    /// Ensures HTML emails always have a readable light canvas (preventing black-on-black text in Dark Mode)
    /// and injects PingFang SC system font defaults for simple HTML emails without custom CSS.
    private static func prepareReadableHTML(from rawHTML: String) -> String {
        let lower = rawHTML.lowercased()
        let hasCustomStyling = lower.contains("<style") || lower.contains("font-family")

        let baseCSS: String
        if hasCustomStyling {
            baseCSS = """
            <style id="mailpilot-canvas-style">
            :root { color-scheme: light; }
            html, body { background-color: #ffffff; color: #1d1d1f; }
            </style>
            """
        } else {
            baseCSS = """
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

        if let headRegex = try? NSRegularExpression(pattern: "(?i)<head[^>]*>"),
           let match = headRegex.firstMatch(in: rawHTML, range: NSRange(rawHTML.startIndex..<rawHTML.endIndex, in: rawHTML)),
           let range = Range(match.range, in: rawHTML) {
            var copy = rawHTML
            copy.insert(contentsOf: baseCSS, at: range.upperBound)
            return copy
        }

        if let htmlRegex = try? NSRegularExpression(pattern: "(?i)<html[^>]*>"),
           let match = htmlRegex.firstMatch(in: rawHTML, range: NSRange(rawHTML.startIndex..<rawHTML.endIndex, in: rawHTML)),
           let range = Range(match.range, in: rawHTML) {
            var copy = rawHTML
            copy.insert(contentsOf: "<head>\(baseCSS)</head>", at: range.upperBound)
            return copy
        }

        return "<!doctype html><html><head><meta charset=\"utf-8\">\(baseCSS)</head><body>\(rawHTML)</body></html>"
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastLoadedHTML: String = ""

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}
