import AppKit
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

final class MailPilotAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var shared: MailPilotAppDelegate?
    @MainActor private weak var mainWindow: NSWindow?
    @MainActor private var closeInterceptor: WindowCloseInterceptor?
    @MainActor private var isQuitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.shared = self
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            isQuitting = true
            closeInterceptor?.isQuitting = true
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !flag, let window = mainWindow {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return false
            }
            return true
        }
    }

    @MainActor
    func registerMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        // Intercept red close button (`⌘W` / `×`) to hide the window via `orderOut` instead of destroying
        // the SwiftUI view tree & WKWebView, making reopening from Dock instantaneous (<16ms).
        if !(window.delegate is WindowCloseInterceptor) {
            let proxy = WindowCloseInterceptor(forwardingTo: window.delegate)
            proxy.isQuitting = isQuitting
            closeInterceptor = proxy
            window.delegate = proxy
        }
    }

    @MainActor
    func showMainWindow() {
        guard let window = mainWindow ?? NSApp.windows.first(where: { !$0.isSheet && $0.canBecomeMain }) else {
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Forwarding `NSWindowDelegate` proxy that keeps SwiftUI's internal delegate intact while hiding
/// the main window on close (`orderOut`) instead of tearing down WebKit & SwiftUI state.
private final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    private weak var originalDelegate: NSWindowDelegate?
    var isQuitting = false

    init(forwardingTo delegate: NSWindowDelegate?) {
        self.originalDelegate = delegate
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original = originalDelegate, original.responds(to: aSelector) {
            return original
        }
        return super.forwardingTarget(for: aSelector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isQuitting {
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }
        guard sender.attachedSheet == nil else {
            return false
        }
        sender.orderOut(nil)
        return false
    }
}

@main
struct MailPilotApp: App {
    @NSApplicationDelegateAdaptor(MailPilotAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("MailPilot") {
            MainWindowRoot(
                viewModel: viewModel,
                compose: viewModel.compose,
                configureMainWindow: configureMainWindow
            )
        }
        .defaultSize(width: 1120, height: 700)
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
    private func configureMainWindow(isOnboarding: Bool, animate: Bool) {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet && $0.canBecomeMain })
                    ?? NSApp.keyWindow
                    ?? NSApp.windows.first(where: { !$0.isSheet && $0.canBecomeMain }) else {
                return
            }
            MailPilotAppDelegate.shared?.registerMainWindow(window)

            let targetSize = isOnboarding ? NSSize(width: 460, height: 470) : NSSize(width: 1120, height: 700)
            let current = window.frame
            let needsResize = isOnboarding
                ? (abs(current.width - targetSize.width) > 40 || abs(current.height - targetSize.height) > 40)
                : (current.width < 880 || current.height < 560)
            guard needsResize else { return }

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

private struct MainWindowRoot: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var compose: ComposeCoordinator
    let configureMainWindow: @MainActor (Bool, Bool) -> Void

    var body: some View {
        ContentView(viewModel: viewModel)
            .frame(
                minWidth: viewModel.accessError != nil ? 460 : 880,
                minHeight: viewModel.accessError != nil ? 450 : 560
            )
            .onAppear {
                configureMainWindow(viewModel.accessError != nil, false)
            }
            .onChange(of: viewModel.accessError == nil) { _, isAuthorized in
                configureMainWindow(!isAuthorized, true)
            }
            .sheet(isPresented: $viewModel.showSettings) {
                SettingsSheetContainer(viewModel: viewModel)
            }
            .sheet(isPresented: $compose.isPresented) {
                ComposeMailSheet(viewModel: viewModel)
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
