#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

extension SettingsView {
    // MARK: - Accounts Tab

    var accountsSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("邮箱账号设置")
                .font(.title3.weight(.semibold))

            if viewModel.groupedMailboxes.isEmpty {
                settingsCard {
                    Text("尚未检测到邮箱账号，请先在系统 Mail.app 登录邮箱并授予完全磁盘访问权限。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Multi-row adaptive grid so all accounts are visible at once without horizontal scrolling
                let columns = [GridItem(.adaptive(minimum: 125, maximum: 180), spacing: 8)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(viewModel.groupedMailboxes) { group in
                        let isSelected = viewModel.selectedSettingsAccountID == group.id
                        Button {
                            viewModel.selectedSettingsAccountID = group.id
                        } label: {
                            HStack(spacing: 6) {
                                AccountLogoView(
                                    accountID: group.id,
                                    email: group.email,
                                    customIconPath: group.customIconPath,
                                    presetLogoID: group.presetLogoID,
                                    sfSymbolName: group.sfSymbolName,
                                    fallbackColor: viewModel.accountBadgeColor(for: group.id),
                                    size: 16
                                )
                                Text(group.title)
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 1.2 : 0.6)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let activeGroup = viewModel.groupedMailboxes.first(where: { $0.id == viewModel.selectedSettingsAccountID }) ?? viewModel.groupedMailboxes.first {
                    Text("基本信息")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)

                    settingsCard {
                        VStack(spacing: 14) {
                            // 1. Sender Display Name
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("发件人名称")
                                        .font(.callout.weight(.medium))
                                    Text("收件人看到的名字")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                TextField(
                                    "例如：Jay Zhao",
                                    text: Binding(
                                        get: { viewModel.customization(for: activeGroup.id).senderDisplayName },
                                        set: { val in viewModel.updateCustomization(for: activeGroup.id) { $0.senderDisplayName = val } }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                            }

                            Divider()

                            // 2. Sidebar Display Name
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("侧栏显示名称")
                                        .font(.callout.weight(.medium))
                                    Text(activeGroup.email ?? "留空显示默认邮箱")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                TextField(
                                    "留空显示完整邮箱",
                                    text: Binding(
                                        get: { viewModel.customization(for: activeGroup.id).sidebarName },
                                        set: { val in viewModel.updateCustomization(for: activeGroup.id) { $0.sidebarName = val } }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                            }

                            Divider()

                            // 3. Account Icon
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("账户图标")
                                        .font(.callout.weight(.medium))
                                    Text("显示在侧边栏和账户列表中")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                AccountLogoView(
                                    accountID: activeGroup.id,
                                    email: activeGroup.email,
                                    customIconPath: activeGroup.customIconPath,
                                    presetLogoID: activeGroup.presetLogoID,
                                    sfSymbolName: activeGroup.sfSymbolName,
                                    fallbackColor: viewModel.accountBadgeColor(for: activeGroup.id),
                                    size: 26
                                )
                                Button("选择图标...") {
                                    viewModel.openIconPicker(for: activeGroup)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Divider()

                            // 4. Default Send Account
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("设为默认发件账户")
                                        .font(.callout.weight(.medium))
                                    Text("在「全部收件箱」里写邮件时使用")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { viewModel.defaultSendAccountID.uppercased() == activeGroup.id.uppercased() },
                                        set: { isOn in
                                            viewModel.defaultSendAccountID = isOn ? activeGroup.id : ""
                                        }
                                    )
                                )
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }

                            Divider()

                            // 5. Account Signature
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("默认发件签名")
                                        .font(.callout.weight(.medium))
                                    Spacer()
                                    Text("写信、回复、转发时自动附在正文末尾")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                TextEditor(
                                    text: Binding(
                                        get: { viewModel.customization(for: activeGroup.id).signature },
                                        set: { val in viewModel.updateCustomization(for: activeGroup.id) { $0.signature = val } }
                                    )
                                )
                                .font(.callout)
                                .frame(height: 70)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(.separator, lineWidth: 0.7)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tags Tab

    var tagSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("智能邮件标签")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("恢复默认") {
                    viewModel.resetTagSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            settingsCard {
                Toggle(isOn: $viewModel.tagSettings.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用智能邮件标签")
                            .font(.callout.weight(.medium))
                        Text("根据发件人与主题零延迟自动归类，在邮件列表与左侧边栏展示")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            if viewModel.tagSettings.isEnabled {
                settingsCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("标签规则与自定义关键词")
                            .font(.callout.weight(.semibold))

                        ForEach(MailSmartTag.allCases) { tag in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 10) {
                                    SmartTagPill(tag: tag)
                                    Text(tag.descriptionText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Toggle(
                                        "",
                                        isOn: Binding(
                                            get: { viewModel.tagSettings.isTagEnabled(tag) },
                                            set: { viewModel.setTag(tag, enabled: $0) }
                                        )
                                    )
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                }

                                if viewModel.tagSettings.isTagEnabled(tag) {
                                    TextField(
                                        "追加关键词（逗号分隔，例如：阿里云, 顺丰）",
                                        text: Binding(
                                            get: { viewModel.tagSettings.customKeywords[tag.rawValue] ?? "" },
                                            set: { viewModel.setCustomKeywords($0, for: tag) }
                                        )
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                }
                            }

                            if tag != MailSmartTag.allCases.last {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

}
