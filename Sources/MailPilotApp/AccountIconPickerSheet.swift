#if canImport(MailPilotCore)
import MailPilotCore
#endif
import SwiftUI

struct PresetLogoOption: Identifiable, Hashable {
    let id: String
    let label: String
    let domain: String?
    let badgeText: String?
    let badgeColor: Color?

    static let all: [PresetLogoOption] = [
        PresetLogoOption(id: "aol", label: "AOL", domain: nil, badgeText: "AOL", badgeColor: .black),
        PresetLogoOption(id: "gmail", label: "Gmail", domain: "mail.google.com", badgeText: nil, badgeColor: nil),
        PresetLogoOption(id: "icloud", label: "iCloud", domain: "icloud.com", badgeText: nil, badgeColor: nil),
        PresetLogoOption(id: "outlook", label: "Outlook", domain: "outlook.live.com", badgeText: nil, badgeColor: nil),
        PresetLogoOption(id: "163", label: "163", domain: nil, badgeText: "163", badgeColor: Color(red: 0.84, green: 0.16, blue: 0.16)),
        PresetLogoOption(id: "126", label: "126", domain: nil, badgeText: "126", badgeColor: Color(red: 0.12, green: 0.56, blue: 0.30)),
        PresetLogoOption(id: "qq", label: "QQ 邮箱", domain: "mail.qq.com", badgeText: nil, badgeColor: nil),
        PresetLogoOption(id: "foxmail", label: "Foxmail", domain: "foxmail.com", badgeText: nil, badgeColor: nil),
        PresetLogoOption(id: "yahoo", label: "Yahoo", domain: "mail.yahoo.com", badgeText: nil, badgeColor: nil),
        PresetLogoOption(id: "proton", label: "Proton", domain: "proton.me", badgeText: nil, badgeColor: nil),
        PresetLogoOption(id: "fastmail", label: "Fastmail", domain: "fastmail.com", badgeText: nil, badgeColor: nil),
        PresetLogoOption(id: "aliyun", label: "阿里邮箱", domain: "qiye.aliyun.com", badgeText: nil, badgeColor: nil),
        PresetLogoOption(id: "feishu", label: "飞书邮箱", domain: "feishu.cn", badgeText: nil, badgeColor: nil)
    ]

    static func find(_ id: String?) -> PresetLogoOption? {
        guard let id else { return nil }
        return all.first(where: { $0.id == id })
    }
}

struct AccountIconPickerState {
    var accountID: String = ""
    var email: String? = nil
    var customIconPath: String? = nil
    var presetLogoID: String? = nil
    var sfSymbolName: String? = nil
}

struct AccountIconPickerSheet: View {
    @ObservedObject var viewModel: AppViewModel

    private static let symbolLibrary: [String] = [
        "shield", "doc.text", "box.truck", "airplane", "calendar", "bell", "newspaper", "bag",
        "folder", "dollarsign.circle", "book.closed", "graduationcap", "pencil", "applepencil.tip", "curlybraces", "terminal",
        "music.note", "film", "wrench.and.screwdriver", "paintpalette", "stethoscope", "cross.case", "leaf", "briefcase",
        "chart.bar", "figure.run", "note.text", "scale.3d", "globe.asia.australia", "globe", "hammer", "shoeprints.fill",
        "flask", "brain.head.profile", "heart", "camera.macro", "person.3", "house", "key", "bubble.left"
    ]

    private let logoColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 7)
    private let symbolColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("账户图标")
                        .font(.title3.weight(.semibold))
                    Text("为此账户选择一个图标或上传自定义图片。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.showIconPickerSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Current preview + Upload button
                    HStack(spacing: 14) {
                        AccountLogoView(
                            accountID: viewModel.iconPickerState.accountID,
                            email: viewModel.iconPickerState.email,
                            customIconPath: viewModel.iconPickerState.customIconPath,
                            presetLogoID: viewModel.iconPickerState.presetLogoID,
                            sfSymbolName: viewModel.iconPickerState.sfSymbolName,
                            fallbackColor: viewModel.accountBadgeColor(for: viewModel.iconPickerState.accountID),
                            size: 38
                        )

                        Button("上传自定义图标...") {
                            viewModel.pickCustomIconForPicker()
                        }
                        .buttonStyle(.bordered)

                        if viewModel.iconPickerState.customIconPath != nil
                            || viewModel.iconPickerState.presetLogoID != nil
                            || viewModel.iconPickerState.sfSymbolName != nil {
                            Button("恢复自动识别") {
                                viewModel.iconPickerState.customIconPath = nil
                                viewModel.iconPickerState.presetLogoID = nil
                                viewModel.iconPickerState.sfSymbolName = nil
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.separator.opacity(0.45), lineWidth: 0.6)
                    )

                    // Logo Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Logo")
                            .font(.callout.weight(.semibold))

                        LazyVGrid(columns: logoColumns, spacing: 12) {
                            ForEach(PresetLogoOption.all) { option in
                                let isSelected = viewModel.iconPickerState.customIconPath == nil
                                    && viewModel.iconPickerState.presetLogoID == option.id
                                Button {
                                    viewModel.iconPickerState.customIconPath = nil
                                    viewModel.iconPickerState.sfSymbolName = nil
                                    viewModel.iconPickerState.presetLogoID = option.id
                                } label: {
                                    PresetLogoTile(option: option, size: 34)
                                        .padding(4)
                                        .background(
                                            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .help(option.label)
                            }
                        }
                    }

                    // Symbols Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("图标")
                            .font(.callout.weight(.semibold))

                        LazyVGrid(columns: symbolColumns, spacing: 10) {
                            ForEach(Self.symbolLibrary, id: \.self) { symbol in
                                let isSelected = viewModel.iconPickerState.customIconPath == nil
                                    && viewModel.iconPickerState.presetLogoID == nil
                                    && viewModel.iconPickerState.sfSymbolName == symbol
                                Button {
                                    viewModel.iconPickerState.customIconPath = nil
                                    viewModel.iconPickerState.presetLogoID = nil
                                    viewModel.iconPickerState.sfSymbolName = symbol
                                } label: {
                                    Image(systemName: symbol)
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.88))
                                        .frame(width: 36, height: 36)
                                        .background(
                                            isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.3)
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            // Footer buttons
            HStack {
                Spacer()
                Button("取消") {
                    viewModel.showIconPickerSheet = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)

                Button("保存") {
                    viewModel.saveIconPickerSelection()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 500, height: 540)
    }
}

struct PresetLogoTile: View {
    let option: PresetLogoOption
    let size: CGFloat
    @ObservedObject private var avatarLoader = SenderAvatarLoader.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color.white)

            if let text = option.badgeText, let color = option.badgeColor {
                Text(text)
                    .font(.system(size: size * (text.count >= 3 ? 0.36 : 0.44), weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            } else if let domain = option.domain,
                      let img = avatarLoader.accountLogo(for: "user@\(domain)") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.14)
            } else {
                Text(String(option.label.prefix(2)))
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
        )
    }
}
