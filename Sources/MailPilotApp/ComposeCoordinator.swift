import AppKit
import Combine
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import UniformTypeIdentifiers

/// Manages the in-app compose, reply, reply-all, and forward sheet state, local contact
/// autocomplete, account signatures, attachments (with live preparation progress and explicit
/// success/failure feedback), AI polish streaming, and delegating final send / save-draft
/// execution to Mail.app via AppleScript.
@MainActor
final class ComposeCoordinator: ObservableObject {
    @Published var isPresented = false
    @Published var draft = ComposeDraftState()
    @Published var activeRecipientField: ComposeRecipientField? = nil
    @Published var contactSuggestions: [MailContactSuggestion] = []

    var currentAIConfig: (() -> AIConfig)?
    var preferredSenderEmail: (() -> String)?
    var senderEmailForOriginAccount: ((String) -> String?)?
    var formattedSenderHeader: ((String) -> String?)?
    var signatureForSenderEmail: ((String) -> String?)?
    var allOwnEmails: (() -> [String])?
    var accountEmailsCount: (() -> Int)?
    var onRefreshAccountEmailsIfEmpty: (() -> Void)?
    var onSearchContacts: ((String) async -> [MailContactSuggestion])?
    var onMaterializeAttachment: ((MailAttachment, Int64) async -> URL?)?
    var onShowToast: ((String) -> Void)?

    private let aiService = AIService()
    private var polishTask: Task<Void, Never>?
    private var attachmentTasks: [UUID: Task<Void, Never>] = [:]
    private var forwardImportTask: Task<Void, Never>?
    private var contactSearchTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?

    func requestClose() {
        guard !draft.isSending else { return }
        if draft.hasUnsavedChanges {
            draft.showDiscardConfirmation = true
        } else {
            forceClose()
        }
    }

    func forceClose() {
        resetTasksForNewDraft()
        draft.isAIPolishing = false
        draft.showDiscardConfirmation = false
        isPresented = false
    }

    func close() {
        requestClose()
    }

    func openNew() {
        resetTasksForNewDraft()
        let sender = preferredSenderEmail?() ?? ""
        let sigBlock = formattedSignatureBlock(for: sender)
        let initialBody = sigBlock ?? ""
        draft = ComposeDraftState(
            id: UUID(),
            revision: 0,
            mode: .new,
            fromEmail: sender,
            toText: "",
            ccText: "",
            bccText: "",
            showBCCField: false,
            subject: "",
            body: initialBody,
            appliedSignature: sigBlock,
            initialToText: "",
            initialCCText: "",
            initialSubject: "",
            initialBody: initialBody
        )
        isPresented = true
        onRefreshAccountEmailsIfEmpty?()
    }

    func openReply(for target: MailMessageSummary, verifiedBody: String?, prefilledBody: String? = nil) {
        openReplyInternal(
            for: target,
            verifiedBody: verifiedBody,
            prefilledBody: prefilledBody,
            recipients: [],
            replyAll: false
        )
    }

    func openReplyAll(
        for target: MailMessageSummary,
        recipients: [MailRecipientInfo],
        verifiedBody: String?,
        prefilledBody: String? = nil
    ) {
        openReplyInternal(
            for: target,
            verifiedBody: verifiedBody,
            prefilledBody: prefilledBody,
            recipients: recipients,
            replyAll: true
        )
    }

    private func openReplyInternal(
        for target: MailMessageSummary,
        verifiedBody: String?,
        prefilledBody: String?,
        recipients: [MailRecipientInfo],
        replyAll: Bool
    ) {
        resetTasksForNewDraft()
        let replySubject = target.subject.lowercased().hasPrefix("re:") ? target.subject : "Re: \(target.subject)"
        let quoteHeader = "\n\n---\n在 \(target.dateReceived.formatted(date: .abbreviated, time: .shortened))，\(target.displaySender) <\(target.senderAddress)> 写道：\n"
        let quoteBody = verifiedBody.map { String($0.prefix(1200)) } ?? ""

        let originEmail = senderEmailForOriginAccount?(target.accountID)
        let warning: String?
        let resolvedFrom: String
        if let originEmail {
            resolvedFrom = originEmail
            warning = nil
        } else if (accountEmailsCount?() ?? 0) > 1 {
            resolvedFrom = ""
            warning = "未能自动匹配原邮件所属发件账号，请手动确认发件人后再回复。"
        } else {
            resolvedFrom = preferredSenderEmail?() ?? ""
            warning = nil
        }

        let sigBlock = formattedSignatureBlock(for: resolvedFrom)
        let quoteSuffix = quoteBody.isEmpty ? "" : quoteHeader + quoteBody
        let initialBody: String
        if let prefilledBody {
            initialBody = prefilledBody + (sigBlock ?? "") + quoteSuffix
        } else if let sigBlock {
            initialBody = sigBlock + quoteSuffix
        } else {
            initialBody = quoteBody.isEmpty ? "" : "\n\n" + quoteHeader + quoteBody
        }

        let toText: String
        let ccText: String
        if replyAll {
            var ownSet = Set((allOwnEmails?() ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            if !resolvedFrom.isEmpty {
                ownSet.insert(resolvedFrom.lowercased())
            }
            var toAddresses: [String] = []
            var seenLower: Set<String> = []
            let senderClean = target.senderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            if !senderClean.isEmpty && !ownSet.contains(senderClean.lowercased()) {
                toAddresses.append(senderClean)
                seenLower.insert(senderClean.lowercased())
            }
            for r in recipients where !r.isCC {
                let addr = r.address.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = addr.lowercased()
                if !addr.isEmpty && !ownSet.contains(lower) && seenLower.insert(lower).inserted {
                    toAddresses.append(addr)
                }
            }
            if toAddresses.isEmpty && !senderClean.isEmpty {
                toAddresses.append(senderClean)
                seenLower.insert(senderClean.lowercased())
            }

            var ccAddresses: [String] = []
            for r in recipients where r.isCC {
                let addr = r.address.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = addr.lowercased()
                if !addr.isEmpty && !ownSet.contains(lower) && seenLower.insert(lower).inserted {
                    ccAddresses.append(addr)
                }
            }
            toText = toAddresses.joined(separator: ", ")
            ccText = ccAddresses.joined(separator: ", ")
        } else {
            toText = target.senderAddress
            ccText = ""
        }

        draft = ComposeDraftState(
            id: UUID(),
            revision: 0,
            mode: replyAll ? .replyAll : .reply,
            fromEmail: resolvedFrom,
            toText: toText,
            ccText: ccText,
            bccText: "",
            showBCCField: false,
            subject: replySubject,
            body: initialBody,
            appliedSignature: sigBlock,
            initialToText: toText,
            initialCCText: ccText,
            initialSubject: replySubject,
            initialBody: initialBody,
            missingOriginAccountWarning: warning
        )
        isPresented = true
        onRefreshAccountEmailsIfEmpty?()
    }

    func openForward(
        for target: MailMessageSummary,
        verifiedBody: String?,
        originalAttachments: [MailAttachment] = []
    ) {
        resetTasksForNewDraft()
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

        let sigBlock = formattedSignatureBlock(for: resolvedFrom)
        let initialBody = (sigBlock ?? "") + header + bodyText
        let draftID = UUID()
        draft = ComposeDraftState(
            id: draftID,
            revision: 0,
            mode: .forward,
            fromEmail: resolvedFrom,
            toText: "",
            ccText: "",
            bccText: "",
            showBCCField: false,
            subject: fwdSubject,
            body: initialBody,
            appliedSignature: sigBlock,
            initialToText: "",
            initialCCText: "",
            initialSubject: fwdSubject,
            initialBody: initialBody,
            missingOriginAccountWarning: warning
        )
        isPresented = true
        onRefreshAccountEmailsIfEmpty?()

        // Automatically import original email attachments into the forward draft.
        if !originalAttachments.isEmpty, let materialize = onMaterializeAttachment {
            showBanner(
                ComposeFeedbackBanner(
                    kind: .progress(nil),
                    message: "正在带入原邮件的 \(originalAttachments.count) 个附件…"
                )
            )
            forwardImportTask = Task { [weak self] in
                var urls: [URL] = []
                var failedNames: [String] = []
                for att in originalAttachments {
                    if Task.isCancelled { return }
                    if let url = await materialize(att, target.id) {
                        urls.append(url)
                    } else {
                        failedNames.append(att.filename)
                    }
                }
                guard !Task.isCancelled, let self, self.draft.id == draftID else { return }
                if !urls.isEmpty {
                    self.addAttachments(urls)
                } else if !failedNames.isEmpty {
                    self.showBanner(
                        ComposeFeedbackBanner(
                            kind: .warning,
                            message: "原邮件附件未能自动导入（\(failedNames.count) 个）",
                            detail: "原附件可能尚未缓存到本地：\(failedNames.prefix(2).joined(separator: "、"))"
                        )
                    )
                }
            }
        }
    }

    // MARK: - Sender & Signature Switching

    func updateSenderEmail(_ newEmail: String) {
        guard draft.fromEmail != newEmail else { return }
        draft.fromEmail = newEmail

        let nextSig = formattedSignatureBlock(for: newEmail)
        if let oldSig = draft.appliedSignature, !oldSig.isEmpty,
           let range = draft.body.range(of: oldSig) {
            draft.body.replaceSubrange(range, with: nextSig ?? "")
            draft.appliedSignature = nextSig
            if draft.revision == 0 {
                draft.initialBody = draft.body
            }
        } else if draft.appliedSignature == nil, let nextSig, draft.revision == 0 {
            if draft.mode == .new && draft.body.isEmpty {
                draft.body = nextSig
            } else {
                draft.body = nextSig + draft.body
            }
            draft.appliedSignature = nextSig
            draft.initialBody = draft.body
        }
    }

    private func formattedSignatureBlock(for senderEmail: String) -> String? {
        guard let raw = signatureForSenderEmail?(senderEmail) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\n\n--\n\(trimmed)"
    }

    // MARK: - Local Contact Autocomplete

    func updateRecipientSuggestions(for field: ComposeRecipientField, text: String) {
        activeRecipientField = field
        contactSearchTask?.cancel()

        let token = Self.trailingRecipientToken(in: text)
        guard !token.isEmpty, let search = onSearchContacts else {
            contactSuggestions = []
            return
        }

        let existing = Set(parseEmailList(text).map { $0.lowercased() })
        let draftID = draft.id
        contactSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let results = await search(token)
            guard !Task.isCancelled, let self, self.draft.id == draftID, self.activeRecipientField == field else { return }
            self.contactSuggestions = results.filter { !existing.contains($0.address.lowercased()) }
        }
    }

    func selectContactSuggestion(_ contact: MailContactSuggestion, for field: ComposeRecipientField) {
        switch field {
        case .to:
            draft.toText = Self.replacingTrailingToken(in: draft.toText, with: contact.address)
        case .cc:
            draft.ccText = Self.replacingTrailingToken(in: draft.ccText, with: contact.address)
        case .bcc:
            draft.bccText = Self.replacingTrailingToken(in: draft.bccText, with: contact.address)
        }
        contactSuggestions = []
    }

    func acceptFirstContactSuggestion(for field: ComposeRecipientField) {
        guard activeRecipientField == field, let first = contactSuggestions.first else { return }
        selectContactSuggestion(first, for: field)
    }

    func clearContactSuggestions() {
        contactSearchTask?.cancel()
        contactSearchTask = nil
        activeRecipientField = nil
        contactSuggestions = []
    }

    private static func trailingRecipientToken(in text: String) -> String {
        let separators = CharacterSet(charactersIn: ",，;；")
        let parts = text.components(separatedBy: separators)
        return parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func replacingTrailingToken(in text: String, with address: String) -> String {
        let separators: [Character] = [",", "，", ";", "；"]
        if let lastSepIdx = text.lastIndex(where: { separators.contains($0) }) {
            let prefix = text[...lastSepIdx].trimmingCharacters(in: .whitespaces)
            return "\(prefix) \(address), "
        }
        return "\(address), "
    }

    // MARK: - Inline Feedback Banner

    func showBanner(_ banner: ComposeFeedbackBanner, autoDismissAfter seconds: Double? = nil) {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        draft.feedbackBanner = banner

        if let seconds {
            let bannerID = banner.id
            let draftID = draft.id
            bannerDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                if self.draft.id == draftID && self.draft.feedbackBanner?.id == bannerID {
                    self.draft.feedbackBanner = nil
                }
            }
        }
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        draft.feedbackBanner = nil
    }

    // MARK: - Attachments (Pick, Drop, Verify/Prepare with Progress, Retry, Remove)

    func pickAttachments() {
        guard !draft.isSending else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "添加附件"
        if panel.runModal() == .OK {
            addAttachments(panel.urls)
        }
    }

    func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        let draftID = draft.id
        Task { [weak self] in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            guard let self, self.draft.id == draftID else { return }
            if urls.isEmpty {
                self.showBanner(
                    ComposeFeedbackBanner(
                        kind: .error,
                        message: "无法读取拖入的文件",
                        detail: "请尝试点击左下角「添加附件」按钮选择本地文件"
                    )
                )
            } else {
                self.addAttachments(urls)
            }
        }
        return true
    }

    func addAttachments(_ urls: [URL]) {
        guard !draft.isSending, !urls.isEmpty else { return }

        var existingPaths = Set(draft.attachments.map { $0.url.standardizedFileURL.path })
        var newItems: [ComposeAttachmentItem] = []
        var skippedDuplicates: [String] = []

        for url in urls {
            let normalizedPath = url.standardizedFileURL.path
            if existingPaths.contains(normalizedPath) {
                skippedDuplicates.append(url.lastPathComponent)
                continue
            }
            existingPaths.insert(normalizedPath)
            let item = ComposeAttachmentItem(
                id: UUID(),
                url: url,
                filename: url.lastPathComponent,
                status: .preparing(progress: 0.05, detail: "准备中…"),
                sizeBytes: nil
            )
            newItems.append(item)
            draft.attachments.append(item)
        }

        if newItems.isEmpty {
            let names = skippedDuplicates.prefix(2).joined(separator: "、")
            showBanner(
                ComposeFeedbackBanner(
                    kind: .info,
                    message: "所选附件已在列表中，无需重复添加",
                    detail: names.isEmpty ? nil : names
                ),
                autoDismissAfter: 3
            )
            return
        }

        let draftID = draft.id
        let batchIDs = newItems.map(\.id)
        let skippedCount = skippedDuplicates.count

        updateBatchPreparationBanner(batchIDs: batchIDs)

        for item in newItems {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.prepareSingleAttachment(
                    itemID: item.id,
                    url: item.url,
                    draftID: draftID,
                    batchIDs: batchIDs,
                    skippedDuplicatesCount: skippedCount
                )
            }
            attachmentTasks[item.id] = task
        }
    }

    func retryAttachment(_ id: UUID) {
        guard !draft.isSending,
              let idx = draft.attachments.firstIndex(where: { $0.id == id }) else { return }
        attachmentTasks[id]?.cancel()
        let url = draft.attachments[idx].url
        let draftID = draft.id
        draft.attachments[idx].status = .preparing(progress: 0.05, detail: "重试中…")
        draft.attachments[idx].sizeBytes = nil

        showBanner(
            ComposeFeedbackBanner(
                kind: .progress(0.05),
                message: "正在重新准备附件「\(draft.attachments[idx].filename)」…"
            )
        )

        let task = Task { [weak self] in
            guard let self else { return }
            await self.prepareSingleAttachment(
                itemID: id,
                url: url,
                draftID: draftID,
                batchIDs: [id],
                skippedDuplicatesCount: 0
            )
        }
        attachmentTasks[id] = task
    }

    func removeAttachment(_ id: UUID) {
        guard !draft.isSending else { return }
        attachmentTasks[id]?.cancel()
        attachmentTasks[id] = nil
        draft.attachments.removeAll { $0.id == id }

        if !draft.isPreparingAttachments && draft.failedAttachmentsCount == 0 {
            if let kind = draft.feedbackBanner?.kind {
                switch kind {
                case .error, .warning, .progress:
                    dismissBanner()
                case .success, .info:
                    break
                }
            }
        }
    }

    private func prepareSingleAttachment(
        itemID: UUID,
        url: URL,
        draftID: UUID,
        batchIDs: [UUID],
        skippedDuplicatesCount: Int
    ) async {
        defer {
            if attachmentTasks[itemID] != nil {
                attachmentTasks[itemID] = nil
            }
        }

        let outcome = await Self.verifyAndReadAttachment(url: url) { [weak self] progress, detail in
            Task { @MainActor [weak self] in
                guard let self, self.draft.id == draftID,
                      let idx = self.draft.attachments.firstIndex(where: { $0.id == itemID }) else { return }
                self.draft.attachments[idx].status = .preparing(progress: progress, detail: detail)
                self.updateBatchPreparationBanner(batchIDs: batchIDs)
            }
        }

        guard !Task.isCancelled, draft.id == draftID,
              let idx = draft.attachments.firstIndex(where: { $0.id == itemID }) else { return }

        switch outcome {
        case .success(let sizeBytes):
            draft.attachments[idx].sizeBytes = sizeBytes
            draft.attachments[idx].status = .ready(sizeBytes: sizeBytes)
        case .failure(let reason):
            draft.attachments[idx].sizeBytes = nil
            draft.attachments[idx].status = .failed(reason: reason)
        }

        let batchItems = draft.attachments.filter { batchIDs.contains($0.id) }
        if batchItems.contains(where: { $0.status.isPreparing }) {
            updateBatchPreparationBanner(batchIDs: batchIDs)
            return
        }

        finalizeBatchPreparationBanner(batchItems: batchItems, skippedDuplicatesCount: skippedDuplicatesCount)
    }

    private func updateBatchPreparationBanner(batchIDs: [UUID]) {
        let batchItems = draft.attachments.filter { batchIDs.contains($0.id) }
        guard !batchItems.isEmpty else { return }

        var progressSum: Double = 0
        var activeName: String?
        for item in batchItems {
            switch item.status {
            case .preparing(let p, _):
                progressSum += p
                if activeName == nil { activeName = item.filename }
            case .ready, .attaching, .attached, .failed:
                progressSum += 1.0
            }
        }
        let overall = progressSum / Double(batchItems.count)
        let doneCount = batchItems.filter { !$0.status.isPreparing }.count
        let pct = Int((overall * 100).rounded())
        let message: String
        if batchItems.count == 1, let name = activeName {
            message = "正在准备附件「\(name)」（\(pct)%）"
        } else {
            message = "正在准备附件（\(doneCount)/\(batchItems.count) · \(pct)%）"
        }
        showBanner(ComposeFeedbackBanner(kind: .progress(overall), message: message, detail: activeName))
    }

    private func finalizeBatchPreparationBanner(batchItems: [ComposeAttachmentItem], skippedDuplicatesCount: Int) {
        guard !batchItems.isEmpty else {
            dismissBanner()
            return
        }

        let succeeded = batchItems.filter { $0.status.isReady }
        let failed = batchItems.filter { $0.status.failureReason != nil }
        let batchBytes = succeeded.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        let batchSizeText = ByteCountFormatter.string(fromByteCount: batchBytes, countStyle: .file)
        let dupNote = skippedDuplicatesCount > 0 ? "（已跳过 \(skippedDuplicatesCount) 个重复文件）" : ""

        if failed.isEmpty {
            if draft.exceedsRecommendedAttachmentLimit {
                showBanner(
                    ComposeFeedbackBanner(
                        kind: .warning,
                        message: "已添加 \(succeeded.count) 个附件（本次 \(batchSizeText)）\(dupNote)",
                        detail: "当前附件总大小 \(draft.formattedTotalAttachmentSize)，超过 25 MB 可能被部分邮箱拒收"
                    )
                )
            } else {
                let singleName = succeeded.count == 1 ? "「\(succeeded[0].filename)」" : "\(succeeded.count) 个附件"
                showBanner(
                    ComposeFeedbackBanner(
                        kind: .success,
                        message: "已成功添加\(singleName)（\(batchSizeText)）\(dupNote)"
                    ),
                    autoDismissAfter: 4
                )
            }
        } else if !succeeded.isEmpty {
            let firstErr = failed[0]
            let reason = firstErr.status.failureReason ?? "读取失败"
            showBanner(
                ComposeFeedbackBanner(
                    kind: .warning,
                    message: "成功添加 \(succeeded.count) 个附件，\(failed.count) 个失败",
                    detail: "「\(firstErr.filename)」：\(reason)"
                )
            )
        } else {
            let firstErr = failed[0]
            let reason = firstErr.status.failureReason ?? "读取失败"
            let title = failed.count == 1
                ? "添加附件「\(firstErr.filename)」失败"
                : "\(failed.count) 个附件添加失败"
            showBanner(
                ComposeFeedbackBanner(
                    kind: .error,
                    message: title,
                    detail: reason
                )
            )
        }
    }

    private enum AttachmentPrepOutcome: Sendable {
        case success(Int64)
        case failure(String)
    }

    /// Runs off the main actor: validates file existence, handles iCloud Drive cloud-only downloads,
    /// and verifies readability in bounded 512 KiB chunks with live progress reporting.
    private nonisolated static func verifyAndReadAttachment(
        url: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async -> AttachmentPrepOutcome {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                return .failure("文件不存在或已被移动")
            }
            if isDir.boolValue {
                return .failure("不支持直接添加文件夹，请压缩为 ZIP 后添加")
            }

            if let values = try? url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemDownloadingErrorKey
            ]), values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                onProgress(0.1, "iCloud 下载中…")
                do {
                    try fm.startDownloadingUbiquitousItem(at: url)
                } catch {
                    return .failure("无法从 iCloud 下载：\(error.localizedDescription)")
                }

                let deadline = Date().addingTimeInterval(60)
                var waitTick = 0
                while Date() < deadline {
                    if Task.isCancelled { return .failure("已取消") }
                    try? await Task.sleep(for: .milliseconds(250))
                    waitTick += 1
                    let current = try? url.resourceValues(forKeys: [
                        .ubiquitousItemDownloadingStatusKey,
                        .ubiquitousItemDownloadingErrorKey
                    ])
                    if let dlErr = current?.ubiquitousItemDownloadingError {
                        return .failure("iCloud 下载失败：\(dlErr.localizedDescription)")
                    }
                    if current?.ubiquitousItemDownloadingStatus == .current {
                        break
                    }
                    let simulated = min(0.55, 0.12 + Double(waitTick) * 0.02)
                    onProgress(simulated, "iCloud 下载中…")
                }
                let finalStatus = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
                if finalStatus != .current {
                    return .failure("iCloud 下载超时，请在访达中下载完成后重试")
                }
            }

            if Task.isCancelled { return .failure("已取消") }

            guard fm.isReadableFile(atPath: url.path) else {
                return .failure("无读取权限，请检查文件权限")
            }

            let fileSize: Int64
            do {
                let attrs = try fm.attributesOfItem(atPath: url.path)
                fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            } catch {
                return .failure("无法读取文件信息：\(error.localizedDescription)")
            }

            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }

                let chunkSize = 512 * 1024
                var bytesRead: Int64 = 0
                var lastReportedProgress: Double = 0.05
                var lastReportTime = Date.distantPast

                while true {
                    if Task.isCancelled { return .failure("已取消") }
                    let chunk = try handle.read(upToCount: chunkSize)
                    guard let chunk, !chunk.isEmpty else { break }
                    bytesRead += Int64(chunk.count)

                    if fileSize > 0 {
                        let ratio = min(0.98, 0.10 + (Double(bytesRead) / Double(fileSize)) * 0.88)
                        let now = Date()
                        if ratio - lastReportedProgress >= 0.05 || now.timeIntervalSince(lastReportTime) >= 0.08 {
                            lastReportedProgress = ratio
                            lastReportTime = now
                            onProgress(ratio, "校验读取中…")
                        }
                    }
                }
                onProgress(1.0, "校验完成")
                return .success(max(fileSize, bytesRead))
            } catch {
                return .failure("文件读取失败：\(error.localizedDescription)")
            }
        }.value
    }

    private nonisolated static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let str = item as? String, let url = URL(string: str) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Send & Save Draft

    func sendMail() {
        guard !draft.isSending else { return }
        draft.showDiscardConfirmation = false
        clearContactSuggestions()
        if draft.isPreparingAttachments {
            showBanner(
                ComposeFeedbackBanner(kind: .info, message: "附件仍在准备中，请等待完成后发送"),
                autoDismissAfter: 3
            )
            return
        }
        if draft.failedAttachmentsCount > 0 {
            showBanner(
                ComposeFeedbackBanner(
                    kind: .error,
                    message: "存在 \(draft.failedAttachmentsCount) 个加载失败的附件",
                    detail: "请点击附件上的刷新按钮重试，或移除失败附件后再发送"
                )
            )
            return
        }
        let toList = parseEmailList(draft.toText)
        guard !toList.isEmpty else {
            showBanner(
                ComposeFeedbackBanner(kind: .warning, message: "请填写至少一个收件人邮箱"),
                autoDismissAfter: 3
            )
            return
        }
        if (accountEmailsCount?() ?? 0) > 0 &&
            draft.fromEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            draft.missingOriginAccountWarning != nil {
            showBanner(
                ComposeFeedbackBanner(kind: .warning, message: "请先选择发件账号再发送"),
                autoDismissAfter: 3
            )
            return
        }
        dispatchToMailApp(toList: toList, shouldSend: true)
    }

    func saveDraft() {
        guard !draft.isSending else { return }
        draft.showDiscardConfirmation = false
        clearContactSuggestions()
        if draft.isPreparingAttachments {
            showBanner(
                ComposeFeedbackBanner(kind: .info, message: "附件仍在准备中，请等待完成后再保存草稿"),
                autoDismissAfter: 3
            )
            return
        }
        if draft.failedAttachmentsCount > 0 {
            showBanner(
                ComposeFeedbackBanner(
                    kind: .error,
                    message: "存在 \(draft.failedAttachmentsCount) 个加载失败的附件",
                    detail: "请先重试或移除失败附件后再保存草稿"
                )
            )
            return
        }
        let toList = parseEmailList(draft.toText)
        dispatchToMailApp(toList: toList, shouldSend: false)
    }

    private func dispatchToMailApp(toList: [String], shouldSend: Bool) {
        let ccList = parseEmailList(draft.ccText)
        let bccList = parseEmailList(draft.bccText)
        polishTask?.cancel()
        polishTask = nil
        draft.isAIPolishing = false

        var missingIndex: Int?
        for idx in draft.attachments.indices {
            let url = draft.attachments[idx].url
            if !FileManager.default.fileExists(atPath: url.path) {
                draft.attachments[idx].status = .failed(reason: "文件已被移动或删除")
                if missingIndex == nil { missingIndex = idx }
            } else if !FileManager.default.isReadableFile(atPath: url.path) {
                draft.attachments[idx].status = .failed(reason: "无读取权限")
                if missingIndex == nil { missingIndex = idx }
            }
        }
        if let missingIndex {
            let item = draft.attachments[missingIndex]
            showBanner(
                ComposeFeedbackBanner(
                    kind: .error,
                    message: "附件「\(item.filename)」无法发送",
                    detail: item.status.failureReason ?? "请重新添加该附件"
                )
            )
            return
        }

        let currentDraft = draft
        let draftID = currentDraft.id
        let attachmentItems = currentDraft.attachments
        let attachmentURLs = attachmentItems.map(\.url)
        let senderHeader = formattedSenderHeader?(currentDraft.fromEmail)

        draft.isSending = true
        if !attachmentURLs.isEmpty {
            draft.sendPhaseLabel = shouldSend ? "附加并发送..." : "附加并保存..."
            for idx in draft.attachments.indices {
                draft.attachments[idx].status = .attaching
            }
            showBanner(
                ComposeFeedbackBanner(
                    kind: .progress(nil),
                    message: shouldSend
                        ? "正在将 \(attachmentURLs.count) 个附件（\(currentDraft.formattedTotalAttachmentSize)）交给系统 Mail.app 发送…"
                        : "正在将 \(attachmentURLs.count) 个附件（\(currentDraft.formattedTotalAttachmentSize)）保存至草稿箱…",
                    detail: "大附件可能需要数秒，请勿关闭窗口"
                )
            )
        } else {
            draft.sendPhaseLabel = shouldSend ? "发送中..." : "保存中..."
            showBanner(
                ComposeFeedbackBanner(
                    kind: .progress(nil),
                    message: shouldSend ? "正在交给系统 Mail.app 发送…" : "正在保存至草稿箱…"
                )
            )
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                if shouldSend {
                    try await MailAppleScriptBridge.sendMessage(
                        from: senderHeader,
                        to: toList,
                        cc: ccList,
                        bcc: bccList,
                        subject: currentDraft.subject.isEmpty ? "(无主题)" : currentDraft.subject,
                        body: currentDraft.body,
                        attachmentURLs: attachmentURLs
                    )
                } else {
                    try await MailAppleScriptBridge.saveDraft(
                        from: senderHeader,
                        to: toList,
                        cc: ccList,
                        bcc: bccList,
                        subject: currentDraft.subject.isEmpty ? "(无主题)" : currentDraft.subject,
                        body: currentDraft.body,
                        attachmentURLs: attachmentURLs
                    )
                }
                if self.draft.id == draftID {
                    for idx in self.draft.attachments.indices {
                        self.draft.attachments[idx].status = .attached
                    }
                    self.draft.isSending = false
                    self.draft.sendPhaseLabel = nil
                    self.dismissBanner()
                    self.isPresented = false
                }
                let attachNote = attachmentURLs.isEmpty ? "" : "（含 \(attachmentURLs.count) 个附件）"
                self.onShowToast?(shouldSend ? "已交给系统 Mail.app 发送\(attachNote)" : "已保存至草稿箱\(attachNote)")
            } catch let attachErr as MailComposeAttachmentError {
                if self.draft.id == draftID {
                    self.restoreAttachingStatuses(failedIndex: attachErr.attachmentIndex, reason: attachErr.shortReason)
                    self.draft.isSending = false
                    self.draft.sendPhaseLabel = nil
                    self.showBanner(
                        ComposeFeedbackBanner(
                            kind: .error,
                            message: shouldSend ? "附件附加失败，邮件未发送" : "附件附加失败，草稿未保存",
                            detail: attachErr.localizedDescription
                        )
                    )
                }
            } catch {
                if self.draft.id == draftID {
                    self.restoreAttachingStatuses(failedIndex: nil, reason: nil)
                    self.draft.isSending = false
                    self.draft.sendPhaseLabel = nil
                    self.showBanner(
                        ComposeFeedbackBanner(
                            kind: .error,
                            message: shouldSend ? "发送失败（草稿内容已保留）" : "保存草稿失败",
                            detail: error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    private func restoreAttachingStatuses(failedIndex: Int?, reason: String?) {
        for idx in draft.attachments.indices {
            if let failedIndex, idx == failedIndex {
                draft.attachments[idx].status = .failed(reason: reason ?? "添加附件失败")
            } else if draft.attachments[idx].status.isAttaching {
                draft.attachments[idx].status = .ready(sizeBytes: draft.attachments[idx].sizeBytes ?? 0)
            }
        }
    }

    // MARK: - AI Polish

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
                    self.showBanner(
                        ComposeFeedbackBanner(
                            kind: .error,
                            message: "AI 润色失败",
                            detail: error.localizedDescription
                        )
                    )
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
        showBanner(
            ComposeFeedbackBanner(kind: .success, message: "已采纳 AI 润色内容"),
            autoDismissAfter: 3
        )
    }

    func discardPendingAIPolish() {
        polishTask?.cancel()
        polishTask = nil
        draft.isAIPolishing = false
        draft.pendingAIPolish = nil
        draft.polishBaseRevision = nil
    }

    // MARK: - Helpers

    private func resetTasksForNewDraft() {
        polishTask?.cancel()
        polishTask = nil
        forwardImportTask?.cancel()
        forwardImportTask = nil
        contactSearchTask?.cancel()
        contactSearchTask = nil
        cancelAllAttachmentTasks()
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        activeRecipientField = nil
        contactSuggestions = []
    }

    private func cancelAllAttachmentTasks() {
        for (_, task) in attachmentTasks {
            task.cancel()
        }
        attachmentTasks.removeAll()
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
