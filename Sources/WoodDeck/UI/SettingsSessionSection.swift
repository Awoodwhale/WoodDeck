import SwiftUI

struct SessionNotificationSection: View {
    @EnvironmentObject private var model: DeckModel
    @ObservedObject var sessions = SessionCenter.shared
    @State private var dshStatus: DSHHookInstaller.Status = .notInstalled
    @State private var dshFailure: String?

    private let agents: [AgentKind] = [.claude, .codex, .gemini, .opencode]

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
                SettingRow(icon: "bell.badge",
                           title: Loc.t("通知权限", "Notification permission"),
                           description: nil) {
                    Button(Loc.t("请求权限", "Request")) {
                        sessions.requestNotificationPermission()
                    }
                }
            } header: {
                Text(Loc.t("实时状态", "Live status"))
            } footer: {
                Text(Loc.t("数字来自当前正在运行的会话。",
                           "The numbers come from the sessions that are running now."))
            }

            Section {
                ForEach(agents) { agent in
                    agentRow(agent)
                }
            } header: {
                Text(Loc.t("助手", "Agents"))
            } footer: {
                Text(Loc.t("会话状态来自各助手发来的事件。",
                           "Session states come from the events the agents send."))
            }

            Section {
                dshRows
            } header: {
                Text("DeepSeek Harness")
            } footer: {
                Text(dshFooter)
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
                           description: Loc.t("会话结束或等待你处理时，岛上显示 8 秒提示", "Show an 8-second notice when a session finishes or waits for you")) {
                    SettingsSwitch(isOn: model.setting(\.sessionNotifications.islandPopup))
                }
                SettingRow(icon: "arrow.up.left.and.arrow.down.right",
                           title: Loc.t("弹出提示时自动展开", "Expand automatically with the notice"),
                           description: nil) {
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
            sessions.refreshInstalledState()
            refreshDSHStatus()
        }
        .onChange(of: model.settings.dshPath) { _, _ in
            refreshDSHStatus()
        }
    }

    @ViewBuilder
    private var dshRows: some View {
        let detected = DSHHookInstaller.locateDSH(customPath: model.settings.dshPath)

        SettingRow(icon: "waveform.path",
                   title: Loc.t("DeepSeek Harness 会话通知", "DeepSeek Harness session notices"),
                   description: detected.map { Loc.t("已检测到 dsh：\($0)", "dsh found at \($0)") }
                       ?? Loc.t("未检测到 dsh", "dsh was not found")) {
            HStack(spacing: 10) {
                if detected == nil {
                    TextField("", text: model.setting(\.dshPath), prompt: Text("/path/to/dsh"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                }
                SettingsSwitch(isOn: dshHookBinding, enabled: detected != nil)
            }
        }
        if let dshFailure {
            SettingRow(icon: "exclamationmark.triangle",
                       title: Loc.t("插件状态", "Plugin status"),
                       description: dshFailure) {
                EmptyView()
            }
        }
        SettingRow(icon: "folder",
                   title: Loc.t("profile 目录", "Profile folder"),
                   description: DSHHookInstaller.profileDirectory?.path(percentEncoded: false)
                       ?? Loc.t("未找到", "Not found")) {
            EmptyView()
        }
        SettingRow(icon: "bell",
                   title: Loc.t("会话通知开关", "Session notices"),
                   description: Loc.t("关闭后 DSH 的会话状态不再提示。",
                                      "Turning this off stops the DSH session states from notifying you.")) {
            SettingsSwitch(isOn: agentBinding(.dsh))
        }
    }

    private var dshFooter: String {
        DSHHookInstaller.locateDSH(customPath: model.settings.dshPath) == nil
            ? Loc.t("填写 dsh 的可执行文件路径后会自动检测。",
                    "The path is checked as soon as you enter it.")
            : Loc.t("开关把 WoodDeck 的会话通知插件写入 DSH 的 profile，关闭时移除。",
                    "The switch writes WoodDeck's session-notice plugin into the DSH profile and removes it when switched off.")
    }

    private var dshHookBinding: Binding<Bool> {
        Binding(get: { dshStatus == .installed },
                set: { value in
                    if value {
                        guard let executable = Bundle.main.executablePath else {
                            dshFailure = Loc.t("没有找到应用的可执行文件路径",
                                               "The app executable path was not found")
                            return
                        }
                        do {
                            try DSHHookInstaller.install(executablePath: executable)
                            dshStatus = DSHHookInstaller.status()
                            dshFailure = nil
                        } catch {
                            dshStatus = .failed(error.localizedDescription)
                            dshFailure = error.localizedDescription
                        }
                    } else {
                        DSHHookInstaller.uninstall()
                        dshStatus = DSHHookInstaller.status()
                        dshFailure = nil
                    }
                })
    }

    private func refreshDSHStatus() {
        dshStatus = DSHHookInstaller.status()
        if case .failed(let text) = dshStatus {
            dshFailure = text
        } else {
            dshFailure = nil
        }
    }

    private func agentRow(_ agent: AgentKind) -> some View {
        SettingRow(icon: agent.symbol,
                   title: agent.displayName,
                   description: statusText(agent)) {
            HStack(spacing: 8) {
                Button(Loc.t("安装", "Install")) { sessions.install(agent) }
                    .controlSize(.small)
                    .disabled(installed(agent))
                Button(Loc.t("卸载", "Uninstall")) { sessions.uninstall(agent) }
                    .controlSize(.small)
                    .disabled(!installed(agent))
                SettingsSwitch(isOn: agentBinding(agent))
            }
        }
    }

    private func agentBinding(_ agent: AgentKind) -> Binding<Bool> {
        Binding(get: { model.settings.sessionNotifications.enabled(for: agent) },
                set: { value in
                    model.update { settings in
                        settings.sessionNotifications.setEnabled(value, for: agent)
                    }
                })
    }

    private func installed(_ agent: AgentKind) -> Bool {
        sessions.installedAgents[agent] ?? false
    }

    private func statusText(_ agent: AgentKind) -> String {
        installed(agent) ? Loc.t("已安装", "Installed") : Loc.t("未安装", "Not installed")
    }
}
