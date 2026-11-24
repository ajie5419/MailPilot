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
        Task { [weak self] in
            let maxID = await Task.detached(priority: .utility) {
                (try? reader.fetchMaxInboxRowID()) ?? 0
            }.value
            self?.lastSeenMaxRowID = maxID
        }
    }

    func checkAndNotifyIncomingMail() async {
        guard notificationsEnabled, let reader else { return }
        guard let watermark = lastSeenMaxRowID else {
            let maxID = await Task.detached(priority: .utility) {
                (try? reader.fetchMaxInboxRowID()) ?? 0
            }.value
            lastSeenMaxRowID = maxID
            return
        }

        // Query directly by `m.ROWID > watermark` in SQL so burst arrivals (>25) or older-dated imports are never skipped (F16).
        let newlyArrived = await Task.detached(priority: .userInitiated) {
            (try? reader.fetchUnreadInboxMessages(afterRowID: watermark, limit: 100)) ?? []
        }.value
        guard !newlyArrived.isEmpty else { return }

        if let maxID = newlyArrived.map(\.id).max() {
            lastSeenMaxRowID = max(watermark, maxID)
        }

        if newlyArrived.count > 3, let latest = newlyArrived.last {
            notificationManager.notifyBatchSummary(count: newlyArrived.count, latest: latest)
            return
        }

        for msg in newlyArrived {
            var code: String?
            if let parser = emlxParser {
                let body = await parser.loadBody(for: msg.id)
                if body.loadStatus == .ready {
                    code = body.verificationCode
                }
            }
            notificationManager.notifyNewMail(message: msg, verificationCode: code)
        }
    }

    func requestNotificationPermissionOnLaunch() {
        Task {
            let status = await notificationManager.requestAuthorization()
            self.notificationAuthStatusText = formatAuthStatus(status)
        }
    }

    func refreshNotificationStatus() {
        Task {
            let status = await notificationManager.authorizationStatus()
            self.notificationAuthStatusText = formatAuthStatus(status)
        }
    }

    func sendTestNotification() {
        Task {
            let status = await notificationManager.requestAuthorization()
            self.notificationAuthStatusText = formatAuthStatus(status)
            if status == .authorized || status == .provisional {
                self.notificationManager.sendTestNotification()
                self.showToast("已发送测试通知")
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

    private func formatAuthStatus(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已授权"
        case .provisional: return "临时授权"
        case .denied: return "已拒绝（请在系统设置中开启）"
        case .notDetermined: return "未授权"
        @unknown default: return "未知"
        }
    }
}
