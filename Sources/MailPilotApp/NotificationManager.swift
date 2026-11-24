import AppKit
import Foundation
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import UserNotifications

/// Manages native macOS desktop notifications for incoming mail detected via FSEvents.
@MainActor
final class NotificationManager: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onSelectMessage: ((Int64) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async -> UNAuthorizationStatus {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return await authorizationStatus()
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }

    func notifyNewMail(message: MailMessageSummary, verificationCode: String?) {
        let content = UNMutableNotificationContent()
        content.title = message.displaySender
        content.subtitle = message.subject
        if let code = verificationCode, !code.isEmpty {
            content.body = "🔑 验证码：\(code)（\(message.mailboxName)）"
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
        center.add(request)
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
        center.add(request)
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
        center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
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
