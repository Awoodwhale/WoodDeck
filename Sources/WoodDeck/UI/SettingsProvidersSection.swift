import SwiftUI

struct ProvidersSection: View {
    @EnvironmentObject private var model: DeckModel
    @State private var secrets: [UUID: String] = [:]
    @State private var testResults: [UUID: String] = [:]

    var body: some View {
        Form {
            Section {
                SettingRow(icon: "bell.badge",
                           title: Loc.t("配额提醒", "Quota notices"),
                           description: Loc.t("额度升到预警线或告警线时提醒一次。",
                                              "You are told once when a quota reaches the warning or critical level.")) {
                    SettingsSwitch(isOn: model.setting(\.quotaAlerts))
                }
            } header: {
                Text(Loc.t("提醒", "Notices"))
            }

            ForEach(model.settings.apps) { app in
                Section {
                    AppEntryEditor(entry: app,
                                   secret: secretBinding(app),
                                   testResult: testResults[app.instanceID],
                                   onTest: { test(app) })
                } header: {
                    HStack(spacing: 10) {
                        Text(app.name)
                        Spacer(minLength: 12)
                        Text(app.enabled ? Loc.t("已启用", "On") : Loc.t("已停用", "Off"))
                            .foregroundStyle(app.enabled ? Color.accentColor : Color.secondary)
                        Toggle("", isOn: enabledBinding(app))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                }
            }

            Section {
                SettingRow(icon: "plus.circle",
                           title: Loc.t("添加应用", "Add application"),
                           description: Loc.t("已添加 \(model.settings.apps.count) 个，最多 \(AppPresets.maximumApps) 个",
                                              "\(model.settings.apps.count) added, up to \(AppPresets.maximumApps)")) {
                    Menu {
                        ForEach(ProviderID.allCases) { id in
                            Button(id.displayName) { addApp(id) }
                        }
                    } label: {
                        Label(Loc.t("添加应用", "Add application"), systemImage: "plus")
                    }
                    .fixedSize()
                    .disabled(model.settings.apps.count >= AppPresets.maximumApps)
                }
            } header: {
                Text(Loc.t("应用列表", "Applications"))
            } footer: {
                Text(Loc.t("每个应用占一列，最多 \(AppPresets.maximumApps) 列。",
                           "Each application takes one column, up to \(AppPresets.maximumApps)."))
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadSecrets)
    }

    private func enabledBinding(_ app: AppEntry) -> Binding<Bool> {
        Binding(get: { model.settings.apps.first { $0.instanceID == app.instanceID }?.enabled ?? app.enabled },
                set: { value in
                    model.update { settings in
                        guard let index = settings.apps.firstIndex(where: { $0.instanceID == app.instanceID }) else { return }
                        settings.apps[index].enabled = value
                    }
                })
    }

    private func loadSecrets() {
        for app in model.settings.apps {
            secrets[app.instanceID] = SecretStore.shared.secret(for: app) ?? ""
        }
    }

    private func secretBinding(_ app: AppEntry) -> Binding<String> {
        Binding(get: { secrets[app.instanceID] ?? "" }, set: { value in
            secrets[app.instanceID] = value
            SecretStore.shared.setSecret(value, for: app)
        })
    }

    private func addApp(_ id: ProviderID) {
        guard model.settings.apps.count < AppPresets.maximumApps else { return }
        model.update { settings in
            settings.apps.append(AppEntry(quotaSource: id, usageSource: id.isUsageSource ? id : .claude, enabled: true))
        }
        loadSecrets()
    }

    private func test(_ app: AppEntry) {
        let secret = secrets[app.instanceID] ?? ""
        testResults[app.instanceID] = Loc.t("测试中…", "Testing…")
        Task {
            let start = Date()
            do {
                let result = try await ProviderRegistry.fetchQuota(app.quotaSource, entry: app, secret: secret,
                                                                   context: ProviderContext(now: Date(), site: app.site, secret: secret,
                                                                                            script: app.script, language: Loc.language),
                                                                   locations: DataLocations.detect(), http: HTTPClient())
                let elapsed = Date().timeIntervalSince(start)
                let summary = result.metrics.first.map { "\($0.label) \($0.valueText)" } ?? Loc.t("无数据", "No data")
                testResults[app.instanceID] = Loc.t("成功：\(summary)（\(Int(elapsed * 1000)) 毫秒）",
                                                    "OK: \(summary) (\(Int(elapsed * 1000)) ms)")
            } catch {
                testResults[app.instanceID] = Loc.t("失败：", "Failed: ") + error.localizedDescription
            }
        }
    }
}

struct AppEntryEditor: View {
    @EnvironmentObject private var model: DeckModel
    var entry: AppEntry
    @Binding var secret: String
    var testResult: String?
    var onTest: () -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                AppFieldCell(Loc.t("显示名称", "Display name")) {
                    TextField("", text: nameBinding, prompt: Text(entry.quotaSource.displayName))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 132)
                }
                AppFieldCell(Loc.t("配额来源", "Quota source")) {
                    Picker("", selection: quotaBinding) {
                        ForEach(ProviderID.allCases) { id in
                            Text(id.displayName).tag(id)
                        }
                    }
                    .labelsHidden()
                }
                AppFieldCell(Loc.t("统计来源", "Usage source")) {
                    Picker("", selection: usageBinding) {
                        ForEach(ProviderID.usageSources) { id in
                            Text(id.displayName).tag(id)
                        }
                    }
                    .labelsHidden()
                }
            }
            GridRow {
                ColorSourceCell(title: Loc.t("主题色", "Theme color"),
                                value: entry.themeColor,
                                resolved: entry.resolvedTheme) { hex in update { $0.themeColor = hex } }
                ColorSourceCell(title: Loc.t("预警色", "Warning color"),
                                value: entry.warningColor,
                                resolved: entry.resolvedWarning) { hex in update { $0.warningColor = hex } }
                ColorSourceCell(title: Loc.t("告警色", "Critical color"),
                                value: entry.criticalColor,
                                resolved: entry.resolvedCritical) { hex in update { $0.criticalColor = hex } }
            }
        }

        if entry.quotaSource.hasOnlineSwitch {
            Toggle(Loc.t("联网获取额度", "Read the quota online"),
                   isOn: Binding(get: { entry.quotaOnline }, set: { value in update { $0.quotaOnline = value } }))
        }

        if entry.quotaSource.needsSite {
            LabeledContent(Loc.t("站点", "Site")) {
                TextField("", text: Binding(get: { entry.site }, set: { value in update { $0.site = value } }),
                          prompt: Text("https://api.example.com"))
                    .textFieldStyle(.roundedBorder)
            }
        }

        if entry.quotaSource.needsSecret {
            LabeledContent(Loc.t("API 密钥", "API key")) {
                SecureField("", text: $secret)
            }
        }

        if entry.quotaSource.needsSecret || entry.quotaSource == .custom {
            Button(Loc.t("测试连接", "Test connection"), action: onTest)
        }

        if let testResult {
            LabeledContent(Loc.t("测试结果", "Test result")) {
                Text(testResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }

        if entry.quotaSource == .custom {
            scriptEditor
        }

        Button(Loc.t("删除这一列", "Remove this column"), role: .destructive) { remove() }
    }

    private var nameBinding: Binding<String> {
        Binding(get: { entry.displayName },
                set: { value in update { $0.displayName = value } })
    }

    private var quotaBinding: Binding<ProviderID> {
        Binding(get: { entry.quotaSource },
                set: { value in update { $0.quotaSource = value } })
    }

    private var usageBinding: Binding<ProviderID> {
        Binding(get: { entry.resolvedUsageSource },
                set: { value in update { $0.usageSource = value } })
    }

    private var scriptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Loc.t("自定义脚本", "Custom script"))
            TextEditor(text: Binding(get: { entry.script }, set: { value in update { $0.script = value } }))
                .font(.caption.monospaced())
                .frame(height: 160)
            HStack(spacing: 10) {
                Button(Loc.t("插入模板", "Insert template")) {
                    update { $0.script = ProviderScripts.example }
                }
                Button(Loc.t("测试连接", "Test connection"), action: onTest)
            }
        }
    }

    private func update(_ change: (inout AppEntry) -> Void) {
        model.update { settings in
            guard let index = settings.apps.firstIndex(where: { $0.instanceID == entry.instanceID }) else { return }
            change(&settings.apps[index])
        }
    }

    private func remove() {
        SecretStore.shared.deleteSecret(for: entry)
        model.update { settings in
            settings.apps.removeAll { $0.instanceID == entry.instanceID }
        }
    }
}

// 应用分组里的一格：说明在上，控件在下
struct AppFieldCell<Content: View>: View {
    var title: String
    var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

// 一列应用的一种颜色：左侧显示当前色，右侧用菜单选择
struct ColorSourceCell: View {
    var title: String
    var value: String
    var resolved: String
    var onChange: (String) -> Void

    var body: some View {
        AppFieldCell(title) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.color(resolved))
                    .frame(width: 11, height: 11)
                Picker("", selection: Binding(get: { value }, set: onChange)) {
                    ForEach(AppPresets.palette, id: \.self) { hex in
                        Text(hex).tag(hex)
                    }
                    Text(Loc.t("跟随预设", "Preset")).tag("")
                }
                .labelsHidden()
                .frame(width: 118)
            }
        }
    }
}
