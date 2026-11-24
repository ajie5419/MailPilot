import AppKit
import Combine
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif

/// Manages the in-app compose, reply, and forward sheet state, attachments, AI polish streaming,
/// and delegating final send / save-draft execution to Mail.app via AppleScript.
@MainActor
final class ComposeCoordinator: ObservableObject {
    @Published var isPresented = false
    @Published var draft = ComposeDraftState()

    var currentAIConfig: (() -> AIConfig)?
    var preferredSenderEmail: (() -> String)?
    var senderEmailForOriginAccount: ((String) -> String?)?
    var formattedSenderHeader: ((String) -> String?)?
    var accountEmailsCount: (() -> Int)?
    var onRefreshAccountEmailsIfEmpty: (() -> Void)?
    var onShowToast: ((String) -> Void)?

    private let aiService = AIService()
    private var polishTask: Task<Void, Never>?

    func close() {
        polishTask?.cancel()
        polishTask = nil
        draft.isAIPolishing = false
        isPresented = false
    }

    func openNew() {
        polishTask?.cancel()
        polishTask = nil
        draft = ComposeDraftState(
            id: UUID(),
            revision: 0,
            mode: .new,
            fromEmail: preferredSenderEmail?() ?? "",
            toText: "",
            ccText: "",
            subject: "",
            body: ""
        )
        isPresented = true
        onRefreshAccountEmailsIfEmpty?()
    }

    func openReply(for target: MailMessageSummary, verifiedBody: String?, prefilledBody: String? = nil) {
        polishTask?.cancel()
        polishTask = nil
        let replySubject = target.subject.lowercased().hasPrefix("re:") ? target.subject : "Re: \(target.subject)"
        let quoteHeader = "\n\n---\n在 \(target.dateReceived.formatted(date: .abbreviated, time: .shortened))，\(target.displaySender) <\(target.senderAddress)> 写道：\n"
        let quoteBody = verifiedBody.map { String($0.prefix(1200)) } ?? ""
        let initialBody: String
        if let prefilledBody {
            initialBody = prefilledBody + (quoteBody.isEmpty ? "" : quoteHeader + quoteBody)
        } else {
            initialBody = quoteBody.isEmpty ? "" : "\n\n" + quoteHeader + quoteBody
        }
        let originEmail = senderEmailForOriginAccount?(target.accountID)
        let warning: String?
        let resolvedFrom: String
        if let originEmail {
            resolvedFrom = originEmail
            warning = nil
        } else if (accountEmailsCount?() ?? 0) > 1 {
            resolvedFrom = ""
            warning = "未能自动匹配原邮件所属发件账号，请手动确认发件人后再发送。"
        } else {
            resolvedFrom = preferredSenderEmail?() ?? ""
            warning = nil
        }
        draft = ComposeDraftState(
            id: UUID(),
            revision: 0,
            mode: .reply,
            fromEmail: resolvedFrom,
            toText: target.senderAddress,
            ccText: "",
            subject: replySubject,
            body: initialBody,
            missingOriginAccountWarning: warning
        )
        isPresented = true
        onRefreshAccountEmailsIfEmpty?()
    }

    func openForward(for target: MailMessageSummary, verifiedBody: String?) {
        polishTask?.cancel()
        polishTask = nil
        let fwdSubject = target.subject.lowercased().hasPrefix("fwd:") ? target.subject : "Fwd: \(target.subject)"
        let header = """
        

        ---------- 转发的邮件 ----------
        发件人：\(target.displaySender) <\(target.senderAddress)>
        日期：\(target.dateReceived.formatted(date: .abbreviated, time: .shortened))
        主题：\(target.subject)

        """
        let bodyText = verifiedBody ?? ""
        let originEmail = senderEmailForOriginAccount?(target.accountID)
        let warning: String?
        let resolvedFrom: String
        if let originEmail {
            resolvedFrom = originEmail
            warning = nil
        } else if (accountEmailsCount?() ?? 0) > 1 {
            resolvedFrom = ""
            warning = "未能自动匹配原邮件所属发件账号，请手动确认发件人后再转发。"
        } else {
            resolvedFrom = preferredSenderEmail?() ?? ""
            warning = nil
        }
        draft = ComposeDraftState(
            id: UUID(),
            revision: 0,
            mode: .forward,
            fromEmail: resolvedFrom,
            toText: "",
            ccText: "",
            subject: fwdSubject,
            body: header + bodyText,
            missingOriginAccountWarning: warning
        )
        isPresented = true
        onRefreshAccountEmailsIfEmpty?()
    }

    func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            for url in panel.urls where !draft.attachmentURLs.contains(url) {
                draft.attachmentURLs.append(url)
            }
        }
    }

    func removeAttachment(_ url: URL) {
        draft.attachmentURLs.removeAll { $0 == url }
    }

    func sendMail() {
        guard !draft.isSending else { return }
        let toList = parseEmailList(draft.toText)
        guard !toList.isEmpty else {
            onShowToast?("请填写至少一个收件人邮箱")
            return
        }
        if (accountEmailsCount?() ?? 0) > 0 &&
            draft.fromEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            draft.missingOriginAccountWarning != nil {
            onShowToast?("请先选择发件账号再发送")
            return
        }
        let ccList = parseEmailList(draft.ccText)
        polishTask?.cancel()
        polishTask = nil
        draft.isAIPolishing = false
        let currentDraft = draft
        let draftID = currentDraft.id
        draft.isSending = true

        let senderHeader = formattedSenderHeader?(currentDraft.fromEmail)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await MailAppleScriptBridge.sendMessage(
                    from: senderHeader,
                    to: toList,
                    cc: ccList,
                    subject: currentDraft.subject.isEmpty ? "(无主题)" : currentDraft.subject,
                    body: currentDraft.body,
                    attachmentURLs: currentDraft.attachmentURLs
                )
                if self.draft.id == draftID {
                    self.draft.isSending = false
                    self.isPresented = false
                }
                self.onShowToast?("已交给系统 Mail.app 发送")
            } catch {
                if self.draft.id == draftID {
                    self.draft.isSending = false
                }
                self.onShowToast?("发送失败（草稿已保留）：\(error.localizedDescription)")
            }
        }
    }

    func saveDraft() {
        guard !draft.isSending else { return }
        let toList = parseEmailList(draft.toText)
        let ccList = parseEmailList(draft.ccText)
        polishTask?.cancel()
        polishTask = nil
        draft.isAIPolishing = false
        let currentDraft = draft
        let draftID = currentDraft.id
        draft.isSending = true

        let senderHeader = formattedSenderHeader?(currentDraft.fromEmail)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await MailAppleScriptBridge.saveDraft(
                    from: senderHeader,
                    to: toList,
                    cc: ccList,
                    subject: currentDraft.subject.isEmpty ? "(无主题)" : currentDraft.subject,
                    body: currentDraft.body,
                    attachmentURLs: currentDraft.attachmentURLs
                )
                if self.draft.id == draftID {
                    self.draft.isSending = false
                    self.isPresented = false
                }
                self.onShowToast?("已保存至草稿箱")
            } catch {
                if self.draft.id == draftID {
                    self.draft.isSending = false
                }
                self.onShowToast?("保存草稿失败：\(error.localizedDescription)")
            }
        }
    }

    func polishBodyWithAI() {
        guard !draft.isSending, let configSnapshot = currentAIConfig?() else { return }
        polishTask?.cancel()
        let draftID = draft.id
        let baseRevision = draft.revision
        let currentBody = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = draft.subject
        let to = draft.toText
        draft.isAIPolishing = true
        draft.pendingAIPolish = ""
        draft.polishBaseRevision = baseRevision

        let prompt: String
        if currentBody.isEmpty {
            prompt = "请根据主题「\(subject)」和收件人「\(to)」，起草一封得体、专业简洁的中文邮件正文（直接输出正文，不要附加解释）。"
        } else {
            prompt = "请帮我润色并补全以下邮件草稿，使其更自然、清晰、得体（直接输出润色后的完整正文，不要附加解释）：\n\n\(currentBody)"
        }

        polishTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.aiService.chat(
                    config: configSnapshot,
                    systemPrompt: "你是一位专业高效的邮件写作助手。",
                    history: [],
                    userMessage: prompt,
                    onPartial: { [weak self] partial in
                        Task { @MainActor [weak self] in
                            guard let self, self.draft.id == draftID, self.draft.isAIPolishing else { return }
                            self.draft.pendingAIPolish = partial
                        }
                    }
                )
                guard !Task.isCancelled, self.draft.id == draftID else { return }
                self.draft.pendingAIPolish = result
            } catch {
                if !Task.isCancelled, self.draft.id == draftID {
                    self.draft.pendingAIPolish = nil
                    self.onShowToast?("AI 润色失败：\(error.localizedDescription)")
                }
            }
            if self.draft.id == draftID {
                self.draft.isAIPolishing = false
            }
        }
    }

    func cancelAIPolish() {
        polishTask?.cancel()
        polishTask = nil
        draft.isAIPolishing = false
    }

    func applyPendingAIPolish() {
        guard let preview = draft.pendingAIPolish, !preview.isEmpty else { return }
        draft.body = preview
        draft.revision += 1
        draft.pendingAIPolish = nil
        draft.polishBaseRevision = nil
        onShowToast?("已采纳 AI 润色内容")
    }

    func discardPendingAIPolish() {
        polishTask?.cancel()
        polishTask = nil
        draft.isAIPolishing = false
        draft.pendingAIPolish = nil
        draft.polishBaseRevision = nil
    }

    private func parseEmailList(_ raw: String) -> [String] {
        raw
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "；", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
