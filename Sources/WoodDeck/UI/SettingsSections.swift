import SwiftUI

struct ClockSection: View {
    @EnvironmentObject private var model: DeckModel

    var body: some View {
        Form {
            Section {
                SettingsPickerRow(icon: "clock",
                                  title: Loc.t("样式", "Style"),
                                  description: nil,
                                  selection: model.setting(\.clockStyle)) {
                    ForEach(ClockStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                SettingRow(icon: "number",
                           title: Loc.t("24 小时制", "24-hour clock"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.clock24Hour))
                }
            } header: {
                Text(Loc.t("样式", "Style"))
            } footer: {
                Text(Loc.t("时间出现在收起形态与展开面板里。",
                           "The clock appears in the collapsed form and in the expanded panel."))
            }

            Section {
                SettingsPickerRow(icon: "paintpalette",
                                  title: Loc.t("颜色", "Color"),
                                  description: nil,
                                  selection: model.setting(\.clockColor)) {
                    ForEach(ClockColor.allCases) { color in
                        Text(color.displayName).tag(color)
                    }
                }

                if model.settings.clockColor == .custom {
                    SettingRow(icon: "eyedropper",
                               title: Loc.t("自定义颜色", "Custom color"),
                               description: nil) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Theme.color(model.settings.clockCustomColor, fallback: .white))
                                .frame(width: 11, height: 11)
                            TextField("#RRGGBB", text: model.setting(\.clockCustomColor))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }
                    }
                }

                if model.settings.clockColor == .gradient {
                    SettingRow(icon: "paintbrush",
                               title: Loc.t("渐变配色", "Gradient"),
                               description: nil) {
                        HStack(spacing: 8) {
                            ForEach(gradientPresets, id: \.self) { start in
                                gradientButton(start)
                            }
                        }
                    }
                }
            } header: {
                Text(Loc.t("颜色", "Color"))
            } footer: {
                Text(Loc.t("渐变按钮写入三色渐变，时间按从左到右的顺序取色。",
                           "Each gradient button writes three colors; the clock takes them from left to right."))
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func gradientButton(_ start: String) -> some View {
        let colors = gradient(for: start)
        let label = Capsule()
            .fill(LinearGradient(colors: colors.map { Theme.color($0) },
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: 34, height: 12)
        if model.settings.clockGradient == colors {
            Button { apply(start) } label: { label }.buttonStyle(.borderedProminent)
        } else {
            Button { apply(start) } label: { label }.buttonStyle(.bordered)
        }
    }

    private func apply(_ start: String) {
        model.update { $0.clockGradient = gradient(for: start) }
    }

    private var gradientPresets: [String] {
        ["#FFB38A", "#7CF3FF", "#8BFFB0", "#FFE27A", "#FF5CF0"]
    }

    private func gradient(for start: String) -> [String] {
        switch start {
        case "#FFB38A": ["#FFB38A", "#FF7EB3", "#B69CFF"]
        case "#7CF3FF": ["#7CF3FF", "#4FA8FF", "#6A6CFF"]
        case "#8BFFB0": ["#8BFFB0", "#5CE1E6", "#B69CFF"]
        case "#FFE27A": ["#FFE27A", "#FF9F43", "#FF5E5E"]
        default: ["#FF5CF0", "#A66BFF", "#5CE1E6"]
        }
    }
}

struct MusicSection: View {
    @EnvironmentObject private var model: DeckModel
    @State private var adapterStatus = Loc.t("未检查", "Not checked")

    var body: some View {
        Form {
            Section {
                SettingsPickerRow(icon: "textformat",
                                  title: Loc.t("显示文字", "Text"),
                                  description: nil,
                                  selection: model.setting(\.musicText)) {
                    ForEach(CompactMusicText.allCases) { text in
                        Text(text.displayName).tag(text)
                    }
                }
                SettingRow(icon: "photo",
                           title: Loc.t("封面取色", "Take the color from the cover"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.musicCoverColor))
                }
                SettingRow(icon: "chart.bar",
                           title: Loc.t("显示播放进度", "Show playback progress"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.musicIndicatorProgress))
                }
            } header: {
                Text(Loc.t("收起形态", "Collapsed form"))
            } footer: {
                Text(Loc.t("收起形态里的音乐显示方式。",
                           "How music appears in the collapsed form."))
            }

            Section {
                SettingRow(icon: "quote.bubble",
                           title: Loc.t("获取歌词", "Fetch lyrics"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.lyricsEnabled))
                }
                SettingRow(icon: "globe",
                           title: Loc.t("显示翻译", "Show translation"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.showLyricsTranslation))
                }
                SettingsSliderGroup(icon: "timer",
                                    title: Loc.t("歌词延迟", "Lyric delay"),
                                    description: nil,
                                    items: [
                                        SettingsSliderItem(title: Loc.t("歌词延迟", "Lyric delay"),
                                                           value: model.intSetting(\.lyricDelayMs),
                                                           range: DeckSettings.lyricDelayRange, step: 10,
                                                           suffix: Loc.t("毫秒", "ms"))
                                    ])
            } header: {
                Text(Loc.t("歌词", "Lyrics"))
            } footer: {
                Text(Loc.t("歌词来自 LRCLIB、网易云音乐与 QQ 音乐的公开接口。换行按固定的轮询节拍判定，这里把歌词整体挪动 −1000–1000 毫秒：正数延后显示，负数提前显示，用来和声音对齐。",
                           "Lyrics come from the public LRCLIB, NetEase Cloud Music and QQ Music endpoints. Line changes are detected on a fixed polling beat, so the whole lyric can be shifted by −1000–1000 ms: positive values show it later, negative values earlier."))
            }

            Section {
                SettingRow(icon: "checkmark.seal",
                           title: Loc.t("系统媒体来源", "System media source"),
                           description: adapterStatus) {
                    Button(Loc.t("检查", "Check")) { check() }
                }
            } header: {
                Text(Loc.t("系统媒体来源", "System media source"))
            } footer: {
                Text(Loc.t("macOS 15.4 起，第三方应用读取系统「正在播放」需要 mediaremote 适配器，它随应用一起打包。",
                           "Since macOS 15.4, third-party apps need the mediaremote adapter to read the system now-playing state; it ships with the app."))
            }
        }
        .formStyle(.grouped)
    }

    private func check() {
        adapterStatus = Loc.t("检查中…", "Checking…")
        Task {
            let adapter = MediaRemoteAdapter(resources: MediaRemoteResources.directory)
            let ok = await adapter.isFunctional()
            adapterStatus = ok ? Loc.t("可用", "Available") : Loc.t("不可用", "Unavailable")
        }
    }
}

struct HotkeySection: View {
    @EnvironmentObject private var model: DeckModel

    var body: some View {
        Form {
            Section {
                SettingRow(icon: "eye.slash",
                           title: Loc.t("隐藏面板", "Hide the panel"),
                           description: nil) {
                    HotkeyField(value: model.setting(\.hideHotkey))
                }
                SettingRow(icon: "chevron.up.square",
                           title: Loc.t("展开面板", "Expand the panel"),
                           description: nil) {
                    HotkeyField(value: model.setting(\.expandHotkey))
                }
            } header: {
                Text(Loc.t("全局快捷键", "Global shortcuts"))
            } footer: {
                Text(Loc.t("点击输入框后按下组合键；按 Esc 清除。例如 ⌃⌥B。",
                           "Click the field and press a key combination; press Esc to clear it. For example ⌃⌥B."))
            }
        }
        .formStyle(.grouped)
    }
}

struct HotkeyField: View {
    @Binding var value: String
    @State private var recording = false

    var body: some View {
        Button {
            recording.toggle()
        } label: {
            Text(recording ? Loc.t("请按组合键…", "Press a combination…") : displayText)
                .frame(width: 158)
        }
        .buttonStyle(.bordered)
        .background(
            KeyCaptureView(active: recording) { hotkey in
                recording = false
                value = hotkey?.encoded ?? ""
            }
        )
    }

    private var displayText: String {
        value.isEmpty ? Loc.t("未设置", "Not set") : (Hotkey.decode(value)?.display ?? value)
    }
}

// 捕获按键组合的 AppKit 视图
struct KeyCaptureView: NSViewRepresentable {
    var active: Bool
    var onCapture: (Hotkey?) -> Void

    func makeNSView(context: Context) -> NSView { CaptureView(active: active, onCapture: onCapture) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CaptureView)?.update(active: active, onCapture: onCapture)
    }

    final class CaptureView: NSView {
        private var active: Bool
        private var onCapture: (Hotkey?) -> Void
        private var monitor: Any?

        init(active: Bool, onCapture: @escaping (Hotkey?) -> Void) {
            self.active = active
            self.onCapture = onCapture
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

        func update(active: Bool, onCapture: @escaping (Hotkey?) -> Void) {
            self.active = active
            self.onCapture = onCapture
            if active && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, self.active else { return event }
                    if event.keyCode == 53 {
                        self.onCapture(nil)
                        self.active = false
                        return nil
                    }
                    guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
                    let hotkey = Hotkey(key: String(characters.prefix(1)), modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
                    self.onCapture(hotkey)
                    self.active = false
                    return nil
                }
            } else if !active, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

struct AboutSection: View {
    @EnvironmentObject private var model: DeckModel

    var body: some View {
        Form {
            Section {
                SettingRow(icon: "folder",
                           title: Loc.t("数据目录", "Data folder"),
                           description: SupportFiles.directory.path(percentEncoded: false)) {
                    Button(Loc.t("打开", "Open")) {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: SupportFiles.directory.path(percentEncoded: false))
                    }
                }
                SettingRow(icon: "power",
                           title: Loc.t("退出 WoodDeck", "Quit WoodDeck"),
                           description: Loc.t("关闭面板并从菜单栏移除，接入的助手不再上报会话。",
                                              "Closes the panel and removes the menu bar item; assistants stop reporting sessions.")) {
                    Button(Loc.t("退出", "Quit")) {
                        NSApp.terminate(nil)
                    }
                    .keyboardShortcut("q", modifiers: .command)
                }
                SettingRow(icon: "arrow.counterclockwise",
                           title: Loc.t("重置设置", "Reset settings"),
                           description: Loc.t("恢复默认值，保留界面语言与收起样式。",
                                              "Restores the defaults, keeping the language and the collapsed style.")) {
                    Button(Loc.t("重置", "Reset")) {
                        model.update { settings in
                            let language = settings.language
                            let style = settings.style
                            settings = DeckSettings()
                            settings.language = language
                            settings.style = style
                        }
                    }
                }
            } header: {
                Text("WoodDeck")
            } footer: {
                Text(Loc.t("在屏幕顶部显示 AI 编程工具的额度与用量，以及正在播放的音乐。只读取本机应用已有的登录状态与用量记录，登录令牌只在内存中使用。",
                           "Quotas and usage for AI coding tools, plus the music that is playing, at the top of the screen. Only the sign-in state and usage records already on this Mac are read; tokens stay in memory."))
            }
        }
        .formStyle(.grouped)
    }
}
