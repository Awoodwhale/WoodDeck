import Foundation

enum CompactStyle: String, Codable, CaseIterable, Identifiable {
    case notch, capsule, line
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .notch: Loc.t("刘海", "Notch")
        case .capsule: Loc.t("胶囊", "Capsule")
        case .line: Loc.t("指示条", "Indicator")
        }
    }
}

enum SettingsTheme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: Loc.t("跟随系统", "Follow system")
        case .light: Loc.t("浅色", "Light")
        case .dark: Loc.t("深色", "Dark")
        }
    }
}

enum ClockStyle: String, Codable, CaseIterable, Identifiable {
    case minimal, stacked, digits, dots, segment, neon, serif, wide, condensed
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .minimal: Loc.t("简约", "Minimal")
        case .stacked: Loc.t("上下", "Stacked")
        case .digits: Loc.t("数码管", "Digits")
        case .dots: Loc.t("点阵", "Dots")
        case .segment: Loc.t("分段", "Segment")
        case .neon: Loc.t("霓虹", "Neon")
        case .serif: Loc.t("衬线", "Serif")
        case .wide: Loc.t("宽体", "Wide")
        case .condensed: Loc.t("窄体", "Condensed")
        }
    }
}

enum ClockColor: String, Codable, CaseIterable, Identifiable {
    case white, amber, cyan, pink, lime, gradient, cover, custom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .white: Loc.t("白色", "White")
        case .amber: Loc.t("琥珀", "Amber")
        case .cyan: "青色"
        case .pink: Loc.t("粉色", "Pink")
        case .lime: Loc.t("青柠", "Lime")
        case .gradient: Loc.t("渐变", "Gradient")
        case .cover: Loc.t("跟随封面", "Cover")
        case .custom: Loc.t("自定义", "Custom")
        }
    }
}

enum CompactMusicText: String, Codable, CaseIterable, Identifiable {
    case none, title, lyrics
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: Loc.t("不显示", "Nothing")
        case .title: Loc.t("歌名", "Song title")
        case .lyrics: Loc.t("歌词", "Lyrics")
        }
    }
}

enum DefaultDeckPage: String, Codable, CaseIterable, Identifiable {
    case last, quota, sessions, music, monitor
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .last: Loc.t("上次的页面", "Last page")
        case .quota: Loc.t("额度", "Quotas")
        case .sessions: Loc.t("会话", "Sessions")
        case .music: Loc.t("音乐", "Music")
        case .monitor: Loc.t("监控", "Monitor")
        }
    }
}

enum DeckPage: String, Codable, CaseIterable {
    case quota, sessions, music, monitor

    var displayName: String {
        switch self {
        case .quota: Loc.t("额度", "Quotas")
        case .sessions: Loc.t("会话", "Sessions")
        case .music: Loc.t("音乐", "Music")
        case .monitor: Loc.t("监控", "Monitor")
        }
    }

    var symbol: String {
        switch self {
        case .quota: "chart.bar.fill"
        case .sessions: "bubble.left.and.bubble.right.fill"
        case .music: "music.note"
        case .monitor: "cpu"
        }
    }
}

// 展开的触发方式
enum ExpandTrigger: String, Codable, CaseIterable, Identifiable {
    case hover, click

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hover: Loc.t("鼠标停留", "Pointer hover")
        case .click: Loc.t("点击", "Click")
        }
    }
}

// 刘海屏上收起形态的排版：内容分列在刘海两侧，还是整体放在刘海下方
enum NotchLayout: String, Codable, CaseIterable, Identifiable {
    case split, below

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .split: Loc.t("分列刘海两侧", "Bodies either side of the notch")
        case .below: Loc.t("整体在刘海下方", "A single body below the notch")
        }
    }
}

enum WindowBehavior: String, Codable, CaseIterable, Identifiable {
    case normal, line, hide
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .normal: Loc.t("不变化", "No change")
        case .line: Loc.t("指示条", "Indicator")
        case .hide: Loc.t("隐藏", "Hide")
        }
    }
}

enum PanelSize: String, Codable, CaseIterable, Identifiable {
    case compact, standard, spacious
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .compact: Loc.t("紧凑", "Compact")
        case .standard: Loc.t("标准", "Standard")
        case .spacious: Loc.t("宽敞", "Spacious")
        }
    }
}

enum PanelSizes {
    static func size(_ size: PanelSize, columns: Int) -> (width: Double, height: Double) {
        let count = max(1, columns)
        func round10(_ value: Double) -> Double { (value / 10).rounded(.up) * 10 }
        let pair: (Double, Double)
        switch (size, count) {
        case (.compact, 1): pair = (500, 170)
        case (.standard, 1): pair = (550, 200)
        case (.spacious, 1): pair = (630, 220)
        case (.compact, 2): pair = (500, 150)
        case (.standard, 2): pair = (520, 200)
        case (.spacious, 2): pair = (760, 310)
        case (.compact, 3): pair = (530, 160)
        case (.standard, 3): pair = (730, 240)
        case (.spacious, 3): pair = (860, 310)
        case (.compact, 4): pair = (700, 170)
        case (.standard, 4): pair = (760, 240)
        case (.spacious, 4): pair = (1100, 310)
        case (.compact, _): pair = (round10(Double(count) * 170 + 12), 170)
        case (.spacious, _): pair = (round10(Double(count) * 270 + 12), 310)
        default: pair = (round10(Double(count) * 187 + 12), 240)
        }
        return (min(max(pair.0, 440), 1200), min(max(pair.1, 140), 400))
    }
}

struct AppEntry: Codable, Identifiable, Hashable, Sendable {
    var instanceID: UUID = UUID()
    var quotaSource: ProviderID
    var usageSource: ProviderID?
    var site: String = ""
    var script: String = ""
    var secretRevision: UUID = UUID()
    var quotaOnline: Bool = true
    var displayName: String = ""
    var enabled: Bool = true
    var themeColor: String = ""
    var warningColor: String = ""
    var criticalColor: String = ""

    var id: UUID { instanceID }

    var resolvedUsageSource: ProviderID {
        if let usageSource, usageSource.isUsageSource { return usageSource }
        return quotaSource.isUsageSource ? quotaSource : .claude
    }

    var name: String { displayName.isEmpty ? quotaSource.displayName : displayName }

    var resolvedTheme: String { themeColor.isEmpty ? AppPresets.themeColor(quotaSource) : themeColor }
    var resolvedWarning: String { warningColor.isEmpty ? AppPresets.warningColor : warningColor }
    var resolvedCritical: String { criticalColor.isEmpty ? AppPresets.criticalColor : criticalColor }

    mutating func normalize() {
        if !(usageSource?.isUsageSource ?? false) {
            usageSource = quotaSource.isUsageSource ? quotaSource : .claude
        }
        site = ProviderCatalog.normalizeSite(site, removeV1: quotaSource != .custom)
        if quotaSource == .custom && script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            script = ProviderScripts.example
        }
        displayName = displayName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if displayName.count > 64 { displayName = String(displayName.prefix(64)) }
        themeColor = AppPresets.normalizeColor(themeColor)
        warningColor = AppPresets.normalizeColor(warningColor)
        criticalColor = AppPresets.normalizeColor(criticalColor)
    }
}

enum AppPresets {
    static let maximumApps = 7
    static let warningColor = "#E5C890"
    static let criticalColor = "#E78284"
    static let warningPercent: Double = 70
    static let criticalPercent: Double = 90
    static let minimumColumnWidth: Double = 150

    static let palette = [
        "#E5A385", "#F0B37E", "#E5C890", "#98DBB0", "#7FD1C4", "#9CB9FF",
        "#B9A8FF", "#E7A0D0", "#E78284", "#D4D5DF", "#8E8E93", "#F5F5F7"
    ]

    static func themeColor(_ id: ProviderID) -> String {
        switch id {
        case .claude: "#E5A385"
        case .codex: "#98DBB0"
        case .antigravity: "#9CB9FF"
        case .cursor: "#D4D5DF"
        case .zcode: "#3A538D"
        case .dsh: "#6081DA"
        case .glmChina, .glmGlobal, .deepSeek, .newAPI, .sub2API, .custom: manualColor
        case .grokBot: "#A9A9B2"
        }
    }

    static let manualColor = "#CC9EED"

    static func quotaColor(_ entry: AppEntry, percent: Double) -> String {
        percent >= criticalPercent ? entry.resolvedCritical : percent >= warningPercent ? entry.resolvedWarning : entry.resolvedTheme
    }

    static func level(_ percent: Double) -> Int {
        percent >= criticalPercent ? 2 : percent >= warningPercent ? 1 : 0
    }

    static func isColor(_ value: String) -> Bool {
        value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
    }

    static func normalizeColor(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.count == 6, isColor("#" + text) { return "#" + text.uppercased() }
        if isColor(text) { return "#" + text.dropFirst().uppercased() }
        return ""
    }
}

struct CollapsedLimits {
    static let baseHeight: Double = 32
    static let notchWidthDefault: Double = 238
    static let notchWidthRange: ClosedRange<Double> = 180...800
    static let notchHeightDefault: Double = 32
    static let notchHeightRange: ClosedRange<Double> = 24...64
    static let capsuleWidthDefault: Double = 196
    static let capsuleWidthRange: ClosedRange<Double> = 140...800
    static let capsuleHeightDefault: Double = 32
    static let capsuleHeightRange: ClosedRange<Double> = 24...64
    static let lineLengthDefault: Double = 56
    static let lineLengthRange: ClosedRange<Double> = 24...600
    static let lineThicknessDefault: Double = 4
    static let lineThicknessRange: ClosedRange<Double> = 2...8
    static let offsetDefault: Double = 0
    static let capsuleTopDefault: Double = 5
    static let lineTopDefault: Double = 4
    static let notchInset: Double = 30
    static let capsuleInset: Double = 16
    static let notchCorner: Double = 12
    static let notchShoulder: Double = 16
}

struct DeckSettings: Codable {
    var launchAtStartup: Bool = false
    var theme: SettingsTheme = .system
    var language: Language = .system

    var style: CompactStyle = .notch
    var notchWidth: Double = CollapsedLimits.notchWidthDefault
    var notchHeight: Double = CollapsedLimits.notchHeightDefault
    var notchOffsetX: Double = CollapsedLimits.offsetDefault
    var capsuleWidth: Double = CollapsedLimits.capsuleWidthDefault
    var capsuleHeight: Double = CollapsedLimits.capsuleHeightDefault
    var capsuleOffsetX: Double = CollapsedLimits.offsetDefault
    var capsuleTop: Double = CollapsedLimits.capsuleTopDefault
    var lineLength: Double = CollapsedLimits.lineLengthDefault
    var lineThickness: Double = CollapsedLimits.lineThicknessDefault
    var lineTop: Double = CollapsedLimits.lineTopDefault
    var lineOffsetX: Double = CollapsedLimits.offsetDefault

    var hideHotkey: String = ""
    var expandHotkey: String = ""

    // 额度页与会话页分开，各自整页可滚动
    var quotaPage: Bool = true
    var sessionsPage: Bool = true
    // 系统监控页与收起形态的系统读数
    // 面板配色主题，取值来自 PanelThemeCatalog
    var panelTheme: String = "dark"
    var monitorPage: Bool = true
    var monitorInCompact: Bool = false
    var monitorCpu: Bool = true
    var monitorMemory: Bool = true
    var monitorNetwork: Bool = false
    var musicPage: Bool = true
    var defaultPage: DefaultDeckPage = .last
    var lastPage: DeckPage = .quota

    var width: Double = 520
    var height: Double = 200

    // 悬停展开前需要停留的时间；也可以改成点击才展开
    var expandTrigger: ExpandTrigger = .hover
    var openDelay: Int = 250
    var closeDelay: Int = 0
    var animationDuration: Int = 360
    var animations: Bool = true
    var rightClickSettings: Bool = true

    // 全屏与无边框窗口在 macOS 上的处理
    var fullscreenBehavior: WindowBehavior = .line

    // 收起形态统一选择显示哪些内容，三种样式共用这三项
    var showQuota: Bool = true
    var showMusic: Bool = true
    var showSessions: Bool = true
    var showClock: Bool = false
    // 刘海屏上的排版：分列两侧时每侧的宽度，以及两个角标
    var notchLayout: NotchLayout = .split
    // 分列布局下，悬停或点击右侧那一段时打开的页面
    var notchRightPage: DeckPage = .sessions
    // 分列布局左右两段各自可调：音乐侧需要更宽才放得下歌词
    var notchLeftWidth: Double = 150
    var notchRightWidth: Double = 96
    var showCornerTags: Bool = true
    var clockStyle: ClockStyle = .minimal
    var clockColor: ClockColor = .white
    var clockCustomColor: String = "#B9A8FF"
    var clockGradient: [String] = ["#FFB38A", "#FF7EB3", "#B69CFF"]
    var clock24Hour: Bool = true
    var musicText: CompactMusicText = .none
    var musicCoverColor: Bool = true
    var musicIndicatorProgress: Bool = true
    var lyricsEnabled: Bool = true
    // 歌词整体延后显示，抵消播放链路的延迟（毫秒）
    var lyricDelayMs: Int = 300
    var showLyricsTranslation: Bool = true

    var quotaAlerts: Bool = true

    var sessionNotifications: SessionNotificationSettings = SessionNotificationSettings()

    // 面板显示在哪块屏幕上：主显示屏、鼠标所在屏幕，或指定的那一块
    var displayMode: DisplayMode = .main
    var displayID: String = ""

    // DSH 会话通知插件与自定义的 dsh 路径
    var dshHookEnabled: Bool = false
    var dshPath: String = ""

    var apps: [AppEntry] = DeckSettings.defaultApps

    static var defaultApps: [AppEntry] {
        ProviderID.builtIns.map { id in
            AppEntry(quotaSource: id, usageSource: id, enabled: id == .claude || id == .codex)
        }
    }

    var configuredApps: [AppEntry] { apps.filter(\.enabled) }

    // 宽容解码：文件里缺少的字段用默认值，避免新增或删除字段时把用户设置整体丢掉
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        launchAtStartup = value(.launchAtStartup, false)
        theme = value(.theme, SettingsTheme.system)
        language = value(.language, Language.system)
        style = value(.style, CompactStyle.notch)
        notchWidth = value(.notchWidth, CollapsedLimits.notchWidthDefault)
        notchHeight = value(.notchHeight, CollapsedLimits.notchHeightDefault)
        notchOffsetX = value(.notchOffsetX, CollapsedLimits.offsetDefault)
        capsuleWidth = value(.capsuleWidth, CollapsedLimits.capsuleWidthDefault)
        capsuleHeight = value(.capsuleHeight, CollapsedLimits.capsuleHeightDefault)
        capsuleOffsetX = value(.capsuleOffsetX, CollapsedLimits.offsetDefault)
        capsuleTop = value(.capsuleTop, CollapsedLimits.capsuleTopDefault)
        lineLength = value(.lineLength, CollapsedLimits.lineLengthDefault)
        lineThickness = value(.lineThickness, CollapsedLimits.lineThicknessDefault)
        lineTop = value(.lineTop, CollapsedLimits.lineTopDefault)
        lineOffsetX = value(.lineOffsetX, CollapsedLimits.offsetDefault)
        hideHotkey = value(.hideHotkey, "")
        expandHotkey = value(.expandHotkey, "")
        quotaPage = value(.quotaPage, true)
        sessionsPage = value(.sessionsPage, true)
        panelTheme = value(.panelTheme, "dark")
        monitorPage = value(.monitorPage, true)
        monitorInCompact = value(.monitorInCompact, false)
        monitorCpu = value(.monitorCpu, true)
        monitorMemory = value(.monitorMemory, true)
        monitorNetwork = value(.monitorNetwork, false)
        musicPage = value(.musicPage, true)
        defaultPage = value(.defaultPage, DefaultDeckPage.last)
        lastPage = value(.lastPage, DeckPage.quota)
        width = value(.width, 520)
        height = value(.height, 200)
        expandTrigger = value(.expandTrigger, ExpandTrigger.hover)
        openDelay = value(.openDelay, 250)
        closeDelay = value(.closeDelay, 0)
        animationDuration = value(.animationDuration, 360)
        animations = value(.animations, true)
        rightClickSettings = value(.rightClickSettings, true)
        fullscreenBehavior = value(.fullscreenBehavior, WindowBehavior.line)
        showQuota = value(.showQuota, true)
        showMusic = value(.showMusic, true)
        showSessions = value(.showSessions, true)
        showClock = value(.showClock, false)
        notchLayout = value(.notchLayout, NotchLayout.split)
        notchRightPage = value(.notchRightPage, DeckPage.sessions)
        notchLeftWidth = value(.notchLeftWidth, 150)
        notchRightWidth = value(.notchRightWidth, 96)
        showCornerTags = value(.showCornerTags, true)
        clockStyle = value(.clockStyle, ClockStyle.minimal)
        clockColor = value(.clockColor, ClockColor.white)
        clockCustomColor = value(.clockCustomColor, "#B9A8FF")
        clockGradient = value(.clockGradient, ["#FFB38A", "#FF7EB3", "#B69CFF"])
        clock24Hour = value(.clock24Hour, true)
        musicText = value(.musicText, CompactMusicText.none)
        musicCoverColor = value(.musicCoverColor, true)
        musicIndicatorProgress = value(.musicIndicatorProgress, true)
        lyricsEnabled = value(.lyricsEnabled, true)
        lyricDelayMs = value(.lyricDelayMs, 300)
        showLyricsTranslation = value(.showLyricsTranslation, true)
        quotaAlerts = value(.quotaAlerts, true)
        sessionNotifications = value(.sessionNotifications, SessionNotificationSettings())
        displayMode = value(.displayMode, DisplayMode.main)
        displayID = value(.displayID, "")
        dshHookEnabled = value(.dshHookEnabled, false)
        dshPath = value(.dshPath, "")
        apps = value(.apps, DeckSettings.defaultApps)
    }

    // 指示条太窄，只显示播放进度或最高配额，不显示文字与时间
    func showsQuotaContent(_ style: CompactStyle) -> Bool { showQuota }

    func showsMusicContent(_ style: CompactStyle) -> Bool { style != .line && showMusic }

    func showsClockContent(_ style: CompactStyle) -> Bool { style != .line && showClock }

    var quotaWanted: Bool { quotaPage || showQuota }

    var enabledApps: [AppEntry] { quotaWanted ? configuredApps : [] }

    var requiredProviders: Set<ProviderID> {
        var set = Set<ProviderID>()
        for app in enabledApps {
            set.insert(app.quotaSource)
            set.insert(app.resolvedUsageSource)
        }
        return set
    }

    var minimumWidth: Double {
        min(max(440, AppPresets.minimumColumnWidth * Double(max(1, configuredApps.count)) + 40), 1200)
    }

    func presetSize(_ size: PanelSize) -> (width: Double, height: Double) {
        let value = PanelSizes.size(size, columns: configuredApps.count)
        return (max(value.width, minimumWidth), value.height)
    }

    var currentPreset: PanelSize? {
        PanelSize.allCases.first { presetSize($0) == (width, height) }
    }

    mutating func normalize() {
        let validSources = Set(ProviderID.allCases)
        var seen = Set<UUID>()
        apps = apps.filter { validSources.contains($0.quotaSource) }
        if apps.count > AppPresets.maximumApps { apps = Array(apps.prefix(AppPresets.maximumApps)) }
        for index in apps.indices {
            if !seen.insert(apps[index].instanceID).inserted {
                repeat { apps[index].instanceID = UUID() } while !seen.contains(apps[index].instanceID)
            }
            apps[index].normalize()
        }
        width = width.isFinite ? min(max(width, 440), 1200) : 760
        width = max(width, minimumWidth)
        height = height.isFinite ? min(max(height, 140), 400) : 240
        notchWidth = clamp(notchWidth, CollapsedLimits.notchWidthRange, CollapsedLimits.notchWidthDefault)
        notchHeight = clamp(notchHeight, CollapsedLimits.notchHeightRange, CollapsedLimits.notchHeightDefault)
        capsuleWidth = clamp(capsuleWidth, CollapsedLimits.capsuleWidthRange, CollapsedLimits.capsuleWidthDefault)
        capsuleHeight = clamp(capsuleHeight, CollapsedLimits.capsuleHeightRange, CollapsedLimits.capsuleHeightDefault)
        lineLength = clamp(lineLength, CollapsedLimits.lineLengthRange, CollapsedLimits.lineLengthDefault)
        lineThickness = clamp(lineThickness, CollapsedLimits.lineThicknessRange, CollapsedLimits.lineThicknessDefault)
        openDelay = min(max(openDelay, 0), 2000)
        closeDelay = min(max(closeDelay, 0), 2000)
        animationDuration = min(max(animationDuration, 0), 1200)
        clockCustomColor = AppPresets.normalizeColor(clockCustomColor).isEmpty ? "#B9A8FF" : AppPresets.normalizeColor(clockCustomColor)
        if clockGradient.count != 3 { clockGradient = ["#FFB38A", "#FF7EB3", "#B69CFF"] }
        clockGradient = clockGradient.map { AppPresets.normalizeColor($0).isEmpty ? "#FFB38A" : AppPresets.normalizeColor($0) }
    }

    private func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    func entry(_ id: ProviderID) -> AppEntry? { apps.first { $0.quotaSource == id } }
    func entry(instanceID: UUID) -> AppEntry? { apps.first { $0.instanceID == instanceID } }

    mutating func setEnabled(_ id: ProviderID, enabled: Bool) {
        let indexes = apps.indices.filter { apps[$0].quotaSource == id || apps[$0].resolvedUsageSource == id }
        if indexes.isEmpty {
            if enabled && apps.count < AppPresets.maximumApps {
                apps.append(AppEntry(quotaSource: id, usageSource: id))
            }
        } else {
            for index in indexes { apps[index].enabled = enabled }
        }
    }

    func isEnabled(_ id: ProviderID) -> Bool { requiredProviders.contains(id) }
}

@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var settings: DeckSettings
    private let locations = DataLocations.detect()
    private var observers: [UUID: (DeckSettings) -> Void] = [:]

    private init() {
        settings = DeckSettings()
        load()
        Loc.language = settings.language.resolved
    }

    func observe(_ handler: @escaping (DeckSettings) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) { observers[token] = nil }

    func load() {
        let url = SupportFiles.settings
        guard let data = try? Data(contentsOf: url) else {
            settings.normalize()
            return
        }
        do {
            settings = try JSONDecoder().decode(DeckSettings.self, from: data)
        } catch {
            SupportFiles.writeCrash("设置读取失败：\(error.localizedDescription)")
            settings = DeckSettings()
        }
        settings.normalize()
    }

    func save() {
        settings.normalize()
        do {
            try FileManager.default.createDirectory(at: locations.support, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: SupportFiles.settings, options: .atomic)
        } catch {
            SupportFiles.writeCrash("设置写入失败：\(error.localizedDescription)")
        }
    }

    // 修改设置后统一保存并通知界面
    func update(_ change: (inout DeckSettings) -> Void) {
        change(&settings)
        settings.normalize()
        save()
        broadcast()
    }

    func broadcast() {
        let value = settings
        for handler in observers.values { handler(value) }
    }
}

// 会话通知的开关：按助手分别开关，另有横幅、声音与显示位置
struct SessionNotificationSettings: Codable {
    var claude: Bool = false
    var codex: Bool = false
    var gemini: Bool = false
    var opencode: Bool = false
    var dsh: Bool = false
    var banner: Bool = true
    var sound: Bool = true
    // 会话需要处理或结束时在岛上弹出提示
    var islandPopup: Bool = true
    // 弹出提示时顺带展开面板
    var autoExpand: Bool = false
    var showInCompact: Bool = true

    func enabled(for agent: AgentKind) -> Bool {
        switch agent {
        case .claude: claude
        case .codex: codex
        case .gemini: gemini
        case .opencode: opencode
        case .dsh: dsh
        }
    }

    mutating func setEnabled(_ value: Bool, for agent: AgentKind) {
        switch agent {
        case .claude: claude = value
        case .codex: codex = value
        case .gemini: gemini = value
        case .opencode: opencode = value
        case .dsh: dsh = value
        }
    }

    var anyEnabled: Bool {
        claude || codex || gemini || opencode || dsh
    }
}

// 面板显示在哪块屏幕上
enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case main, active, specific

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .main: Loc.t("系统主显示屏", "Main display")
        case .active: Loc.t("鼠标所在的显示屏", "Display with the pointer")
        case .specific: Loc.t("指定的显示屏", "A specific display")
        }
    }
}
