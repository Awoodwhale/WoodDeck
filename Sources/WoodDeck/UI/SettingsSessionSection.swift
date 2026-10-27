import SwiftUI

struct SessionNotificationSection: View {
    @EnvironmentObject private var model: DeckModel
    @ObservedObject var sessions = SessionCenter.shared
    @State private var configuring: AgentKind?

    var body: some View {
        Form {
            Section {
                SettingRow(icon: "person.2",
                           title: Loc.t("当前会话", "Active sessions"),
                           description: nil) {
                    Text("\(sessions.sessions.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                SettingRow(icon: "bell",
                           title: Loc.t("待处理", "Waiting for you"),
                           description: nil) {
                    Text("\(sessions.attentionSessions.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                permissionRow
            } header: {
                Text(Loc.t("实时状态", "Live status"))
            } footer: {
                Text(Loc.t("数字来自当前正在运行的会话。",
                           "The numbers come from the sessions that are running now."))
            }

            Section {
                ForEach(AgentKind.allCases) { agent in
                    agentRow(agent)
                }
            } header: {
                Text(Loc.t("助手", "Agents"))
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Loc.t("开关决定是否读取这个助手的会话并发出通知；打开时 WoodDeck 会把自己的钩子写进它的配置，关闭时只清理自己写入的那部分。",
                               "The switch decides whether WoodDeck reads this agent's sessions and notifies you; turning it on writes WoodDeck's own hook into the agent's configuration, turning it off removes only what WoodDeck wrote."))
                    if let error = sessions.hookError {
                        Text(error).foregroundStyle(.red)
                    } else if let message = sessions.hookMessage {
                        Text(message).foregroundStyle(.green)
                    }
                }
            }

            Section {
                SettingRow(icon: "menubar.rectangle",
                           title: Loc.t("横幅通知", "Banner notifications"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.sessionNotifications.banner))
                }
                SettingRow(icon: "speaker.wave.2",
                           title: Loc.t("播放声音", "Play a sound"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.sessionNotifications.sound))
                }
                SettingRow(icon: "bell.badge",
                           title: Loc.t("在岛上弹出提示", "Show a notice on the island"),
                           description: Loc.t("会话结束或等待你处理时，岛上弹出提示信息。",
                                              "Show a notice on the island when a session finishes or waits for you.")) {
                    SettingsSwitch(isOn: model.setting(\.sessionNotifications.islandPopup))
                }
                if model.settings.sessionNotifications.islandPopup {
                    islandDurationRow
                }
                SettingRow(icon: "arrow.up.left.and.arrow.down.right",
                           title: Loc.t("弹出提示时自动展开", "Expand automatically with the notice"),
                           description: Loc.t("有会话等你处理时直接展开到会话页，并保持到提示结束。",
                                              "Open the sessions page when a session waits for you, and keep it open until the notice ends.")) {
                    SettingsSwitch(isOn: model.setting(\.sessionNotifications.autoExpand))
                }
                SettingRow(icon: "bell.badge.circle",
                           title: Loc.t("在收起形态显示提醒数", "Show the alert count in the collapsed form"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.sessionNotifications.showInCompact))
                }
            } header: {
                Text(Loc.t("提醒方式", "How to remind"))
            } footer: {
                Text(Loc.t("会话等你处理时按这里的方式通知。",
                           "Sessions notify you this way when they wait for you."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            sessions.clearHookFeedback()
            sessions.refreshInstalledState()
            sessions.refreshNotificationPermission()
        }
        .sheet(item: $configuring) { agent in
            AgentConfigSheet(agent: agent)
                .environmentObject(model)
        }
    }

    private var permissionRow: some View {
        SettingRow(icon: "bell.badge",
                   title: Loc.t("通知权限", "Notification permission"),
                   description: sessions.notificationPermission.label) {
            HStack(spacing: 8) {
                if sessions.notificationPermission == .authorized {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if sessions.notificationPermission.needsSystemSettings {
                    Button(Loc.t("打开系统设置", "Open Settings")) {
                        sessions.openNotificationSettings()
                    }
                    .controlSize(.small)
                } else {
                    Button(Loc.t("请求权限", "Request")) {
                        sessions.requestNotificationPermission()
                    }
                    .controlSize(.small)
                    .disabled(sessions.notificationPermission == .unavailable)
                }
            }
        }
    }

    private var islandDurationRow: some View {
        SettingRow(icon: "timer",
                   title: Loc.t("提示停留时长", "Notice duration"),
                   description: Loc.t("提示在岛上显示多久。", "How long the notice stays on the island.")) {
            HStack(spacing: 8) {
                Slider(value: secondsBinding,
                       in: SessionNotificationSettings.islandRange,
                       step: 1)
                    .frame(width: 140)
                Text("\(Int(model.settings.sessionNotifications.islandSeconds.rounded())) \(Loc.t("秒", "s"))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    private var secondsBinding: Binding<Double> {
        Binding(get: { model.settings.sessionNotifications.islandSeconds },
                set: { value in
                    model.update { $0.sessionNotifications.islandSeconds = value.rounded() }
                })
    }

    private func agentRow(_ agent: AgentKind) -> some View {
        SettingRow(icon: agent.symbol,
                   title: agent.displayName,
                   description: statusText(agent)) {
            HStack(spacing: 8) {
                Button(Loc.t("配置", "Configure")) {
                    sessions.clearHookFeedback()
                    configuring = agent
                }
                    .controlSize(.small)
                SettingsSwitch(isOn: agentBinding(agent))
            }
        }
    }

    private func agentBinding(_ agent: AgentKind) -> Binding<Bool> {
        Binding(get: { model.settings.sessionNotifications.enabled(for: agent) },
                set: { value in sessions.setEnabled(value, for: agent) })
    }

    private func statusText(_ agent: AgentKind) -> String {
        guard model.settings.sessionNotifications.enabled(for: agent) else {
            return Loc.t("已关闭 · \(agent.mechanism)", "Off · \(agent.mechanism)")
        }
        let hooked = sessions.installedAgents[agent] ?? false
        let state = hooked ? Loc.t("正在读取", "Reading") : Loc.t("等待钩子生效", "Waiting for the hook")
        return "\(state) · \(agent.mechanism)"
    }
}
