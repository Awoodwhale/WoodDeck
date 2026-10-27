import AppKit
import SwiftUI

// 每个助手各自的配置：DSH 选可执行文件与 profile，其它助手给出配置文件位置
struct AgentConfigSheet: View {
    let agent: AgentKind

    @EnvironmentObject private var model: DeckModel
    @ObservedObject private var sessions = SessionCenter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if agent == .dsh {
                        dshContent
                    } else {
                        hookContent
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 540, height: agent == .dsh ? 460 : 280)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: agent.symbol)
                .font(.title2)
                .foregroundStyle(agent.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .font(.headline)
                Text(agent.mechanism)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let message = sessions.hookError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let message = sessions.hookMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(Loc.t("完成", "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // DSH：可执行文件路径 + profile 选择
    @ViewBuilder
    private var dshContent: some View {
        let detected = DSHHookInstaller.locateDSH(customPath: model.settings.dshPath)

        VStack(alignment: .leading, spacing: 6) {
            Text(Loc.t("dsh 可执行文件", "dsh executable"))
                .font(.subheadline.weight(.medium))
            TextField("", text: model.setting(\.dshPath), prompt: Text("/path/to/dsh"))
                .textFieldStyle(.roundedBorder)
            Text(detected.map { Loc.t("已检测到：\($0)", "Found at \($0)") }
                ?? Loc.t("未检测到 dsh，请填写它的完整路径。", "dsh was not found; enter its full path."))
                .font(.caption)
                .foregroundStyle(detected == nil ? .orange : .secondary)
                .textSelection(.enabled)
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text(Loc.t("读取哪些 profile 的会话", "Profiles to read"))
                .font(.subheadline.weight(.medium))
            let profiles = DSHHookInstaller.profiles
            if profiles.isEmpty {
                Text(Loc.t("没有找到 profile 目录，请先运行一次 dsh。",
                           "No profile folder was found; run dsh once first."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profiles) { profile in
                    profileRow(profile)
                }
                Text(Loc.t("web 是桌面端用的 profile，headless 是命令行用的 profile。",
                           "web is the profile the desktop app uses; headless is the command-line one."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Loc.t("会话提醒", "Session notices"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                SettingsSwitch(isOn: Binding(
                    get: { model.settings.sessionNotifications.enabled(for: .dsh) },
                    set: { sessions.setEnabled($0, for: .dsh) }))
            }
            Text(DSHHookInstaller.status(names: model.settings.dshSelectedProfiles).label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func profileRow(_ profile: DSHHookInstaller.Profile) -> some View {
        let state = DSHHookInstaller.status(in: profile)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.callout.weight(.medium))
                Text(profile.directory.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(state.label)
                    .font(.caption2)
                    .foregroundStyle(state == .installed ? .green : .secondary)
            }
            Spacer()
            SettingsSwitch(isOn: profileBinding(profile), enabled: !isOnlySelected(profile))
        }
        .padding(.vertical, 2)
    }

    // 最后一个选中的 profile 不能被关掉，否则没有任何目标可写入
    private func isOnlySelected(_ profile: DSHHookInstaller.Profile) -> Bool {
        let selected = DSHHookInstaller.profiles.filter { item in
            let names = model.settings.dshSelectedProfiles
            return names.isEmpty || names.contains(item.name)
        }
        return selected.count == 1 && selected.first?.name == profile.name
    }

    private func profileBinding(_ profile: DSHHookInstaller.Profile) -> Binding<Bool> {
        Binding(get: {
            let names = model.settings.dshSelectedProfiles
            return names.isEmpty || names.contains(profile.name)
        }, set: { value in
            let all = DSHHookInstaller.profiles.map(\.name)
            model.update { settings in
                var names = settings.dshProfilesCustomized ? settings.dshProfiles : all
                if value {
                    if !names.contains(profile.name) { names.append(profile.name) }
                } else {
                    let remaining = names.filter { $0 != profile.name }
                    // 至少留一个 profile；要全部停用请关掉会话提醒开关
                    guard !remaining.isEmpty else { return }
                    names = remaining
                }
                settings.dshProfiles = all.filter { names.contains($0) }
                settings.dshProfilesCustomized = true
            }
            // 选择变化后立刻按新的范围写入或清理插件
            if model.settings.sessionNotifications.enabled(for: .dsh) {
                sessions.install(.dsh)
            }
        })
    }

    // 其它助手：配置文件位置与状态
    @ViewBuilder
    private var hookContent: some View {
        if let file = configFile {
            VStack(alignment: .leading, spacing: 6) {
                Text(Loc.t("配置文件", "Configuration file"))
                    .font(.subheadline.weight(.medium))
                Text(file.path(percentEncoded: false))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(Loc.t("打开文件", "Open file")) { NSWorkspace.shared.open(file) }
                        .controlSize(.small)
                    Button(Loc.t("在访达中显示", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                    .controlSize(.small)
                }
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 4) {
            Text(Loc.t("状态", "Status"))
                .font(.subheadline.weight(.medium))
            Text((sessions.installedAgents[agent] ?? false)
                ? Loc.t("正在读取这个助手的会话，钩子已写入它的配置。",
                        "Reading this agent's sessions; the hook is written into its configuration.")
                : Loc.t("没有在读取。打开「会话通知」里的开关就会写入 WoodDeck 自己的钩子。",
                        "Not reading. Turn on the switch under Session notices and WoodDeck writes its own hook."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var configFile: URL? {
        switch agent {
        case .claude: HookInstaller.claudeSettings
        case .codex: HookInstaller.codexConfig
        case .gemini: HookInstaller.geminiSettings
        case .opencode: HookInstaller.opencodePlugin
        case .dsh: nil
        }
    }
}
