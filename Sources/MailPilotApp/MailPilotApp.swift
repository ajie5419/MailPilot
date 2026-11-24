import AppKit
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

final class MailPilotAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct MailPilotApp: App {
    @NSApplicationDelegateAdaptor(MailPilotAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("MailPilot") {
            ContentView(viewModel: viewModel)
                .frame(
                    minWidth: viewModel.accessError != nil ? 460 : 880,
                    minHeight: viewModel.accessError != nil ? 450 : 560
                )
                .onAppear {
                    resizeMainWindow(isOnboarding: viewModel.accessError != nil, animate: false)
                }
                .onChange(of: viewModel.accessError == nil) { _, isAuthorized in
                    resizeMainWindow(isOnboarding: !isAuthorized, animate: true)
                }
                .sheet(isPresented: $viewModel.showSettings) {
                    SettingsSheetContainer(viewModel: viewModel)
                }
                .sheet(isPresented: $viewModel.showComposeSheet) {
                    ComposeMailSheet(viewModel: viewModel)
                }
        }
        .defaultSize(width: 460, height: 470)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置与 AI 订阅登录...") {
                    viewModel.showSettings = true
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(replacing: .newItem) {
                Button("写新邮件") {
                    viewModel.openComposeNew()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("回复当前邮件") {
                    viewModel.openComposeReply()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(viewModel.selectedMessage == nil)

                Button("转发当前邮件") {
                    viewModel.openComposeForward()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(viewModel.selectedMessage == nil)

                Divider()

                Button("归档当前邮件") {
                    if let msg = viewModel.selectedMessage {
                        viewModel.archiveMessage(msg)
                    }
                }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled(viewModel.selectedMessage == nil)

                Button("删除当前邮件") {
                    if let msg = viewModel.selectedMessage {
                        viewModel.deleteMessage(msg)
                    }
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(viewModel.selectedMessage == nil)
            }
            CommandGroup(after: .appSettings) {
                Button("刷新邮件索引") {
                    viewModel.refreshNow()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("触发 Mail.app 收信") {
                    viewModel.triggerNativeMailFetch()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("展开/收起 AI 对话抽屉") {
                    viewModel.showAIPanel.toggle()
                }
                .keyboardShortcut("j", modifiers: [.command])
            }
        }

        Settings {
            SettingsView(viewModel: viewModel)
                .frame(width: 720, height: 520)
        }
    }

    @MainActor
    private func resizeMainWindow(isOnboarding: Bool, animate: Bool) {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet })
                    ?? NSApp.keyWindow
                    ?? NSApp.windows.first else {
                return
            }
            let targetSize = isOnboarding ? NSSize(width: 460, height: 470) : NSSize(width: 1120, height: 700)
            let current = window.frame
            let newOrigin = NSPoint(
                x: current.midX - targetSize.width / 2,
                y: current.midY - targetSize.height / 2
            )
            let targetFrame = NSRect(origin: newOrigin, size: targetSize)
            window.setFrame(targetFrame, display: true, animate: animate)
            if !animate {
                window.center()
            }
        }
    }
}

private struct SettingsSheetContainer: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("偏好设置", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    viewModel.showSettings = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            SettingsView(viewModel: viewModel)
        }
        .frame(width: 720, height: 540)
    }
}
