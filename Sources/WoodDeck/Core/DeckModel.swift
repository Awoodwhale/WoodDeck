import Foundation
import SwiftUI
import Combine

// 各来源的统一入口。每一个来源单独失败，不影响其它来源
enum ProviderRegistry {
    static func fetchQuota(_ id: ProviderID, entry: AppEntry, secret: String, context: ProviderContext,
                           locations: DataLocations, http: HTTPClient) async throws -> ProviderResult {
        switch id {
        case .claude:
            return try await ClaudeProvider.fetch(context: context, locations: locations, http: http, online: entry.quotaOnline)
        case .codex:
            return try await CodexProvider.fetch(context: context, locations: locations, http: http)
        case .cursor:
            return try await CursorProvider.fetch(context: context, locations: locations, http: http)
        case .antigravity:
            return try await AntigravityProvider.fetch(context: context, locations: locations, http: http)
        case .grokBot:
            return try await GrokBotProvider.fetch(context: context, locations: locations, http: http, online: entry.quotaOnline)
        case .zcode:
            return try await ZCodeProvider.fetch(context: context, locations: locations, http: http)
        case .dsh:
            return try await DshProvider.fetch(context: context, locations: locations, http: http)
        case .glmChina, .glmGlobal, .deepSeek, .newAPI, .sub2API, .custom:
            return try await ConfiguredProvider.fetch(entry: entry, secret: secret, http: http, now: context.now)
        }
    }

    static func readUsage(_ id: ProviderID, locations: DataLocations, now: Date, start: Date) -> UsageReading {
        switch id {
        case .claude: return ClaudeUsageReader.read(locations: locations, now: now, start: start)
        case .codex: return CodexUsageReader.read(locations: locations, now: now, start: start)
        case .antigravity: return AntigravityUsageReader.read(locations: locations, now: now, start: start)
        case .zcode: return ZCodeUsageReader.read(locations: locations, now: now, start: start)
        case .dsh: return DshUsageReader.read(locations: locations, now: now, start: start)
        case .cursor, .grokBot, .glmChina, .glmGlobal, .deepSeek, .newAPI, .sub2API, .custom:
            return UsageReading(entries: [], note: Loc.t("这个来源没有本机用量记录。", "This source has no local usage records."),
                                available: false, complete: true, quotas: [], plan: "")
        }
    }
}

@MainActor
final class DeckModel: ObservableObject {
    static let shared = DeckModel()

    @Published private(set) var settings: DeckSettings = SettingsStore.shared.settings
    @Published private(set) var columns: [AppColumn] = []
    @Published private(set) var music = MusicDisplay()
    @Published private(set) var refreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published var page: DeckPage = .quota
    @Published private(set) var compactAlert: (text: String, color: Color)?
    // 会话提醒显示期间不接受额度提醒覆盖
    private var sessionAlertActive = false

    private let locations = DataLocations.detect()
    private let http = HTTPClient()
    private var snapshots: [ProviderID: ProviderSnapshot] = [:]
    private var entries: [ProviderID: [TokenEntry]] = [:]
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    // 音乐位置与歌词用更密的节拍，避免歌词晚到一整秒
    private var musicTimer: Timer?
    private var musicAdapter: MediaRemoteAdapter?
    private var musicTask: Task<Void, Never>?
    private var lyricsKey = ""
    private var alertTask: Task<Void, Never>?
    private var previousLevels: [UUID: Int] = [:]
    private var settingsToken: UUID?

    @Published private(set) var now: Date = Date()
    // 面板是否正在展开或收起；为真时暂停律动条重绘
    var panelAnimating = false

    private init() {
        settingsToken = SettingsStore.shared.observe { [weak self] value in
            guard let self else { return }
            let lyricsWereEnabled = self.settings.lyricsEnabled
            self.settings = value
            Loc.language = value.language.resolved
            self.rebuildColumns()
            self.restartTimers()
            // 关掉歌词就把已显示的歌词一并清掉；重新打开时让下一次播放信息重新触发查询
            if lyricsWereEnabled && !value.lyricsEnabled {
                self.lyricsKey = ""
                self.clearLyrics()
            }
        }
        rebuildColumns()
        restartTimers()
    }

    // 每分钟刷新配额与用量，时间每秒走一格
    private func restartTimers() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if clockTimer == nil {
            clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.now = Date()
                    self.updateLyricPosition()
                }
            }
        }
        syncMusicTimer()
    }

    // 歌词推进节拍：只在节拍真的需要变化时重排，不动配额刷新与时钟
    private func syncMusicTimer() {
        if let timer = musicTimer, abs(timer.timeInterval - musicInterval) < 0.001 { return }
        musicTimer?.invalidate()
        musicTimer = Timer.scheduledTimer(withTimeInterval: musicInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.music.playing, self.music.hasTrack else { return }
                self.updateLyricPosition()
            }
        }
    }

    // 展开音乐页时歌词推进用更快的节拍：0.2 秒一格会让换句最多晚 200 毫秒
    private var musicInterval: TimeInterval { fastLyricTicker ? 0.05 : 0.2 }

    var fastLyricTicker = false {
        didSet {
            guard fastLyricTicker != oldValue else { return }
            syncMusicTimer()
        }
    }

    // 自检用：当前歌词推进节拍的实际值
    var lyricTickInterval: TimeInterval { musicTimer?.timeInterval ?? 0 }

    func start() {
        refresh()
        startMusic()
    }

    // 退出前结束音乐子进程，避免留下孤儿进程
    func shutdown() {
        let adapter = musicAdapter
        musicTask?.cancel()
        musicTask = nil
        musicAdapter = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        musicTimer?.invalidate()
        musicTimer = nil
        if let adapter {
            // 退出前等待子进程结束，最多一秒，避免留下孤儿进程
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await adapter.stop()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1)
        }
    }

    func update(_ change: (inout DeckSettings) -> Void) {
        SettingsStore.shared.update(change)
    }

    // MARK: - 配额与用量

    func refresh() {
        guard !refreshing else { return }
        refreshIntervalTick()
    }

    private func refreshIntervalTick() {
        refreshing = true
        let settings = self.settings
        let locations = self.locations
        let http = self.http
        let now = Date()
        let start = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -6, to: now) ?? now)
        let secrets = secretsForRefresh(settings: settings)

        // 读取会话记录与请求配额都很耗时，全部放到主线程之外执行
        let model = self
        Task.detached(priority: .utility) {
            let outcome = await Self.collect(settings: settings, secrets: secrets, locations: locations,
                                             http: http, now: now, start: start)
            await MainActor.run {
                model.apply(quotaResults: outcome.quota, errors: outcome.errors, usage: outcome.usage, at: now)
                model.refreshing = false
            }
        }
    }

    private func secretsForRefresh(settings: DeckSettings) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for app in settings.enabledApps {
            map[app.instanceID] = SecretStore.shared.secret(for: app) ?? ""
        }
        return map
    }

    private nonisolated static func collect(settings: DeckSettings, secrets: [UUID: String], locations: DataLocations,
                                            http: HTTPClient, now: Date, start: Date) async
        -> (quota: [ProviderID: ProviderResult], errors: [ProviderID: ProviderError], usage: [ProviderID: UsageReading]) {
        let apps = settings.enabledApps
        var quotaResults: [ProviderID: ProviderResult] = [:]
        var quotaErrors: [ProviderID: ProviderError] = [:]
        var usageResults: [ProviderID: UsageReading] = [:]

        // 同一个来源只请求一次
        var quotaWanted: [ProviderID: AppEntry] = [:]
        for app in apps where quotaWanted[app.quotaSource] == nil {
            quotaWanted[app.quotaSource] = app
        }
        var usageWanted = Set<ProviderID>()
        for app in apps { usageWanted.insert(app.resolvedUsageSource) }

        await withTaskGroup(of: (ProviderID, Result<ProviderResult, Error>).self) { group in
            for (id, entry) in quotaWanted {
                let secret = secrets[entry.instanceID] ?? ""
                group.addTask {
                    do {
                        let context = ProviderContext(now: now, site: entry.site, secret: secret,
                                                      script: entry.script, language: Loc.language)
                        let result = try await ProviderRegistry.fetchQuota(id, entry: entry, secret: secret,
                                                                           context: context, locations: locations, http: http)
                        return (id, .success(result))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let value): quotaResults[id] = value
                case .failure(let error):
                    quotaErrors[id] = (error as? ProviderError) ?? .readFailed(error.localizedDescription)
                }
            }
        }

        for id in usageWanted {
            usageResults[id] = ProviderRegistry.readUsage(id, locations: locations, now: now, start: start)
        }
        return (quotaResults, quotaErrors, usageResults)
    }

    private func apply(quotaResults: [ProviderID: ProviderResult], errors: [ProviderID: ProviderError],
                       usage: [ProviderID: UsageReading], at now: Date) {
        var snapshots: [ProviderID: ProviderSnapshot] = [:]
        for (id, result) in quotaResults {
            var snapshot = ProviderSnapshot(id: id)
            snapshot.metrics = result.metrics
            snapshot.quotas = result.metrics.compactMap { metric in
                guard metric.kind == .percent, let percent = metric.percent else { return nil }
                return Quota(label: metric.label, usedPercent: percent, resetAt: metric.resetAt, windowMinutes: metric.window)
            }
            snapshot.plan = result.plan
            snapshot.planSource = result.planSource
            snapshot.fetchedAt = now
            snapshots[id] = snapshot
        }
        for (id, error) in errors {
            var snapshot = ProviderSnapshot(id: id)
            snapshot.statusLabel = error.label
            snapshot.status = error.errorDescription ?? ""
            snapshot.fetchedAt = now
            snapshots[id] = snapshot
        }
        self.snapshots = snapshots

        var entryMap: [ProviderID: [TokenEntry]] = [:]
        for (id, reading) in usage {
            entryMap[id] = reading.entries
        }
        self.entries = entryMap
        self.usage = usage
        self.lastRefresh = now
        rebuildColumns()
        checkAlerts()
    }

    private func rebuildColumns() {
        let settings = self.settings
        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart

        columns = settings.configuredApps.map { app in
            let snapshot = snapshots[app.quotaSource]
            let usageID = app.resolvedUsageSource
            let allEntries = entries[usageID] ?? []
            let todayEntries = allEntries.filter { $0.time >= todayStart && $0.time <= now }
            let weekEntries = allEntries.filter { $0.time >= weekStart && $0.time <= now }
            let todayTokens = todayEntries.reduce(0) { $0 + $1.total }
            let weekTokens = weekEntries.reduce(0) { $0 + $1.total }
            let todayCost = cost(of: todayEntries)
            let weekCost = cost(of: weekEntries)

            return AppColumn(
                id: app.instanceID,
                entry: app,
                name: app.name,
                quotas: snapshot?.quotas ?? [],
                metrics: snapshot?.metrics ?? [],
                plan: snapshot?.plan ?? "",
                planSource: snapshot?.planSource ?? "",
                statusLabel: snapshot?.statusLabel ?? "",
                status: snapshot?.status ?? "",
                connected: snapshot?.connected ?? false,
                todayTokens: todayTokens,
                todayCost: todayCost,
                weekTokens: weekTokens,
                weekCost: weekCost,
                usageNote: usage[app.resolvedUsageSource]?.note ?? "",
                usageAvailable: usage[app.resolvedUsageSource]?.available ?? false
            )
        }
    }

    private var usage: [ProviderID: UsageReading] = [:]

    private func cost(of entries: [TokenEntry]) -> Decimal? {
        guard !entries.isEmpty else { return nil }
        var total: Decimal = 0
        var priced = false
        for entry in entries {
            if let value = Pricing.cost(entry: entry) {
                total += value
                priced = true
            }
        }
        return priced ? total : nil
    }

    // MARK: - 收起形态的内容

    func compactContent() -> CompactContent {
        let settings = settings
        let style = settings.style
        let scale = Double(compactHeight(style)) / CollapsedLimits.baseHeight
        var rings: [(Double, Color)] = []
        if settings.showQuota {
            for app in settings.configuredApps.prefix(4) {
                guard let snapshot = snapshots[app.quotaSource] else { continue }
                guard let peak = snapshot.metrics.compactMap(\.usedPercent).max() ?? snapshot.quotas.compactMap(\.usedPercent).max() else { continue }
                rings.append((peak, Theme.quotaColor(app, percent: peak)))
            }
        }

        var musicText = ""
        if settings.showsMusicContent(style) {
            switch settings.musicText {
            case .none: musicText = ""
            case .title: musicText = music.hasTrack ? music.caption : ""
            case .lyrics: musicText = music.currentLyric.isEmpty ? (music.hasTrack ? music.caption : "") : music.currentLyric
            }
        }

        let clock = settings.showsClockContent(style) ? TimeFormatting.clock(now, hour24: settings.clock24Hour, style: settings.clockStyle) : ""

        let metrics = ScreenMetrics.of(ScreenCatalog.target(for: settings))
        let geometry = CompactGeometry.compact(settings, style: style, metrics: metrics)
        // 封面取色开关打开时，用封面主色给律动条与进度着色
        let coverTint: Color? = settings.musicCoverColor
            ? music.artwork.flatMap { CoverColor.tint(from: $0) }
            : nil
        let attention = SessionCenter.shared.attentionSessions
        let showBadge = settings.sessionNotifications.showInCompact && !attention.isEmpty
        return CompactContent(
            style: style,
            rings: rings,
            clock: clock,
            musicText: musicText,
            equalizer: settings.showsMusicContent(style) && music.hasTrack,
            playing: music.playing,
            artwork: settings.showsMusicContent(style) ? music.artwork : nil,
            coverTint: coverTint,
            alertText: compactAlert?.text,
            alertColor: compactAlert?.color ?? .white,
            lineProgress: style == .line ? (settings.musicIndicatorProgress && music.hasTrack ? music.progress : nil) : nil,
            scale: scale,
            clockColor: clockColor(settings),
            clockStyle: settings.clockStyle,
            contentTopPadding: geometry.contentTopPadding,
            splitLeft: geometry.splitLeft,
            splitRight: geometry.splitRight,
            splitNotch: geometry.splitNotch,
            leftTag: settings.showCornerTags ? DeckPage.music.displayName : nil,
            rightTag: settings.showCornerTags ? Loc.t("AI", "AI") : nil,
            sessionBadge: showBadge ? attention.count : 0,
            sessionAgent: showBadge ? attention.first?.agent : nil,
            sessionSymbol: showBadge ? attention.first?.agent.symbol : nil,
            monitorCpu: compactMonitorCpu,
            monitorMemory: compactMonitorMemory,
            monitorNetwork: compactMonitorNetwork,
            animating: panelAnimating
        )
    }

    // 收起形态的系统读数：只在开关打开时取用，取不到就留空，不显示 0
    private var compactMonitorReading: SystemSample? {
        guard settings.monitorInCompact else { return nil }
        return SystemMonitorModel.shared.sample
    }

    private var compactMonitorCpu: Double? {
        guard settings.monitorCpu, let reading = compactMonitorReading?.cpu.orNil else { return nil }
        return reading.usage
    }

    private var compactMonitorMemory: Double? {
        guard settings.monitorMemory, let reading = compactMonitorReading?.memory.orNil else { return nil }
        return reading.fraction
    }

    private var compactMonitorNetwork: String? {
        guard settings.monitorNetwork, let reading = compactMonitorReading?.network.orNil else { return nil }
        return MonitorPageView.rate(reading.receiveBytesPerSecond)
    }

    private func compactHeight(_ style: CompactStyle) -> CGFloat {
        switch style {
        case .notch: settings.notchHeight
        case .capsule: settings.capsuleHeight
        case .line: settings.lineThickness
        }
    }

    private func clockColor(_ settings: DeckSettings) -> Color {
        switch settings.clockColor {
        case .white: return .white
        case .amber: return Theme.color("#FFC46B")
        case .cyan: return Theme.color("#7CE7FF")
        case .pink: return Theme.color("#FF9ECD")
        case .lime: return Theme.color("#B9F27C")
        case .gradient: return Theme.color(settings.clockGradient.count == 3 ? settings.clockGradient[1] : "#B9A8FF")
        case .cover: return music.hasTrack ? Theme.color(settings.clockGradient.first ?? "#B9A8FF") : .white
        case .custom: return Theme.color(settings.clockCustomColor)
        }
    }

    // 配额升到预警或告警时，在收起形态上提示 5 秒
    // 会话需要处理或结束时在收起形态上提示，可选自动展开到对应页面
    func flashSession(_ session: AgentSession) {
        guard settings.sessionNotifications.islandPopup else { return }
        let text: String
        switch session.status {
        case .done: text = Loc.t("\(session.agent.shortName) · 会话已完成", "\(session.agent.shortName) · finished")
        case .waitingPermission: text = Loc.t("\(session.agent.shortName) · 等待授权", "\(session.agent.shortName) · needs permission")
        case .waitingInput: text = Loc.t("\(session.agent.shortName) · 等待你的输入", "\(session.agent.shortName) · waiting for you")
        case .error: text = Loc.t("\(session.agent.shortName) · 出错", "\(session.agent.shortName) · error")
        default: return
        }
        alertTask?.cancel()
        sessionAlertActive = true
        compactAlert = (text, session.status.color)
        let seconds = settings.sessionNotifications.islandSeconds
        alertTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.sessionAlertActive = false
            self?.compactAlert = nil
        }
    }

    private func checkAlerts() {
        // 等级始终跟踪：即使提醒关着也要更新基线，否则重新打开时会一次性补报历史越级
        guard !sessionAlertActive else { return }
        var triggered: (String, Color)?
        for app in settings.configuredApps {
            guard let snapshot = snapshots[app.quotaSource] else { continue }
            guard let peak = snapshot.metrics.compactMap(\.usedPercent).max() ?? snapshot.quotas.compactMap(\.usedPercent).max() else { continue }
            let level = AppPresets.level(peak)
            let previous = previousLevels[app.instanceID] ?? 0
            if level > previous, level > 0 {
                let label = snapshot.quotas.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }?.label ?? ""
                triggered = ("\(app.name) \(label) 已用 \(Int(peak.rounded()))%".trimmingCharacters(in: .whitespaces),
                             level >= 2 ? Theme.color(app.resolvedCritical) : Theme.color(app.resolvedWarning))
            }
            previousLevels[app.instanceID] = level
        }
        // 是否真的提示只由「额度提醒」开关决定，与额度环是否显示无关
        guard settings.quotaAlerts, let (text, color) = triggered else { return }
        alertTask?.cancel()
        compactAlert = (text, color)
        alertTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.compactAlert = nil
        }
    }

    // MARK: - 音乐

    private func startMusic() {
        guard musicAdapter == nil else { return }
        let resources = MediaRemoteResources.directory
        let adapter = MediaRemoteAdapter(resources: resources)
        musicAdapter = adapter
        musicTask = Task { [weak self] in
            do {
                try await adapter.start()
            } catch {
                DebugLog.write("音乐：适配器启动失败 \(error.localizedDescription)")
                await MainActor.run {
                    self?.music.available = false
                    SupportFiles.writeCrash("音乐来源不可用：\(error.localizedDescription)")
                }
                return
            }
            let stream = await adapter.updates()
            for await update in stream {
                await MainActor.run {
                    self?.applyNowPlaying(update)
                }
            }
            await MainActor.run { self?.music.available = false }
        }
    }

    // 自检用：把一条播放信息喂进真实处理路径
    func applyNowPlayingForTest(_ update: NowPlaying?) {
        applyNowPlaying(update)
    }

    // 自检用：按生产路径的写法写入歌词（模拟查询完成）
    func seedLyricsForTest(_ lines: [LyricLine], current: String, next: String) {
        music.lyrics = lines
        music.currentLyric = current
        music.nextLyric = next
        music.currentTranslation = "旧翻译"
    }

    // 自检用：直接推进一次歌词，用于测量单次开销
    func updateLyricPositionForTest() {
        updateLyricPosition()
    }

    private func applyNowPlaying(_ update: NowPlaying?) {
        guard let update, !update.title.isEmpty else {
            music = MusicDisplay(available: true)
            lyricsKey = ""
            return
        }
        let wasPlaying = music.playing
        music.available = true
        music.playing = update.playing
        music.title = update.title
        music.artist = update.artist
        music.album = update.album
        music.artwork = update.artwork ?? music.artwork
        music.duration = update.duration
        music.position = update.position()
        music.positionStamp = Date()
        livePosition = update.position()
        musicPositionOrigin = music.position
        musicPositionDate = update.timestamp
        music.canToggle = true
        music.canNext = true
        music.canPrevious = true
        music.canSeek = update.duration > 0
        // 只有播放器真的报告了对应字段才认为支持：网易云这类只给基础元数据的播放器不提供
        music.canShuffle = update.shuffleMode != nil
        music.canRepeat = update.repeatMode != nil
        music.shuffle = (update.shuffleMode ?? 1) >= 2
        music.repeatMode = update.repeatMode ?? 1
        music.canLike = update.supportsLiked
        music.liked = update.liked
        music.sourceName = MediaSourceNames.name(for: update.bundleIdentifier)
        _ = wasPlaying

        let key = "\(update.title)|\(update.artist)|\(update.album)|\(Int(update.duration.rounded()))"
        if key != lyricsKey && settings.lyricsEnabled {
            lyricsKey = key
            // 先清空上一首的歌词：新曲目的歌词要联网查，查询期间若保留旧词就会张冠李戴
            clearLyrics()
            let title = update.title, artist = update.artist, album = update.album, duration = update.duration
            let preferred = LyricsService.preferredSource(for: update.bundleIdentifier)
            Task { [weak self] in
                let lines = await LyricsService.fetch(title: title, artist: artist, album: album, duration: duration, http: HTTPClient(), preferred: preferred)
                await MainActor.run {
                    guard let self, self.lyricsKey == key else { return }
                    if lines.isEmpty {
                        self.clearLyrics()
                    } else {
                        self.music.lyrics = lines
                        self.updateLyricPosition()
                    }
                }
            }
        } else {
            updateLyricPosition()
        }
    }

    // 清空歌词状态：切歌与关闭歌词时都要做，避免把上一首的歌词留在界面上
    private func clearLyrics() {
        music.lyrics = []
        music.currentLyric = ""
        music.currentTranslation = ""
        music.nextLyric = ""
        music.previousLyric = ""
    }

    private func updateLyricPosition() {
        guard music.hasTrack else { return }
        // 位置单独存放，不进 @Published：5 次/秒地发布会让整个收起视图重建
        let now = Date()
        if music.playing, let origin = musicPositionOrigin {
            livePosition = origin + now.timeIntervalSince(musicPositionDate)
        }
        guard !music.lyrics.isEmpty else { return }
        // 播放链路有缓冲，歌词按设置整体延后，避免总是比声音早
        let delay = Double(max(0, settings.lyricDelayMs)) / 1000
        let time = livePosition - delay
        var current = ""
        var next = ""
        var previous = ""
        var translated = ""
        var currentIndex = -1
        for (index, line) in music.lyrics.enumerated() {
            if line.time <= time {
                current = line.text
                translated = line.translation ?? ""
                next = index + 1 < music.lyrics.count ? music.lyrics[index + 1].text : ""
                currentIndex = index
            } else {
                break
            }
        }
        if currentIndex > 0 { previous = music.lyrics[currentIndex - 1].text }
        // 只有显示出来的文字变了才发布一次
        if current != music.currentLyric || next != music.nextLyric || translated != music.currentTranslation
            || previous != music.previousLyric {
            music.currentLyric = current
            music.nextLyric = next
            music.previousLyric = previous
            music.currentTranslation = translated
            music.position = livePosition
            music.positionStamp = Date()
        }
    }

    // 当前位置由视图按锚点自行插值，避免高频发布
    var positionAnchor: (position: Double, date: Date, rate: Double, playing: Bool) {
        (livePosition, Date(), music.playing ? 1 : 0, music.playing)
    }

    var livePlaybackPosition: Double { livePosition }
    private var livePosition: Double = 0

    private var musicPositionOrigin: Double?
    private var musicPositionDate = Date()

    func seekMusic(to seconds: Double) {
        guard let adapter = musicAdapter else { return }
        Task {
            try? await adapter.seek(to: seconds)
            await MainActor.run {
                self.livePosition = seconds
                self.music.position = seconds
                self.music.positionStamp = Date()
                self.musicPositionOrigin = seconds
                self.musicPositionDate = Date()
            }
        }
    }

    func musicCommand(_ command: MediaCommand) {
        guard let adapter = musicAdapter else { return }
        Task {
            try? await adapter.send(command)
            if command == .toggle {
                await MainActor.run {
                    self.music.playing.toggle()
                    self.musicPositionOrigin = self.music.position
                    self.musicPositionDate = Date()
                }
            }
        }
    }

    // 播放模式按「列表循环 → 单曲循环 → 随机播放 → 顺序播放」循环，
    // 只走播放器报告的可用能力；两项都不支持的播放器（例如网易云）不会响应
    func cyclePlaybackMode() {
        guard let adapter = musicAdapter, music.canChangeMode else { return }
        let modes = PlaybackMode.available(canShuffle: music.canShuffle, canRepeat: music.canRepeat)
        let current = PlaybackMode.current(shuffle: music.shuffle, repeatMode: music.repeatMode)
        let next = PlaybackMode.next(after: current, in: modes)
        Task {
            switch next {
            case .shuffle:
                try? await adapter.setShuffle(3)
                try? await adapter.setRepeat(1)
            case .repeatAll:
                try? await adapter.setShuffle(1)
                try? await adapter.setRepeat(1)
            case .repeatOne:
                try? await adapter.setShuffle(1)
                try? await adapter.setRepeat(2)
            case .inOrder:
                try? await adapter.setShuffle(1)
                try? await adapter.setRepeat(3)
            }
            await MainActor.run {
                self.music.shuffle = next == .shuffle
                self.music.repeatMode = next.repeatMode
            }
        }
    }

    func cycleRepeat() {
        guard let adapter = musicAdapter else { return }
        let next = music.repeatMode >= 3 ? 1 : music.repeatMode + 1
        Task {
            try? await adapter.setRepeat(next)
            await MainActor.run { self.music.repeatMode = next }
        }
    }
}

enum MediaSourceNames {
    static func name(for bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case "com.netease.163music": return "网易云音乐"
        case "com.apple.Music": return "音乐"
        case "com.spotify.client": return "Spotify"
        case "com.tencent.QQMusicMac": return "QQ 音乐"
        case "com.google.Chrome": return "Chrome"
        case "com.apple.Safari": return "Safari"
        default: return bundleIdentifier
        }
    }
}

// 模型明细行：某一列在指定时间范围内的用量
struct ModelDetailRow: Identifiable {
    var id: String { model }
    var model: String
    var input: Int
    var output: Int
    var cacheWrite: Int
    var cacheRead: Int
    var cost: Decimal?
    // 没有匹配到单价、因此没有计入费用的请求数
    var unpriced: Int
    var requests: Int

    var tokens: Int { input + output + cacheWrite + cacheRead }
}

extension DeckModel {
    func modelDetails(columnID: UUID, days: Int) -> [ModelDetailRow] {
        guard let app = settings.apps.first(where: { $0.instanceID == columnID }) else { return [] }
        let source = app.resolvedUsageSource
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: todayStart) ?? todayStart
        let list = (entries[source] ?? []).filter { $0.time >= start }
        var grouped: [String: ModelDetailRow] = [:]
        for entry in list {
            let name = entry.model.isEmpty ? Loc.t("未知模型", "Unknown model") : entry.model
            var row = grouped[name] ?? ModelDetailRow(model: name, input: 0, output: 0, cacheWrite: 0,
                                                      cacheRead: 0, cost: nil, unpriced: 0, requests: 0)
            row.input += entry.input
            row.output += entry.output
            row.cacheWrite += entry.cacheWrite
            row.cacheRead += entry.cacheRead
            row.requests += 1
            if let cost = Pricing.cost(entry: entry) {
                row.cost = (row.cost ?? 0) + cost
            } else {
                row.unpriced += 1
            }
            grouped[name] = row
        }
        return grouped.values.sorted { $0.tokens > $1.tokens }
    }

    // 指定范围内所有条目合计金额；一条都匹配不到单价时返回空
    func totalCost(columnID: UUID, days: Int) -> Decimal? {
        guard let app = settings.apps.first(where: { $0.instanceID == columnID }) else { return nil }
        let source = app.resolvedUsageSource
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: todayStart) ?? todayStart
        return cost(of: (entries[source] ?? []).filter { $0.time >= start })
    }

    func usageNote(forColumn columnID: UUID) -> String {
        guard let app = settings.apps.first(where: { $0.instanceID == columnID }) else { return "" }
        return usage[app.resolvedUsageSource]?.note ?? ""
    }
}
