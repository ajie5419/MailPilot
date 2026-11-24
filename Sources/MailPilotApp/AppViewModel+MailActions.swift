import AppKit
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif

extension AppViewModel {
    // MARK: - Local Optimistic Message Mutations

    func updateLocalReadState(rowID: Int64, isRead: Bool) {
        guard let idx = messages.firstIndex(where: { $0.id == rowID }) else { return }
        let old = messages[idx]
        messages[idx] = MailMessageSummary(
            id: old.id,
            messageIDHeader: old.messageIDHeader,
            subject: old.subject,
            senderAddress: old.senderAddress,
            senderName: old.senderName,
            dateReceived: old.dateReceived,
            isRead: isRead,
            isFlagged: old.isFlagged,
            mailboxID: old.mailboxID,
            mailboxName: old.mailboxName,
            accountID: old.accountID
        )
    }

    func removeMessageLocally(rowID: Int64) {
        guard let idx = messages.firstIndex(where: { $0.id == rowID }) else { return }
        messages.remove(at: idx)
        if selectedMessageID == rowID {
            if idx < messages.count {
                selectedMessageID = messages[idx].id
            } else {
                selectedMessageID = messages.last?.id
            }
        }
    }

    // MARK: - Apple Mail Write Actions

    func triggerNativeMailFetch() {
        Task {
            do {
                try await MailAppleScriptBridge.triggerCheckForNewMail()
                showToast("已通知系统 Mail.app 立即收信")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func toggleReadStatus(for message: MailMessageSummary) {
        let nextState = !message.isRead
        updateLocalReadState(rowID: message.id, isRead: nextState)
        Task {
            do {
                try await MailAppleScriptBridge.setReadStatus(rowID: message.id, isRead: nextState)
                showToast(nextState ? "已标记为已读" : "已标记为未读")
                try? await Task.sleep(for: .milliseconds(400))
                refreshNow()
            } catch {
                updateLocalReadState(rowID: message.id, isRead: message.isRead)
                showToast(error.localizedDescription)
            }
        }
    }

    func toggleFlaggedStatus(for message: MailMessageSummary) {
        let nextState = !message.isFlagged
        Task {
            do {
                try await MailAppleScriptBridge.setFlaggedStatus(rowID: message.id, isFlagged: nextState)
                showToast(nextState ? "已添加旗标" : "已取消旗标")
                try? await Task.sleep(for: .milliseconds(400))
                refreshNow()
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func openInNativeMail(_ message: MailMessageSummary) {
        Task {
            do {
                try await MailAppleScriptBridge.openInMailApp(rowID: message.id)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    // MARK: - Batch & Single Archive / Delete

    func clearMultiSelection() {
        if let current = selectedMessageID {
            selectedMessageIDs = [current]
        } else {
            selectedMessageIDs.removeAll()
        }
    }

    func batchMarkSelected(isRead: Bool) {
        let targets = messages.filter { selectedMessageIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        for msg in targets {
            updateLocalReadState(rowID: msg.id, isRead: isRead)
        }
        let ids = targets.map(\.id)
        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            for id in ids {
                do {
                    try await MailAppleScriptBridge.setReadStatus(rowID: id, isRead: isRead)
                } catch {
                    failed += 1
                }
            }
            if failed == 0 {
                self.showToast("已批量标记 \(ids.count) 封为\(isRead ? "已读" : "未读")")
            } else {
                self.showToast("批量更新完成（\(failed) 封失败）")
            }
            self.refreshNow()
        }
    }

    func batchArchiveSelected() {
        let targets = messages.filter { selectedMessageIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        for id in ids {
            pendingRemovedIDs.insert(id)
            removeMessageLocally(rowID: id)
        }
        selectedMessageIDs = selectedMessageID.map { [$0] } ?? []

        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            for id in ids {
                do {
                    try await MailAppleScriptBridge.archiveMessage(rowID: id)
                } catch {
                    failed += 1
                }
                self.pendingRemovedIDs.remove(id)
            }
            if failed == 0 {
                self.showToast("已批量归档 \(ids.count) 封邮件")
            } else {
                self.reloadMessages()
                self.showToast("批量归档完成（\(failed) 封失败）")
            }
        }
    }

    func batchDeleteSelected() {
        let targets = messages.filter { selectedMessageIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        for id in ids {
            pendingRemovedIDs.insert(id)
            removeMessageLocally(rowID: id)
        }
        selectedMessageIDs = selectedMessageID.map { [$0] } ?? []

        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            var deletedIDs: [Int64] = []
            for id in ids {
                do {
                    try await MailAppleScriptBridge.deleteMessage(rowID: id)
                    deletedIDs.append(id)
                } catch {
                    failed += 1
                }
                self.pendingRemovedIDs.remove(id)
            }
            if !deletedIDs.isEmpty {
                await self.bodyIndex.deleteRowIDs(deletedIDs)
            }
            if failed == 0 {
                self.showToast("已批量删除 \(ids.count) 封邮件")
            } else {
                self.reloadMessages()
                self.showToast("批量删除完成（\(failed) 封失败）")
            }
        }
    }

    func deleteMessage(_ message: MailMessageSummary) {
        pendingRemovedIDs.insert(message.id)
        removeMessageLocally(rowID: message.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await MailAppleScriptBridge.deleteMessage(rowID: message.id)
                self.pendingRemovedIDs.remove(message.id)
                await self.bodyIndex.deleteRowIDs([message.id])
                self.showToast("已移入废纸篓")
            } catch {
                self.pendingRemovedIDs.remove(message.id)
                self.reloadMessages()
                self.showToast("删除失败：\(error.localizedDescription)")
            }
        }
    }

    func archiveMessage(_ message: MailMessageSummary) {
        pendingRemovedIDs.insert(message.id)
        removeMessageLocally(rowID: message.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await MailAppleScriptBridge.archiveMessage(rowID: message.id)
                self.pendingRemovedIDs.remove(message.id)
                self.showToast("已归档")
            } catch {
                self.pendingRemovedIDs.remove(message.id)
                self.reloadMessages()
                self.showToast("归档失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Attachment Actions

    func materializeAttachmentURL(_ attachment: MailAttachment) -> URL? {
        if let local = attachment.localFileURL, FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        guard let data = EmlxParser.decodeAttachmentData(attachment) else { return nil }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = caches
            .appendingPathComponent("MailPilot/Attachments", isDirectory: true)
            .appendingPathComponent("\(selectedMessageID ?? 0)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let safeName = attachment.filename.replacingOccurrences(of: "/", with: "_")
        let targetURL = folder.appendingPathComponent(safeName)
        do {
            try data.write(to: targetURL, options: .atomic)
            return targetURL
        } catch {
            showToast("导出附件失败：\(error.localizedDescription)")
            return nil
        }
    }

    func openAttachment(_ attachment: MailAttachment) {
        guard let url = materializeAttachmentURL(attachment) else {
            showToast("无法打开附件：本地文件尚未缓存")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealAttachmentInFinder(_ attachment: MailAttachment) {
        guard let url = materializeAttachmentURL(attachment) else {
            showToast("无法定位附件")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func saveAttachmentAs(_ attachment: MailAttachment) {
        guard let sourceURL = materializeAttachmentURL(attachment) else {
            showToast("无法保存附件")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        if panel.runModal() == .OK, let dest = panel.url {
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: sourceURL, to: dest)
                showToast("已保存附件到 \(dest.lastPathComponent)")
            } catch {
                showToast("保存失败：\(error.localizedDescription)")
            }
        }
    }
}
