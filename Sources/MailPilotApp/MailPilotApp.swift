import AppKit
#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

final class MailPilotAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    @MainActor static weak var shared: MailPilotAppDelegate?
    @MainActor private weak var mainWindow: NSWindow?
    @MainActor private weak var boundViewModel: AppViewModel?
    @MainActor private var closeInterceptor: WindowCloseInterceptor?
    @MainActor private var isQuitting = false

    // Menu Bar Status Item + Frosted Glass Popover
    @MainActor private var statusItem: NSStatusItem?
    @MainActor private var statusPopover: NSPopover?
    @MainActor private var popoverClickMonitor: Any?
    @MainActor private var lastMenuBarVisible = false
    @MainActor private var lastMenuBarUnreadCount = 0
    @MainActor var onMenuBarCompose: (() -> Void)?
    @MainActor var onMenuBarCheckMail: (() -> Void)?

    // Standalone behindWindow Liquid-Glass Settings Window
    @MainActor private var settingsWindow: NSWindow?
    @MainActor private var settingsWindowDelegate: SettingsWindowDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.shared = self
            applyMenuBarStatusItem()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func bind(viewModel: AppViewModel) {
        boundViewModel = viewModel
    }

    @MainActor
    func isSettingsWindow(_ window: NSWindow) -> Bool {
        settingsWindow === window
    }

    // MARK: - Menu Bar Status Item & Popover

    @MainActor
    func updateMenuBarStatus(visible: Bool, unreadCount: Int) {
        lastMenuBarVisible = visible
        lastMenuBarUnreadCount = max(0, unreadCount)
        applyMenuBarStatusItem()
    }

    @MainActor
    private func applyMenuBarStatusItem() {
        guard lastMenuBarVisible else {
            closeStatusPopover()
            if let existing = statusItem {
                NSStatusBar.system.removeStatusItem(existing)
                statusItem = nil
            }
            return
        }

        let item: NSStatusItem
        if let existing = statusItem {
            item = existing
        } else {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
        }

        if let button = item.button {
            button.image = CraneTemplateIconRenderer.menuBarIcon()
            button.imagePosition = lastMenuBarUnreadCount > 0 ? .imageLeading : .imageOnly
            button.title = lastMenuBarUnreadCount > 0 ? " \(lastMenuBarUnreadCount)" : ""
            button.toolTip = lastMenuBarUnreadCount > 0
                ? "MailPilot · \(lastMenuBarUnreadCount) 封未读邮件"
                : "MailPilot · 收件箱全部已读"
            button.target = self
            button.action = #selector(handleStatusBarButtonClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        item.menu = nil
    }

    @MainActor @objc private func handleStatusBarButtonClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closeStatusPopover()
            showStatusContextMenu(from: sender)
            return
        }
        toggleStatusPopover(relativeTo: sender)
    }

    @MainActor
    private func showStatusContextMenu(from button: NSStatusBarButton) {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let statusTitle = lastMenuBarUnreadCount > 0
            ? "收件箱未读：\(lastMenuBarUnreadCount) 封"
            : "收件箱暂无未读邮件"
        let headerItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "打开 MailPilot", action: #selector(handleMenuBarOpen), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let composeItem = NSMenuItem(title: "写新邮件", action: #selector(handleMenuBarCompose), keyEquivalent: "")
        composeItem.target = self
        menu.addItem(composeItem)

        let checkItem = NSMenuItem(title: "立即检查新邮件", action: #selector(handleMenuBarCheckMail), keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)

        let settingsItem = NSMenuItem(title: "偏好设置…", action: #selector(handleMenuBarSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 MailPilot", action: #selector(handleMenuBarQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    @MainActor
    private func toggleStatusPopover(relativeTo button: NSStatusBarButton) {
        if let popover = statusPopover, popover.isShown {
            closeStatusPopover()
            return
        }
        guard let viewModel = boundViewModel else {
            showMainWindow()
            return
        }

        viewModel.refreshMenuBarUnreadPreview()

        let popover = statusPopover ?? {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = true
            p.delegate = self
            statusPopover = p
            return p
        }()

        let rootView = MenuBarPopoverView(
            viewModel: viewModel,
            onOpenMain: { [weak self] in
                self?.closeStatusPopover()
                self?.showMainWindow()
            },
            onSelectMessage: { [weak self] rowID in
                self?.closeStatusPopover()
                viewModel.openMessageFromMenuBar(rowID)
            },
            onCompose: { [weak self] in
                self?.closeStatusPopover()
                self?.showMainWindow()
                self?.onMenuBarCompose?()
            },
            onCheckMail: { [weak self] in
                self?.onMenuBarCheckMail?()
                viewModel.refreshMenuBarUnreadPreview()
            },
            onOpenSettings: { [weak self] in
                self?.closeStatusPopover()
                viewModel.showSettings = true
                self?.setSettingsWindowVisible(true, viewModel: viewModel)
            },
            onQuit: { [weak self] in
                self?.closeStatusPopover()
                NSApp.terminate(nil)
            }
        )

        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        installPopoverOutsideClickMonitor()
    }

    @MainActor
    private func closeStatusPopover() {
        statusPopover?.performClose(nil)
        removePopoverOutsideClickMonitor()
    }

    @MainActor
    private func installPopoverOutsideClickMonitor() {
        removePopoverOutsideClickMonitor()
        popoverClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closeStatusPopover()
            }
        }
    }

    @MainActor
    private func removePopoverOutsideClickMonitor() {
        if let monitor = popoverClickMonitor {
            NSEvent.removeMonitor(monitor)
            popoverClickMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            removePopoverOutsideClickMonitor()
        }
    }

    @MainActor @objc private func handleMenuBarOpen() {
        showMainWindow()
    }

    @MainActor @objc private func handleMenuBarCompose() {
        showMainWindow()
        onMenuBarCompose?()
    }

    @MainActor @objc private func handleMenuBarCheckMail() {
        onMenuBarCheckMail?()
    }

    @MainActor @objc private func handleMenuBarSettings() {
        guard let viewModel = boundViewModel else { return }
        viewModel.showSettings = true
        setSettingsWindowVisible(true, viewModel: viewModel)
    }

    @MainActor @objc private func handleMenuBarQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Standalone Liquid-Glass Settings Window

    @MainActor
    func setSettingsWindowVisible(_ visible: Bool, viewModel: AppViewModel) {
        boundViewModel = viewModel
        if !visible {
            if let window = settingsWindow, window.isVisible {
                window.orderOut(nil)
            }
            return
        }

        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            let hosting = NSHostingController(
                rootView: SettingsView(viewModel: viewModel)
                    .ignoresSafeArea(.container, edges: .top)
            )
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 790, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            created.title = "MailPilot 设置"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.isMovableByWindowBackground = true
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 680, height: 480)
            created.contentViewController = hosting
            created.center()

            let delegate = SettingsWindowDelegate { [weak viewModel] in
                Task { @MainActor in
                    viewModel?.showSettings = false
                }
            }
            settingsWindowDelegate = delegate
            created.delegate = delegate
            settingsWindow = created
            window = created
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Application Lifecycle & Main Window

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            isQuitting = true
            closeInterceptor?.isQuitting = true
            removePopoverOutsideClickMonitor()
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
        guard !isSettingsWindow(window), mainWindow !== window else { return }
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
        guard let window = mainWindow ?? NSApp.windows.first(where: { !$0.isSheet && $0.canBecomeMain && !isSettingsWindow($0) }) else {
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
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
                    MailPilotAppDelegate.shared?.setSettingsWindowVisible(true, viewModel: viewModel)
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

                Button("全部回复") {
                    viewModel.openComposeReplyAll()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
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
                Button("搜索邮件") {
                    viewModel.focusSearchField()
                }
                .keyboardShortcut("f", modifiers: [.command])

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
                .frame(width: 790, height: 580)
        }
    }

    @MainActor
    private func configureMainWindow(isOnboarding: Bool, animate: Bool) {
        DispatchQueue.main.async {
            let delegate = MailPilotAppDelegate.shared
            guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet && $0.canBecomeMain && !(delegate?.isSettingsWindow($0) ?? false) })
                    ?? NSApp.windows.first(where: { !$0.isSheet && $0.canBecomeMain && !(delegate?.isSettingsWindow($0) ?? false) }) else {
                return
            }
            delegate?.registerMainWindow(window)

            // Apply Canapé-style frameless frosted-glass chrome during onboarding;
            // restore crisp native macOS toolbar chrome once authorized.
            if isOnboarding {
                window.styleMask.insert(.fullSizeContentView)
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
                window.isOpaque = false
                window.backgroundColor = .clear
            } else {
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                window.isMovableByWindowBackground = false
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
            }

            let targetSize = isOnboarding ? NSSize(width: 468, height: 536) : NSSize(width: 1120, height: 700)
            let current = window.frame
            let needsResize = isOnboarding
                ? (abs(current.width - targetSize.width) > 36 || abs(current.height - targetSize.height) > 36)
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
                minHeight: viewModel.accessError != nil ? 520 : 560
            )
            .onAppear {
                MailPilotAppDelegate.shared?.bind(viewModel: viewModel)
                configureMainWindow(viewModel.accessError != nil, false)
            }
            .onChange(of: viewModel.accessError == nil) { _, isAuthorized in
                configureMainWindow(!isAuthorized, true)
            }
            .onChange(of: viewModel.showSettings) { _, isVisible in
                MailPilotAppDelegate.shared?.setSettingsWindowVisible(isVisible, viewModel: viewModel)
            }
            .sheet(isPresented: $compose.isPresented) {
                ComposeMailSheet(viewModel: viewModel)
            }
    }
}
