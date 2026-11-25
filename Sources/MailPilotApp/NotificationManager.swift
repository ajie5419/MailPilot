import AppKit
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import OSLog
import UserNotifications

/// Manages native macOS desktop notifications and Dock unread badge synchronization.
@MainActor
final class NotificationManager: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.mailpilot.app", category: "notifications")
    private var badgeGeneration: UInt64 = 0
    var onSelectMessage: ((Int64) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async -> UNNotificationSettings {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
        }
        return await notificationSettings()
    }

    func notificationSettings() async -> UNNotificationSettings {
        await center.notificationSettings()
    }

    /// Synchronizes both AppKit's `NSApp.dockTile.badgeLabel` and `UNUserNotificationCenter`'s badge count
    /// so the red Dock badge stays accurate across macOS versions, app launches, and background updates.
    func syncBadgeCount(_ count: Int) {
        let clamped = max(0, count)
        applyAppKitDockBadge(clamped)

        badgeGeneration &+= 1
        let generation = badgeGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.center.setBadgeCount(clamped)
            } catch {
                self.logger.debug("UNUserNotificationCenter.setBadgeCount(\(clamped)) skipped: \(error.localizedDescription, privacy: .public)")
            }
            if self.badgeGeneration == generation {
                self.applyAppKitDockBadge(clamped)
            }
        }
    }

    private func applyAppKitDockBadge(_ count: Int) {
        guard let app = NSApp else { return }
        app.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        app.dockTile.display()
    }

    func notifyNewMail(message: MailMessageSummary, verificationCode: String?) {
        let content = UNMutableNotificationContent()
        content.title = message.displaySender
        content.subtitle = message.subject
        if let code = verificationCode, !code.isEmpty {
            content.body = "验证码：\(code)（\(message.mailboxName)）"
        } else {
            content.body = "收到新邮件 · \(message.mailboxName)"
        }
        content.sound = .default
        content.userInfo = ["rowID": message.id]

        let request = UNNotificationRequest(
            identifier: "mailpilot-msg-\(message.id)",
            content: content,
            trigger: nil
        )
        enqueueRequest(request)
    }

    func notifyBatchSummary(count: Int, latest: MailMessageSummary) {
        let content = UNMutableNotificationContent()
        content.title = "收到 \(count) 封新邮件"
        content.subtitle = "\(latest.displaySender)：\(latest.subject)"
        content.body = "点击查看最新邮件"
        content.sound = .default
        content.userInfo = ["rowID": latest.id]

        let request = UNNotificationRequest(
            identifier: "mailpilot-batch-\(latest.id)",
            content: content,
            trigger: nil
        )
        enqueueRequest(request)
    }

    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "MailPilot 通知已就绪"
        content.subtitle = "新邮件桌面提醒测试"
        content.body = "现在可以放心关闭系统 Mail.app 的通知，由 MailPilot 统一提醒。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "mailpilot-test-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        enqueueRequest(request)
    }

    func removeDeliveredNotification(for rowID: Int64) {
        center.removeDeliveredNotifications(withIdentifiers: ["mailpilot-msg-\(rowID)"])
    }

    private func enqueueRequest(_ request: UNNotificationRequest) {
        let identifier = request.identifier
        center.add(request) { [logger] error in
            if let error {
                logger.error("Failed to deliver notification \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        NSApp.activate(ignoringOtherApps: true)
        if let rowID = response.notification.request.content.userInfo["rowID"] as? Int64 {
            onSelectMessage?(rowID)
        } else if let num = response.notification.request.content.userInfo["rowID"] as? NSNumber {
            onSelectMessage?(num.int64Value)
        }
    }
}
