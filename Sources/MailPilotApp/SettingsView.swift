#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var ai: AIAssistantController
    @ObservedObject var bodyIndex: BodyIndexCoordinator

    init(viewModel: AppViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._ai = ObservedObject(wrappedValue: viewModel.ai)
        self._bodyIndex = ObservedObject(wrappedValue: viewModel.bodyIndex)
    }

    private var appVersionLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar Navigation
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        viewModel.settingsTab = tab
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(viewModel.settingsTab == tab ? .white : tabColor(tab))
                                .frame(width: 24, height: 24)
                                .background(
                                    viewModel.settingsTab == tab ? tabColor(tab) : tabColor(tab).opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                            Text(tab.rawValue)
                                .font(.callout.weight(viewModel.settingsTab == tab ? .semibold : .regular))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            viewModel.settingsTab == tab ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("MailPilot \(appVersionLabel)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .padding(12)
            .frame(width: 168)
            .background(.quaternary.opacity(0.35))

            Divider()

            // Right Detail Content
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                    }
                }
                .padding(22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
        .onAppear {
            ai.refreshAuthStatuses()
            viewModel.refreshNotificationStatus()
        }
        .sheet(isPresented: $viewModel.showIconPickerSheet) {
            AccountIconPickerSheet(viewModel: viewModel)
        }
    }

    // MARK: - Notifications Tab

    private var notificationSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("桌面通知")
                .font(.title3.weight(.semibold))

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
                            Text("在顶部菜单栏显示未读图标")
                                .font(.callout.weight(.medium))
                            Text("关闭主窗口后可随时在菜单栏查看未读数、快速打开或写信")
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

    // MARK: - Permissions Tab

    private var permissionSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("隐私与网络安全")
                .font(.title3.weight(.semibold))

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $viewModel.blockRemoteImages) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("默认拦截邮件远程图片与外部资源")
                                .font(.callout.weight(.medium))
                            Text("防止追踪像素泄露 IP 与阅读时间；内嵌截图（cid:）仍正常显示，单封邮件可按需临时放行")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

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

            Text("macOS 系统权限")
                .font(.title3.weight(.semibold))

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

    // MARK: - Helpers

    func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.45), lineWidth: 0.6)
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
        case .ai: return .purple
        case .accounts: return .indigo
        case .tags: return .teal
        case .notifications: return .orange
        case .permissions: return .blue
        }
    }
}
