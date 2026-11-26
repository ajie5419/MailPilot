#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var ai: AIAssistantController
    @ObservedObject var bodyIndex: BodyIndexCoordinator
    @Environment(\.colorScheme) var colorScheme

    init(viewModel: AppViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._ai = ObservedObject(wrappedValue: viewModel.ai)
        self._bodyIndex = ObservedObject(wrappedValue: viewModel.bodyIndex)
    }

    var appVersionLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.5.1"
    }

    var body: some View {
        ZStack {
            // Native macOS behindWindow liquid-glass refraction
            VisualEffectBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)

            HStack(spacing: 0) {
                glassSidebar
                glassDetailPane
            }
        }
        .tint(BrandPalette.coral)
        .onAppear {
            ai.refreshAuthStatuses()
            viewModel.refreshNotificationStatus()
        }
        .sheet(isPresented: $viewModel.showIconPickerSheet) {
            AccountIconPickerSheet(viewModel: viewModel)
        }
    }

    // MARK: - Translucent Glass Sidebar (Canapé-inspired grouped icon badges)

    private var glassSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Space beneath transparent window traffic lights
            Spacer().frame(height: 28)

            sidebarGroup(title: "核心配置", tabs: [.ai, .accounts, .tags])
            sidebarGroup(title: "显示与提醒", tabs: [.notifications])
            sidebarGroup(title: "MailPilot", tabs: [.permissions, .about])

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
        .frame(width: 204)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(BrandPalette.sidebarVeil(for: colorScheme))
    }

    private func sidebarGroup(title: String, tabs: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.bottom, 2)

            ForEach(tabs) { tab in
                sidebarRow(for: tab)
            }
        }
    }

    private func sidebarRow(for tab: SettingsTab) -> some View {
        let isSelected = viewModel.settingsTab == tab
        return Button {
            viewModel.settingsTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 23, height: 23)
                    .background(
                        tabColor(tab),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .shadow(color: tabColor(tab).opacity(0.24), radius: 2, y: 1)

                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let pill = sidebarBadgePill(for: tab) {
                    Text(pill.text)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(pill.tint)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(pill.background, in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(pill.tint.opacity(0.24), lineWidth: 0.6)
                        )
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? BrandPalette.sidebarSelectionFill(for: colorScheme) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sidebarBadgePill(for tab: SettingsTab) -> (text: String, tint: Color, background: Color)? {
        switch tab {
        case .permissions:
            if viewModel.accessError == nil {
                return ("已授权", .green, Color.green.opacity(colorScheme == .dark ? 0.16 : 0.12))
            }
            return ("待授权", .orange, Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.14))
        case .about:
            return ("v\(appVersionLabel)", .secondary, BrandPalette.sidebarPillFill(for: colorScheme))
        default:
            return nil
        }
    }

    // MARK: - Right Liquid-Glass Detail Pane

    private var glassDetailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                tabHeaderBar

                switch viewModel.settingsTab {
                case .ai:
                    aiSettingsContent
                case .accounts:
                    accountsSettingsContent
                case .tags:
                    tagSettingsContent
                case .notifications:
                    notificationSettingsContent
                case .permissions:
                    permissionSettingsContent
                case .about:
                    aboutSettingsContent
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 26)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandPalette.detailVeil(for: colorScheme))
    }

    private var tabHeaderBar: some View {
        let tab = viewModel.settingsTab
        return HStack(spacing: 11) {
            Image(systemName: tab.iconName)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    tabColor(tab),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .shadow(color: tabColor(tab).opacity(0.28), radius: 4, y: 2)

            Text(tabHeaderTitle(for: tab))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()

            if tab == .tags {
                Button("恢复默认") {
                    viewModel.resetTagSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.bottom, 2)
    }

    private func tabHeaderTitle(for tab: SettingsTab) -> String {
        switch tab {
        case .ai: return "AI 模型与订阅登录"
        case .accounts: return "邮箱账号设置"
        case .tags: return "智能邮件标签"
        case .notifications: return "通知与状态栏"
        case .permissions: return "隐私与系统权限"
        case .about: return "关于 MailPilot"
        }
    }

    // MARK: - Notifications & Menu Bar Tab (with Hero Live Visual Preview)

    private var notificationSettingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            notificationHeroPreviewCard

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $viewModel.notificationsEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("由 MailPilot 弹出新邮件桌面横幅")
                                .font(.callout.weight(.medium))
                            Text("自动识别验证码并在通知中展示，点击通知直达对应邮件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("系统通知权限状态")
                                .font(.callout)
                            Text(viewModel.notificationAuthStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("发送测试通知") {
                            viewModel.sendTestNotification()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("系统通知设置") {
                            viewModel.openNotificationSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $viewModel.showMenuBarExtra) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("在顶部菜单栏显示千纸鹤图标与未读数")
                                .font(.callout.weight(.medium))
                            Text("左键打开毛玻璃迷你收件箱，随时浏览未读、快速写信或一键回主窗口")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    Toggle(
                        isOn: Binding(
                            get: { viewModel.launchAtLoginEnabled },
                            set: { viewModel.setLaunchAtLogin($0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("登录 macOS 时自动启动 MailPilot")
                                .font(.callout.weight(.medium))
                            Text("使用系统原生 ServiceManagement 注册，随时可在系统设置 → 登录项中管理")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }

            settingsCard {
                Label("开启 MailPilot 通知后，可以在「系统设置 → 通知 → 邮件」中关闭系统 Mail.app 的横幅，避免重复弹窗（只需保持 Mail.app 后台运行不按 ⌘Q 退出即可）。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notificationHeroPreviewCard: some View {
        ZStack {
            // Atmospheric dark macOS desktop stage
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.25, blue: 0.29),
                    Color(red: 0.12, green: 0.19, blue: 0.23),
                    Color(red: 0.11, green: 0.14, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [BrandPalette.coral.opacity(0.22), Color.clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 240
            )

            VStack(spacing: 14) {
                // Mini macOS Menu Bar Preview Strip
                HStack(spacing: 8) {
                    Circle().fill(Color.white.opacity(0.22)).frame(width: 6, height: 6)
                    Text("macOS 菜单栏预览")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                    Spacer()

                    HStack(spacing: 5) {
                        Image(nsImage: CraneTemplateIconRenderer.menuBarIcon())
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 12)
                            .foregroundStyle(.white)
                        if viewModel.totalInboxUnreadCount > 0 {
                            Text("\(viewModel.totalInboxUnreadCount)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(viewModel.showMenuBarExtra ? 0.18 : 0.06), in: Capsule())
                    .opacity(viewModel.showMenuBarExtra ? 1.0 : 0.35)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                // Realistic macOS Frosted Notification Banner Preview
                HStack(spacing: 12) {
                    AppBrandIconView(size: 36, showShadow: false)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("GitHub")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Text("刚刚")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Text("您的登录验证码已送达，点击通知直达邮件")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }

                    Text("842916")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(BrandPalette.coralGradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.26), radius: 14, y: 6)
                .opacity(viewModel.notificationsEnabled ? 1.0 : 0.42)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.35), lineWidth: 0.9)
        )
        .shadow(color: BrandPalette.floatingCardShadow(for: colorScheme), radius: 12, y: 4)
    }

    // MARK: - Permissions Tab

    private var permissionSettingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $viewModel.blockRemoteImages) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("默认拦截邮件远程图片与外部资源")
                                .font(.callout.weight(.medium))
                            Text("防止追踪像素泄露 IP 与阅读时间；内嵌截图（cid:）仍正常显示，单封邮件可按需临时放行")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    Toggle(isOn: Binding(
                        get: { viewModel.allowOnlineBrandAvatars },
                        set: { viewModel.allowOnlineBrandAvatars = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("允许联网获取发件人品牌头像")
                                .font(.callout.weight(.medium))
                            Text("关闭时仅使用本地字母头像与内置品牌图标，不向第三方图标服务外发发件人域名")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本地正文全文搜索缓存")
                                .font(.callout.weight(.medium))
                            Text("当前已索引 \(bodyIndex.indexedBodyCount) 封邮件正文（仅保存在本机缓存，绝不改动原邮件库）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let errorMsg = bodyIndex.errorMessage, !errorMsg.isEmpty {
                                Text("最近索引异常：\(errorMsg)")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        if bodyIndex.errorMessage != nil {
                            Button("重试索引") {
                                viewModel.retryBodySearchIndexing()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        Button("重建索引") {
                            viewModel.rebuildBodySearchIndex()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("清空缓存") {
                            viewModel.clearBodySearchIndex()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("完全磁盘访问权限")
                                .font(.callout.weight(.medium))
                            Text("用于严格只读访问 ~/Library/Mail 原生邮件索引与正文")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("前往设置") {
                            viewModel.openFullDiskAccessSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动化控制「邮件」App")
                                .font(.callout.weight(.medium))
                            Text("用于自动标记已读、添加旗标、创建回复草稿及触发收信")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("前往设置") {
                            viewModel.openAutomationSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - About Tab

    private var aboutSettingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard {
                HStack(spacing: 16) {
                    AppBrandIconView(size: 62)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("MailPilot")
                                .font(.title2.weight(.bold))
                            Text("v\(appVersionLabel)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BrandPalette.coral)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2.5)
                                .background(BrandPalette.coral.opacity(0.12), in: Capsule())
                        }
                        Text("原生级 macOS 极简邮件客户端与 AI 领航助手")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("严格只读系统 Mail.app 邮件库 · 零账号密码托管 · 本地隐私脱敏")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("开源仓库与更新日志", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Link(destination: URL(string: "https://github.com/ajie5419/MailPilot")!) {
                            HStack(spacing: 4) {
                                Text("GitHub")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .font(.callout)
                        }
                    }

                    Divider()

                    HStack {
                        Label("问题反馈与功能建议", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Link(destination: URL(string: "https://github.com/ajie5419/MailPilot/issues")!) {
                            HStack(spacing: 4) {
                                Text("提交 Issue")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Floating Liquid-Glass Card & Helpers

    func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            BrandPalette.floatingCardFill(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BrandPalette.floatingCardBorder(for: colorScheme), lineWidth: 0.9)
        )
        .shadow(
            color: BrandPalette.floatingCardShadow(for: colorScheme),
            radius: 10,
            y: 3
        )
    }

    func labeledField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func tabColor(_ tab: SettingsTab) -> Color {
        switch tab {
        case .ai: return Color(red: 0.56, green: 0.34, blue: 0.94)
        case .accounts: return Color(red: 0.25, green: 0.44, blue: 0.96)
        case .tags: return Color(red: 0.08, green: 0.68, blue: 0.63)
        case .notifications: return BrandPalette.coral
        case .permissions: return Color(red: 0.16, green: 0.54, blue: 0.95)
        case .about: return Color(red: 0.48, green: 0.50, blue: 0.54)
        }
    }
}
