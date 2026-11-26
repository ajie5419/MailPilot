import AppKit
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import UserNotifications

extension AppViewModel {
    // MARK: - Incoming Mail Watermark & Notifications

    func seedInitialRowIDWatermark() {
        guard let reader else { return }
        hasSeededNotificationWatermark = false
        notifiedMessageIDs.removeAll()
        Task { [weak self] in
            let seedResult: (maxID: Int64, recentUnreadIDs: [Int64])? = await Task.detached(priority: .utility) {
                guard let maxID = try? reader.fetchMaxInboxRowID() else { return nil }
                let lookbackStart = max(0, maxID - 200)
                let existingUnread = (try? reader.fetchUnreadInboxMessages(afterRowID: lookbackStart, limit: 200)) ?? []
                return (maxID, existingUnread.map(\.id))
            }.value
            guard let self else { return }
            if let seedResult {
                self.lastSeenMaxRowID = seedResult.maxID
                self.notifiedMessageIDs = Set(seedResult.recentUnreadIDs)
                self.hasSeededNotificationWatermark = true
            }
        }
    }

    func checkAndNotifyIncomingMail() async {
        guard notificationsEnabled, let reader else { return }

        // Prevent overlapping checks from firing duplicate notifications during WAL write bursts.
        if isCheckingIncomingNotifications {
            needsFollowUpNotificationCheck = true
            return
        }
        isCheckingIncomingNotifications = true
        needsFollowUpNotificationCheck = false
        defer {
            isCheckingIncomingNotifications = false
            if needsFollowUpNotificationCheck {
                needsFollowUpNotificationCheck = false
                Task { [weak self] in
                    await self?.checkAndNotifyIncomingMail()
                }
            }
        }

        if !hasSeededNotificationWatermark || lastSeenMaxRowID == nil {
            let seedResult: (maxID: Int64, recentUnreadIDs: [Int64])? = await Task.detached(priority: .utility) {
                guard let maxID = try? reader.fetchMaxInboxRowID() else { return nil }
                let lookbackStart = max(0, maxID - 200)
                let existingUnread = (try? reader.fetchUnreadInboxMessages(afterRowID: lookbackStart, limit: 200)) ?? []
                return (maxID, existingUnread.map(\.id))
            }.value
            if let seedResult {
                lastSeenMaxRowID = seedResult.maxID
                notifiedMessageIDs.formUnion(seedResult.recentUnreadIDs)
                hasSeededNotificationWatermark = true
            }
            return
        }

        guard let watermark = lastSeenMaxRowID else { return }

        // Look back slightly behind `watermark` and deduplicate via `notifiedMessageIDs` so
        // Gmail/IMAP messages whose `labels` row arrives slightly after a higher ROWID are never skipped.
        let queryAfterRowID = max(0, watermark - 50)
        let fetched: [MailMessageSummary]? = await Task.detached(priority: .userInitiated) {
            try? reader.fetchUnreadInboxMessages(afterRowID: queryAfterRowID, limit: 150)
        }.value
        guard let fetched else { return }

        let newlyArrived = fetched.filter { !notifiedMessageIDs.contains($0.id) }
        guard !newlyArrived.isEmpty else { return }

        for msg in newlyArrived {
            notifiedMessageIDs.insert(msg.id)
        }
        if let maxID = newlyArrived.map(\.id).max() {
            lastSeenMaxRowID = max(watermark, maxID)
        }
        // Keep the deduplication set bounded while always covering recent ROWIDs.
        if notifiedMessageIDs.count > 1000 {
            let cutoff = (lastSeenMaxRowID ?? 0) - 500
            notifiedMessageIDs = notifiedMessageIDs.filter { $0 >= cutoff }
        }

        if newlyArrived.count > 3, let latest = newlyArrived.last {
            notificationManager.notifyBatchSummary(count: newlyArrived.count, latest: latest)
            return
        }

        for msg in newlyArrived {
            var code = EmlxParser.extractVerificationCode(from: msg.subject)
            if code == nil, let parser = emlxParser {
                let body = await parser.loadBody(for: msg.id)
                if body.loadStatus == .ready {
                    code = body.verificationCode
                }
            }
            if let code, !code.isEmpty {
                recordIncomingVerificationCode(code, for: msg)
            }
            notificationManager.notifyNewMail(message: msg, verificationCode: code)
        }
    }

    func requestNotificationPermissionOnLaunch() {
        Task {
            let settings = await notificationManager.requestAuthorization()
            self.notificationAuthStatusText = formatAuthStatus(settings)
            self.updateDockUnreadBadge()
        }
    }

    func refreshNotificationStatus() {
        Task {
            let settings = await notificationManager.notificationSettings()
            self.notificationAuthStatusText = formatAuthStatus(settings)
        }
    }

    func sendTestNotification() {
        Task {
            let settings = await notificationManager.requestAuthorization()
            self.notificationAuthStatusText = formatAuthStatus(settings)
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                self.notificationManager.sendTestNotification()
                if settings.alertSetting == .disabled {
                    self.showToast("已发送测试通知，但系统设置中已关闭横幅提醒")
                } else {
                    self.showToast("已发送测试通知")
                }
            } else {
                self.showToast("系统通知权限未开启，请前往系统设置放行 MailPilot")
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func formatAuthStatus(_ settings: UNNotificationSettings) -> String {
        switch settings.authorizationStatus {
        case .authorized:
            var disabled: [String] = []
            if settings.alertSetting == .disabled { disabled.append("横幅已关闭") }
            if settings.badgeSetting == .disabled { disabled.append("角标已关闭") }
            if disabled.isEmpty {
                return "已授权（横幅与角标均已开启）"
            }
            return "已授权，但系统设置中：\(disabled.joined(separator: "、"))"
        case .provisional:
            return "临时授权"
        case .denied:
            return "已拒绝（请在系统设置中开启）"
        case .notDetermined:
            return "未授权"
        @unknown default:
            return "未知"
        }
    }
}
