import SwiftUI
import AppKit

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var detailsWindow: NSWindow?
    // 设置窗口在前台时按 Cmd+Q 直接退出：应用是 accessory，没有系统默认的主菜单
    private var quitMonitor: Any?
    // 设置窗口出现时回调，外部据此收起灵动岛
    var onWillShow: (() -> Void)?

    func show() {
        onWillShow?()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        installQuitMonitor()
    }

    // 设置窗口：输入框只在用户点击它或按 Tab 时获得焦点；在输入框以外的地方按下鼠标时结束编辑
    final class SettingsNSWindow: NSWindow {
        // 窗口打开、成为键盘窗口时，AppKit 与 SwiftUI 会自动把第一个输入框设为焦点。
        // 不是由本窗口里的点击或按键引起的输入框焦点请求一律拒绝
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if responder is NSTextField || responder is NSText, !userIsInteracting {
                Self.rejectedAutoFocus += 1
                return false
            }
            return super.makeFirstResponder(responder)
        }

        // 自检用：拒绝过几次自动设置的输入框焦点
        static var rejectedAutoFocus = 0

        // 最近一次点到输入框或按键的时刻。SwiftUI 会在事件处理完之后的下一轮才把焦点交给输入框，
        // 所以按时间窗口判定这次焦点请求是否由用户操作引起
        private var lastInteractionAt: TimeInterval = 0

        private var userIsInteracting: Bool {
            ProcessInfo.processInfo.systemUptime - lastInteractionAt < 0.5
        }

        override func sendEvent(_ event: NSEvent) {
            switch event.type {
            case .leftMouseDown:
                if clickHitsTextInput(event) {
                    lastInteractionAt = ProcessInfo.processInfo.systemUptime
                } else if firstResponder is NSText {
                    // 结束编辑会让输入框按当前文字提交数值
                    _ = makeFirstResponder(nil)
                }
            case .keyDown:
                lastInteractionAt = ProcessInfo.processInfo.systemUptime
            default:
                break
            }
            super.sendEvent(event)
        }

        private func clickHitsTextInput(_ event: NSEvent) -> Bool {
            guard let root = contentView?.superview ?? contentView else { return false }
            var view = root.hitTest(root.convert(event.locationInWindow, from: nil))
            while let current = view {
                if current is NSTextField || current is NSText { return true }
                view = current.superview
            }
            return false
        }
    }

    private func installQuitMonitor() {
        guard quitMonitor == nil else { return }
        quitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "q" {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
    }

    // 建一个设置窗口并读它的工具栏信息。shown 为真时先真正显示一遍（透明、不激活），
    // 这样读到的是 SwiftUI 显示后装好的工具栏，并且可以实际收起、展开一次侧栏
    func inspectOffscreen(shown: Bool = false) -> [String] {
        let window = makeWindow()
        if shown {
            window.alphaValue = 0
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        } else {
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        }
        var lines: [String] = []
        let items = window.toolbar?.items ?? []
        lines.append("工具栏条目数：\(items.count)")
        for item in items {
            let action = item.action.map { NSStringFromSelector($0) } ?? "-"
            lines.append("  id=\(item.itemIdentifier.rawValue) action=\(action) visible=\(item.isVisible)")
        }
        let toggle = items.first { item in
            (item.action.map { NSStringFromSelector($0) } ?? "") == "toggleSidebar:"
                || item.itemIdentifier.rawValue.lowercased().contains("sidebar")
        }
        lines.append("含侧栏折叠按钮：\(toggle != nil)")
        lines.append("窗口尺寸：\(Int(window.frame.width))x\(Int(window.frame.height)) 标题=\(window.title) 副标题=\(window.subtitle)")
        lines.append("标题栏透明：\(window.titlebarAppearsTransparent) 工具栏样式=\(window.toolbarStyle.rawValue) 内容铺满标题栏=\(window.styleMask.contains(.fullSizeContentView))")
        if shown, let content = window.contentView {
            lines.append("侧栏宽度：\(Self.sidebarWidths(in: content))")
            // 工具栏按钮是 SwiftUI 自己画的视图，没有 action，直接调用分栏控制器的同一个操作
            guard let controller = Self.splitView(in: content)?.delegate as? NSSplitViewController else {
                lines.append("没有找到分栏控制器")
                window.orderOut(nil)
                window.contentView = nil
                return lines
            }
            for step in ["收起一次后", "再展开一次后"] {
                controller.toggleSidebar(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                lines.append("\(step)侧栏宽度：\(Self.sidebarWidths(in: content))")
            }
        }
        window.orderOut(nil)
        window.contentView = nil
        return lines
    }

    // 焦点自检：窗口透明，成为键盘窗口但不激活应用，所以按键仍然进入用户正在用的应用。
    // 鼠标事件直接交给本窗口的 sendEvent，不经过系统输入
    func inspectFocus() -> [String] {
        let window = makeWindow()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        var lines: [String] = []
        func responder() -> String {
            guard let current = window.firstResponder else { return "无" }
            return current is NSText ? "输入框（\(type(of: current))）" : "\(type(of: current))"
        }
        let opened = window.firstResponder is NSText
        lines.append("打开后的焦点：\(responder()) \(opened ? "✗" : "✓")")
        guard let root = window.contentView, let field = Self.firstTextField(in: root) else {
            lines.append("没有找到输入框")
            window.orderOut(nil)
            window.contentView = nil
            return lines
        }
        let hitRoot = root.superview ?? root
        field.scrollToVisible(field.bounds)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let fieldRect = field.convert(field.bounds, to: nil)
        let hit = hitRoot.hitTest(hitRoot.convert(NSPoint(x: fieldRect.midX, y: fieldRect.midY), from: nil))
        lines.append("输入框：值=\(field.stringValue) 窗口内位置=\(fieldRect) 命中=\(hit.map { "\(type(of: $0))" } ?? "无")")
        // 与打开窗口时的自动焦点相同：没有用户操作时直接请求把焦点交给输入框
        let accepted = window.makeFirstResponder(field)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let autoBlocked = !accepted && !(window.firstResponder is NSText)
        lines.append("没有用户操作时请求输入框焦点：\(accepted ? "被接受" : "被拒绝")，焦点=\(responder()) \(autoBlocked ? "✓" : "✗")")
        lines.append("累计拒绝的自动焦点请求：\(SettingsNSWindow.rejectedAutoFocus) 次")
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                window.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        click(NSPoint(x: fieldRect.midX, y: fieldRect.midY))
        let entered = window.firstResponder is NSText
        lines.append("点击输入框后的焦点：\(responder()) \(entered ? "✓" : "✗")")
        // 改一下文字，点击别处后应当按新文字提交，结束时恢复原值
        let original = DeckModel.shared.settings.openDelay
        let typed = original == 450 ? 460 : 450
        if let editor = window.firstResponder as? NSTextView {
            editor.selectAll(nil)
            editor.insertText("\(typed)", replacementRange: editor.selectedRange())
        }
        // 同一行左侧的标题文字处
        click(NSPoint(x: fieldRect.minX - 260, y: fieldRect.midY))
        let left = !(window.firstResponder is NSText)
        lines.append("点击输入框以外的地方后的焦点：\(responder()) \(left ? "✓" : "✗")")
        let committed = DeckModel.shared.settings.openDelay
        lines.append("输入 \(typed) 后点击别处，停留时间=\(committed) \(committed == typed ? "✓" : "✗")")
        DeckModel.shared.update { $0.openDelay = original }
        window.orderOut(nil)
        window.contentView = nil
        return lines
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews {
            if let found = firstTextField(in: child) { return found }
        }
        return nil
    }

    // 找出分栏视图
    private static func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let found = splitView(in: child) { return found }
        }
        return nil
    }

    // 报告分栏第一栏（侧栏）的宽度与是否收起
    private static func sidebarWidths(in view: NSView) -> String {
        guard let split = splitView(in: view), let first = split.arrangedSubviews.first else { return "没有分栏视图" }
        let collapsed = split.isSubviewCollapsed(first) || first.isHidden
        return "\(Int(first.frame.width)) 点\(collapsed ? "（已收起）" : "")"
    }

    // 只显示不抢焦点，用于截图自检
    // 自检用：拿到已创建的窗口，不激活
    func inspectWindowForTest() -> NSWindow? {
        if let window { return window }
        let window = makeWindow()
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        self.window = window
        return window
    }

    func showForCapture() -> NSWindow {
        let window = makeWindow()
        window.orderFrontRegardless()
        return window
    }

    // 统一创建窗口，show() 与离屏自检共用
    private func makeWindow() -> NSWindow {
        let view = SettingsView()
            .environmentObject(DeckModel.shared)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        // 页面标题与侧栏按钮交给窗口的工具栏
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 620)
        hosting.autoresizingMask = [.width, .height]
        let window = SettingsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered,
                                      defer: false)
        window.title = Loc.t("WoodDeck 设置", "WoodDeck Settings")
        window.toolbarStyle = .unified
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.layoutIfNeeded()
        window.setContentSize(NSSize(width: 800, height: 620))
        window.contentMinSize = NSSize(width: 700, height: 520)
        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                          y: visible.midY - size.height / 2))
        }
        return window
    }

    func showDetails(columnID: UUID, days: Int = 7) {
        let view = ModelDetailsView(columnID: columnID, initialDays: days)
            .environmentObject(DeckModel.shared)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = Loc.t("模型明细", "Model details")
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 460, height: 300)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        detailsWindow = window
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, clock, music, sessions, providers, hotkeys, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: Loc.t("通用", "General")
        case .appearance: Loc.t("外观", "Appearance")
        case .clock: Loc.t("时间", "Clock")
        case .music: Loc.t("音乐", "Music")
        case .sessions: Loc.t("会话通知", "Sessions")
        case .providers: Loc.t("配额与统计", "Quota and usage")
        case .hotkeys: Loc.t("快捷键", "Shortcuts")
        case .about: Loc.t("关于", "About")
        }
    }

    // 工具栏里标题下方的一行说明
    var subtitle: String {
        switch self {
        case .general: Loc.t("启动、语言、页面与展开方式", "Startup, language, pages and expanding")
        case .appearance: Loc.t("收起样式、尺寸、配色与动画", "Collapsed style, size, colours and motion")
        case .clock: Loc.t("收起形态里时间的样式与颜色", "Clock style and colour when collapsed")
        case .music: Loc.t("播放来源、歌词与律动条", "Sources, lyrics and the equalizer")
        case .sessions: Loc.t("编程助手的会话读取与提醒", "Coding assistant sessions and alerts")
        case .providers: Loc.t("配额来源、用量统计与提醒", "Quota sources, usage and alerts")
        case .hotkeys: Loc.t("键盘快捷键", "Keyboard shortcuts")
        case .about: Loc.t("版本与致谢", "Version and credits")
        }
    }

    // 侧栏图标块里的白色符号
    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .clock: "clock.fill"
        case .music: "music.note"
        case .sessions: "bell.badge.fill"
        case .providers: "chart.bar.fill"
        case .hotkeys: "keyboard.fill"
        case .about: "info"
        }
    }

    // 每一页自己的颜色：侧栏图标块的底色，也是这一页各行图标的颜色
    var tint: Color {
        switch self {
        case .general: .blue
        case .appearance: .purple
        case .clock: .orange
        case .music: .pink
        case .sessions: .red
        case .providers: .green
        case .hotkeys: .indigo
        case .about: .teal
        }
    }
}

// 系统设置样式的图标块：圆角方块填充渐变色，中间是白色符号
struct SettingsIconTile: View {
    let symbol: String
    let tint: Color
    var side: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
            .fill(tint.gradient)
            .frame(width: side, height: side)
            .overlay {
                // 按方块内的固定区域缩放，宽或高的符号都不会超出方块
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .frame(width: side * 0.58, height: side * 0.58)
            }
    }
}

extension EnvironmentValues {
    // 当前设置页的颜色，SettingRow 用它给行首图标着色
    @Entry var settingsTint: Color = .secondary
}

struct SettingsView: View {
    @State private var selection: SettingsSection
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private let showsSidebar: Bool

    init(initialSection: SettingsSection = .general, showsSidebar: Bool = true) {
        _selection = State(initialValue: initialSection)
        self.showsSidebar = showsSidebar
    }

    var body: some View {
        if showsSidebar {
            // 侧栏用系统的半透明材质，工具栏里的按钮可以收起和展开侧栏；
            // 页面标题与说明放在工具栏，表单在工具栏下方滚动并柔和淡出
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            } detail: {
                detail
                    .navigationTitle(selection.title)
                    .navigationSubtitle(selection.subtitle)
            }
            .frame(minWidth: 700, minHeight: 520)
        } else {
            // 截图只画右侧表单，补上窗口底色
            detail
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            ForEach(SettingsSection.allCases) { section in
                Label {
                    Text(section.title)
                } icon: {
                    SettingsIconTile(symbol: section.icon, tint: section.tint)
                }
                .tag(section)
            }
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    // List 的选中值可以为空，点空白处时保持当前页
    private var sidebarSelection: Binding<SettingsSection?> {
        Binding(get: { selection }, set: { value in
            if let value { selection = value }
        })
    }

    private var detail: some View {
        page
            .id(selection)
            .environment(\.settingsTint, selection.tint)
            // 分组卡片直接放在窗口底色上
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var page: some View {
        switch selection {
        case .general: GeneralSection()
        case .appearance: AppearanceSection()
        case .clock: ClockSection()
        case .music: MusicSection()
        case .sessions: SessionNotificationSection()
        case .providers: ProvidersSection()
        case .hotkeys: HotkeySection()
        case .about: AboutSection()
        }
    }
}

struct GeneralSection: View {
    @EnvironmentObject private var model: DeckModel

    var body: some View {
        Form {
            Section {
                SettingRow(icon: "power",
                           title: Loc.t("登录时启动", "Launch at login"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.launchAtStartup))
                }
                SettingsPickerRow(icon: "globe",
                                  title: Loc.t("界面语言", "Language"),
                                  description: nil,
                                  selection: language) {
                    ForEach(Language.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
            } header: {
                Text(Loc.t("启动与语言", "Startup and language"))
            } footer: {
                Text(Loc.t("登录时启动会在系统里注册登录项。",
                           "Launching at login registers a login item with the system."))
            }

            Section {
                SettingsPickerRow(icon: "rectangle.on.rectangle",
                                  title: Loc.t("打开时的页面", "Page on open"),
                                  description: nil,
                                  selection: model.setting(\.defaultPage)) {
                    ForEach(DefaultDeckPage.allCases) { page in
                        Text(page.displayName).tag(page)
                    }
                }
                SettingRow(icon: "chart.bar.fill",
                           title: Loc.t("显示额度页", "Show the quota page"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.quotaPage))
                }
                SettingRow(icon: "bubble.left.and.bubble.right.fill",
                           title: Loc.t("显示会话页", "Show the sessions page"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.sessionsPage))
                }
                SettingRow(icon: "music.note",
                           title: Loc.t("显示音乐页", "Show the music page"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.musicPage))
                }
                SettingRow(icon: "cpu",
                           title: Loc.t("显示监控页", "Show the monitor page"),
                           description: Loc.t("CPU、内存、网络与占用最高的应用", "CPU, memory, network and the busiest apps")) {
                    SettingsSwitch(isOn: model.setting(\.monitorPage))
                }
                SettingRow(icon: "gauge.with.dots.needle.bottom.50percent",
                           title: Loc.t("收起时显示系统读数", "Show system readings when collapsed"),
                           description: Loc.t("在刘海或胶囊里显示 CPU、内存与网络", "Show CPU, memory and network in the notch or capsule")) {
                    SettingsSwitch(isOn: model.setting(\.monitorInCompact))
                }
                if model.settings.monitorInCompact {
                    SettingRow(icon: "cpu",
                               title: Loc.t("读数：CPU", "Reading: CPU"),
                               description: nil) {
                        SettingsSwitch(isOn: model.setting(\.monitorCpu))
                    }
                    SettingRow(icon: "memorychip",
                               title: Loc.t("读数：内存", "Reading: memory"),
                               description: nil) {
                        SettingsSwitch(isOn: model.setting(\.monitorMemory))
                    }
                    SettingRow(icon: "network",
                               title: Loc.t("读数：网络", "Reading: network"),
                               description: nil) {
                        SettingsSwitch(isOn: model.setting(\.monitorNetwork))
                    }
                }
                SettingRow(icon: "cursorarrow.click",
                           title: Loc.t("右键面板打开设置", "Right-click opens Settings"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.rightClickSettings))
                }
                SettingsPickerRow(icon: "hand.tap",
                                  title: Loc.t("展开方式", "Expand with"),
                                  description: nil,
                                  selection: model.setting(\.expandTrigger)) {
                    ForEach(ExpandTrigger.allCases) { trigger in
                        Text(trigger.displayName).tag(trigger)
                    }
                }
                SettingsSliderGroup(icon: "timer",
                                    title: Loc.t("停留时间", "Dwell time"),
                                    description: nil,
                                    items: [
                                        SettingsSliderItem(title: Loc.t("停留时间", "Dwell time"),
                                                           value: model.intSetting(\.openDelay),
                                                           range: 0...2000, step: 50,
                                                           suffix: Loc.t("毫秒", "ms"))
                                    ])
                    .disabled(model.settings.expandTrigger == .click)
            } header: {
                Text(Loc.t("面板", "Panel"))
            } footer: {
                Text(dwellNote)
            }

            Section {
                SettingRow(icon: "wand.and.stars",
                           title: Loc.t("使用动画", "Use animations"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.animations))
                }
                SettingsSliderGroup(icon: "speedometer",
                                    title: Loc.t("动画与延迟", "Animation and delays"),
                                    description: nil,
                                    items: [
                                        SettingsSliderItem(title: Loc.t("动画时长", "Animation duration"),
                                                           value: model.intSetting(\.animationDuration),
                                                           range: 0...1200, step: 20,
                                                           suffix: Loc.t("毫秒", "ms")),
                                        SettingsSliderItem(title: Loc.t("收起延迟", "Close delay"),
                                                           value: model.intSetting(\.closeDelay),
                                                           range: 0...2000, step: 50,
                                                           suffix: Loc.t("毫秒", "ms"))
                                    ])
            } header: {
                Text(Loc.t("动画与延迟", "Animation and delays"))
            } footer: {
                Text(Loc.t("动画时长 0–1200 毫秒，收起延迟 0–2000 毫秒。",
                           "Animation duration 0–1200 ms, close delay 0–2000 ms."))
            }

            Section {
                SettingsPickerRow(icon: "macwindow",
                                  title: Loc.t("全屏应用在最前面时", "When a full-screen app is in front"),
                                  description: nil,
                                  selection: model.setting(\.fullscreenBehavior)) {
                    ForEach(WindowBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
            } header: {
                Text(Loc.t("全屏", "Full screen"))
            } footer: {
                Text(Loc.t("全屏应用在最前面时按这里的选择处理。",
                           "This choice applies while a full-screen app is in front."))
            }
        }
        .formStyle(.grouped)
    }

    private var dwellNote: String {
        model.settings.expandTrigger == .click
            ? Loc.t("点击展开时不需要停留。", "Expanding on click does not use a dwell time.")
            : Loc.t("停留时间是鼠标在面板上停留多久后展开。",
                    "The dwell time is how long the pointer rests on the panel before it expands.")
    }

    private var language: Binding<Language> {
        Binding(get: { model.settings.language },
                set: { value in
                    model.update { $0.language = value }
                    Loc.language = value.resolved
                })
    }
}

struct AppearanceSection: View {
    @EnvironmentObject private var model: DeckModel
    @State private var screens: [ScreenInfo] = ScreenCatalog.current()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Loc.t("面板配色", "Panel theme"))
                        .fontWeight(.medium)
                    Text(Loc.t("收起形态与展开面板共用的底色、描边与强调色。",
                               "Surface, stroke and accent shared by the collapsed form and the panel."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    themePicker
                        .padding(.top, 2)
                }
                .padding(.vertical, 4)
            } header: {
                Text(Loc.t("配色", "Colors"))
            }

            Section {
                SettingsPickerRow(icon: "rectangle.topthird.inset.filled",
                                  title: Loc.t("样式", "Style"),
                                  description: nil,
                                  selection: model.setting(\.style),
                                  width: 264,
                                  isSegmented: true) {
                    ForEach(CompactStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            } header: {
                Text(Loc.t("收起样式", "Collapsed style"))
            } footer: {
                Text(Loc.t("刘海、胶囊与指示条三种收起形态。",
                           "Three collapsed forms: notch, capsule and indicator."))
            }

            Section {
                SettingRow(icon: "chart.bar",
                           title: Loc.t("显示额度", "Show quotas"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.showQuota))
                }
                SettingRow(icon: "music.note",
                           title: Loc.t("显示音乐", "Show music"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.showMusic))
                }
                SettingRow(icon: "bell",
                           title: Loc.t("显示会话", "Show sessions"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.showSessions))
                }
                SettingRow(icon: "clock",
                           title: Loc.t("显示时间", "Show the clock"),
                           description: nil) {
                    SettingsSwitch(isOn: model.setting(\.showClock))
                }
            } header: {
                Text(Loc.t("显示内容", "Content"))
            } footer: {
                Text(Loc.t("三种形态共用这四项选择。",
                           "All three forms share these four choices."))
            }

            Section {
                SettingsPickerRow(icon: "rectangle.split.2x1",
                                  title: Loc.t("排版", "Layout"),
                                  description: nil,
                                  selection: model.setting(\.notchLayout)) {
                    ForEach(NotchLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                if model.settings.notchLayout == .split {
                    SettingRow(icon: "tag",
                               title: Loc.t("显示角落标签", "Show the corner labels"),
                               description: nil) {
                        SettingsSwitch(isOn: model.setting(\.showCornerTags))
                    }
                }
                if model.settings.notchLayout == .split {
                    notchSegmentPageRows
                }
                SettingsSliderGroup(icon: "ruler",
                                    title: Loc.t("尺寸与位置", "Size and position"),
                                    description: nil,
                                    items: notchItems)
            } header: {
                Text(Loc.t("刘海", "Notch"))
            } footer: {
                Text(notchNote)
            }

            Section {
                SettingsSliderGroup(icon: "capsule",
                                    title: Loc.t("尺寸与位置", "Size and position"),
                                    description: nil,
                                    items: [
                                        SettingsSliderItem(title: Loc.t("宽度", "Width"),
                                                           value: model.setting(\.capsuleWidth),
                                                           range: CollapsedLimits.capsuleWidthRange, step: 2,
                                                           suffix: "pt"),
                                        SettingsSliderItem(title: Loc.t("高度", "Height"),
                                                           value: model.setting(\.capsuleHeight),
                                                           range: CollapsedLimits.capsuleHeightRange, step: 1,
                                                           suffix: "pt"),
                                        SettingsSliderItem(title: Loc.t("距顶部", "Distance from top"),
                                                           value: model.setting(\.capsuleTop),
                                                           range: 0...40, step: 1,
                                                           suffix: "pt"),
                                        SettingsSliderItem(title: Loc.t("水平位置", "Horizontal offset"),
                                                           value: model.setting(\.capsuleOffsetX),
                                                           range: -600...600, step: 2,
                                                           suffix: "pt")
                                    ])
            } header: {
                Text(Loc.t("胶囊", "Capsule"))
            } footer: {
                Text(Loc.t("宽度 140–800 pt，高度 24–64 pt，距顶部 0–40 pt，水平位置 −600–600 pt。",
                           "Width 140–800 pt, height 24–64 pt, distance from top 0–40 pt, offset −600–600 pt."))
            }

            Section {
                SettingsSliderGroup(icon: "minus",
                                    title: Loc.t("尺寸与位置", "Size and position"),
                                    description: nil,
                                    items: [
                                        SettingsSliderItem(title: Loc.t("长度", "Length"),
                                                           value: model.setting(\.lineLength),
                                                           range: CollapsedLimits.lineLengthRange, step: 2,
                                                           suffix: "pt"),
                                        SettingsSliderItem(title: Loc.t("厚度", "Thickness"),
                                                           value: model.setting(\.lineThickness),
                                                           range: CollapsedLimits.lineThicknessRange, step: 0.5,
                                                           suffix: "pt"),
                                        SettingsSliderItem(title: Loc.t("距顶部", "Distance from top"),
                                                           value: model.setting(\.lineTop),
                                                           range: 0...16, step: 0.5,
                                                           suffix: "pt"),
                                        SettingsSliderItem(title: Loc.t("水平位置", "Horizontal offset"),
                                                           value: model.setting(\.lineOffsetX),
                                                           range: -600...600, step: 2,
                                                           suffix: "pt")
                                    ])
            } header: {
                Text(Loc.t("指示条", "Indicator"))
            } footer: {
                Text(Loc.t("长度 24–600 pt，厚度 2–8 pt，距顶部 0–16 pt，水平位置 −600–600 pt。",
                           "Length 24–600 pt, thickness 2–8 pt, distance from top 0–16 pt, offset −600–600 pt."))
            }

            Section {
                SettingRow(icon: "square.grid.2x2",
                           title: Loc.t("快捷尺寸", "Presets"),
                           description: nil) {
                    HStack(spacing: 8) {
                        ForEach(PanelSize.allCases) { size in
                            presetButton(size)
                        }
                    }
                }
                SettingsSliderGroup(icon: "ruler",
                                    title: Loc.t("展开面板尺寸", "Expanded panel size"),
                                    description: nil,
                                    items: [
                                        SettingsSliderItem(title: Loc.t("宽度", "Width"),
                                                           value: model.setting(\.width),
                                                           range: 440...1200, step: 10,
                                                           suffix: "pt"),
                                        SettingsSliderItem(title: Loc.t("高度", "Height"),
                                                           value: model.setting(\.height),
                                                           range: 140...400, step: 10,
                                                           suffix: "pt")
                                    ])
            } header: {
                Text(Loc.t("展开面板尺寸", "Expanded panel size"))
            } footer: {
                Text(Loc.t("宽度 440–1200 pt，高度 140–400 pt。",
                           "Width 440–1200 pt, height 140–400 pt."))
            }

            Section {
                SettingsPickerRow(icon: "display",
                                  title: Loc.t("显示位置", "Show on"),
                                  description: nil,
                                  selection: displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if model.settings.displayMode == .specific {
                    SettingsPickerRow(icon: "rectangle.on.rectangle",
                                      title: Loc.t("显示屏", "Display"),
                                      description: nil,
                                      selection: model.setting(\.displayID),
                                      width: 220) {
                        ForEach(displayChoices) { screen in
                            Text(displayLabel(screen)).tag(screen.id)
                        }
                    }
                }
            } header: {
                Text(Loc.t("显示屏", "Display"))
            } footer: {
                Text(Loc.t("选定的屏幕断开后回到主显示屏。",
                           "When the chosen display disconnects, the panel returns to the main display."))
            }
        }
        .formStyle(.grouped)
        .onAppear { screens = ScreenCatalog.current() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = ScreenCatalog.current()
        }
    }

    // 六套面板配色：每个色块直接画出该配色下的收起形态底色、强调色与警示色
    private var themePicker: some View {
        HStack(spacing: 10) {
            ForEach(PanelThemeCatalog.all, id: \.id) { palette in
                themeSwatch(palette)
            }
            Spacer(minLength: 0)
        }
    }

    private func themeSwatch(_ palette: PanelPalette) -> some View {
        let selected = model.settings.panelTheme == palette.id
        return Button {
            model.update { $0.panelTheme = palette.id }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.surfaceColor)
                        .frame(width: 62, height: 38)
                    HStack(spacing: 4) {
                        Capsule()
                            .fill(palette.accentColor)
                            .frame(width: 16, height: 4)
                        Circle()
                            .fill(palette.dangerColor)
                            .frame(width: 5, height: 5)
                        Circle()
                            .fill(palette.primaryText)
                            .frame(width: 5, height: 5)
                            .opacity(0.6)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.28),
                                      lineWidth: selected ? 2 : 1)
                )
                Text(Loc.t(palette.name, palette.nameEn))
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 66)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Loc.t(palette.name, palette.nameEn))
    }

    private var notchItems: [SettingsSliderItem] {
        var items = [
            SettingsSliderItem(title: Loc.t("宽度", "Width"),
                               value: model.setting(\.notchWidth),
                               range: CollapsedLimits.notchWidthRange, step: 2,
                               suffix: "pt"),
            SettingsSliderItem(title: Loc.t("高度", "Height"),
                               value: model.setting(\.notchHeight),
                               range: CollapsedLimits.notchHeightRange, step: 1,
                               suffix: "pt")
        ]
        if model.settings.notchLayout == .split {
            items.append(SettingsSliderItem(title: Loc.t("音乐侧宽度", "Music side width"),
                                            value: model.setting(\.notchLeftWidth),
                                            range: 100...320, step: 2,
                                            suffix: "pt"))
            items.append(SettingsSliderItem(title: Loc.t("AI 侧宽度", "AI side width"),
                                            value: model.setting(\.notchRightWidth),
                                            range: 56...200, step: 2,
                                            suffix: "pt"))
        }
        items.append(SettingsSliderItem(title: Loc.t("水平位置", "Horizontal offset"),
                                        value: model.setting(\.notchOffsetX),
                                        range: -600...600, step: 2,
                                        suffix: "pt"))
        return items
    }

    // 分列布局下左右两段各自打开哪一页
    private var notchSegmentPageRows: some View {
        Group {
            SettingsPickerRow(icon: "sidebar.left",
                              title: Loc.t("悬停左侧打开的页面", "Page opened on the left"),
                              description: Loc.t("默认是音乐；选「不做特殊处理」就按面板当前的页面展开",
                                                 "Music by default; pick No specific page to open whatever page the panel is on"),
                              selection: model.setting(\.notchLeftPage)) {
                ForEach(NotchSegmentPage.allCases) { page in
                    Text(page.displayName).tag(page)
                }
            }
            SettingsPickerRow(icon: "sidebar.right",
                              title: Loc.t("悬停右侧打开的页面", "Page opened on the right"),
                              description: Loc.t("默认是会话；选「不做特殊处理」就按面板当前的页面展开",
                                                 "Sessions by default; pick No specific page to open whatever page the panel is on"),
                              selection: model.setting(\.notchRightPage)) {
                ForEach(NotchSegmentPage.allCases) { page in
                    Text(page.displayName).tag(page)
                }
            }
        }
    }

    private var notchNote: String {
        model.settings.notchLayout == .split
            ? Loc.t("分列时内容分别放在刘海左右两侧。宽度 180–800 pt，每侧宽度 72–240 pt，高度 24–64 pt，水平位置 −600–600 pt。",
                    "Split puts the content either side of the notch. Width 180–800 pt, side width 72–240 pt, height 24–64 pt, offset −600–600 pt.")
            : Loc.t("整体放在刘海下方。宽度 180–800 pt，高度 24–64 pt，水平位置 −600–600 pt。",
                    "The content sits below the notch. Width 180–800 pt, height 24–64 pt, offset −600–600 pt.")
    }

    @ViewBuilder
    private func presetButton(_ size: PanelSize) -> some View {
        if model.settings.currentPreset == size {
            Button(size.displayName) { apply(size) }.buttonStyle(.borderedProminent)
        } else {
            Button(size.displayName) { apply(size) }.buttonStyle(.bordered)
        }
    }

    private func apply(_ size: PanelSize) {
        model.update { settings in
            let value = settings.presetSize(size)
            settings.width = value.width
            settings.height = value.height
        }
    }

    private var displayMode: Binding<DisplayMode> {
        Binding(get: { model.settings.displayMode },
                set: { value in
                    let current = ScreenCatalog.current()
                    screens = current
                    model.update { settings in
                        settings.displayMode = value
                        if value == .specific, settings.displayID.isEmpty {
                            settings.displayID = current.first(where: \.isMain)?.id ?? current.first?.id ?? ""
                        }
                    }
                })
    }

    // 已断开的屏幕仍以占位项出现在列表里，避免当前选择丢失
    private var displayChoices: [ScreenInfo] {
        var list = screens
        let selected = model.settings.displayID
        if !selected.isEmpty, !list.contains(where: { $0.id == selected }) {
            list.append(ScreenInfo(id: selected,
                                   name: Loc.t("已断开", "Disconnected"),
                                   width: 0, height: 0,
                                   isMain: false, hasNotch: false))
        }
        return list
    }

    private func displayLabel(_ screen: ScreenInfo) -> String {
        guard screen.width > 0 else {
            return Loc.t("已断开（\(screen.id)）", "Disconnected (\(screen.id))")
        }
        var parts = [screen.name]
        if screen.isMain { parts.append(Loc.t("主显示屏", "Main")) }
        if screen.hasNotch { parts.append(Loc.t("有刘海", "Notch")) }
        parts.append("\(Int(screen.width))×\(Int(screen.height))")
        return parts.joined(separator: " · ")
    }
}
