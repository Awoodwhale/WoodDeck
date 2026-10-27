import AppKit
import Foundation

// 命令行自检：不启动界面，直接跑一遍各数据来源并打印真实结果
enum SelfTest {
    // 歌词查询自检：每项写成「标题|歌手|专辑|时长」，打印最终来自哪个数据源
    // 传入 --lyricsource 时只查那一个数据源；传入 --prefer 时按播放源顺序查询
    static func lyricQueryReport(_ specs: [String], source: String?, preferred: LyricsService.Source? = nil) async {
        let manifests = specs.isEmpty ? defaultLyricCases : specs
        let http = HTTPClient()
        for manifest in manifests {
            let fields = manifest.components(separatedBy: "|")
            let title = fields.count > 0 ? fields[0] : ""
            let artist = fields.count > 1 ? fields[1] : ""
            let album = fields.count > 2 ? fields[2] : ""
            let duration = fields.count > 3 ? Double(fields[3]) ?? 0 : 0
            let started = Date()
            let result: (lines: [LyricLine], source: String)
            if let source {
                let lines = await LyricsService.fetchFrom(source,
                                                          title: title,
                                                          artist: artist,
                                                          album: album,
                                                          duration: duration,
                                                          http: http)
                result = (lines, source)
            } else {
                result = await LyricsService.fetchDetailed(title: title, artist: artist, album: album, duration: duration, http: http, preferred: preferred)
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let head = result.lines.first.map { "首行 \(String(format: "%.2f", $0.time))s \($0.text)" } ?? "没有歌词"
            let translation = result.lines.contains { $0.translation != nil } ? "，含翻译" : ""
            print("\(title) / \(artist) / \(album.isEmpty ? "无专辑" : album) / \(Int(duration))s → \(result.source)，\(result.lines.count) 行\(translation)（\(elapsed) 毫秒）")
            print("    \(head)")
        }
    }

    private static let defaultLyricCases = [
        "Emotional|Keyshia Cole|11:11 Reset|291",
        "晴天|周杰伦|叶惠美|269",
        "Die With A Smile|Lady Gaga|不存在的专辑|251",
        "Fortnight|Taylor Swift|THE TORTURED POETS DEPARTMENT|229",
        "七里香|周杰伦|七里香|299",
    ]

    static func run() async {
        let locations = DataLocations.detect()
        let http = HTTPClient()
        let now = Date()
        let start = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -6, to: now) ?? now)

        print("数据目录：\(locations.support.path(percentEncoded: false))")
        print("适配器目录：\(MediaRemoteResources.directory.path(percentEncoded: false))，存在=\(MediaRemoteResources.isPresent())")

        for id in ProviderID.usageSources {
            let reading = ProviderRegistry.readUsage(id, locations: locations, now: now, start: start)
            let week = reading.entries.filter { $0.time >= start }.reduce(0) { $0 + $1.input + $1.output }
            print("用量 \(id.rawValue)：条目 \(reading.entries.count)，七日 \(week) token，可用=\(reading.available)，说明=\(reading.note)")
            if !reading.quotas.isEmpty {
                print("  本地配额快照：\(reading.quotas.map { "\($0.label)=\(String(format: "%.1f", $0.usedPercent ?? 0))%" }.joined(separator: ", "))")
            }
        }

        for id in ProviderID.allCases where id.isAutomatic {
            let entry = AppEntry(quotaSource: id, usageSource: id)
            do {
                let result = try await ProviderRegistry.fetchQuota(id, entry: entry, secret: "",
                                                                   context: ProviderContext(now: now, language: Loc.language),
                                                                   locations: locations, http: http)
                let summary = result.metrics.map { "\($0.label)=\($0.valueText)" }.joined(separator: ", ")
                print("配额 \(id.rawValue)：套餐=\(result.plan) 指标=[\(summary)]")
            } catch {
                print("配额 \(id.rawValue)：失败 \(error.localizedDescription)")
            }
        }

        // 自定义脚本：使用界面模板
        do {
            let result = try await ScriptProvider.run(script: ProviderScripts.example, site: "", secret: "",
                                                      language: Loc.language, now: now, http: http)
            print("脚本模板：\(result.metrics.map { "\($0.label)=\($0.valueText)" }.joined(separator: ", "))")
        } catch {
            print("脚本模板：失败 \(error.localizedDescription)")
        }

        // 内建 DeepSeek 脚本，使用无效密钥，应得到 401
        if let script = ProviderScripts.builtIn(.deepSeek) {
            do {
                let result = try await ScriptProvider.run(script: script, site: "", secret: "sk-invalid-test",
                                                          language: Loc.language, now: now, http: http)
                print("DeepSeek 脚本：\(result.metrics.count) 项（不应成功）")
            } catch {
                print("DeepSeek 脚本：按预期失败 \(error.localizedDescription)")
            }
        } else {
            print("DeepSeek 脚本：未提供")
        }

        // 连续读取两次，确认文件缓存生效
        let first = Date()
        _ = ProviderRegistry.readUsage(.claude, locations: locations, now: now, start: start)
        let firstMs = Int(Date().timeIntervalSince(first) * 1000)
        let second = Date()
        _ = ProviderRegistry.readUsage(.claude, locations: locations, now: now, start: start)
        let secondMs = Int(Date().timeIntervalSince(second) * 1000)
        print("Claude 用量读取：首次 \(firstMs) 毫秒，缓存后 \(secondMs) 毫秒")

        let lines = await LyricsService.fetch(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269, http: http)
        print("歌词（晴天）：\(lines.count) 行" + (lines.first.map { "，首行 \($0.time)s \($0.text)" } ?? ""))

        let adapter = MediaRemoteAdapter(resources: MediaRemoteResources.directory)
        let functional = await adapter.isFunctional()
        print("媒体适配器可用：\(functional)")
        print("正在播放：\(SelfTest.describe(await SelfTest.firstNowPlaying(adapter)))")
    }

    // 走马灯自检：短句静止、长句先停留再匀速，且换句后从头开始
    @MainActor
    static func marqueeTest() {
        func offsets(textWidth: CGFloat, containerWidth: CGFloat, speed: CGFloat, delay: TimeInterval, from: Date, samples: [TimeInterval]) -> [CGFloat] {
            let overflows = textWidth - containerWidth > 0.5
            guard overflows, speed > 0 else { return samples.map { _ in 0 } }
            let distance = textWidth + 28
            let duration = max(1.2, Double(distance / speed))
            let cycle = delay + duration
            return samples.map { elapsed in
                let phase = elapsed.truncatingRemainder(dividingBy: cycle)
                guard phase > delay else { return 0 }
                let progress = min(1, (phase - delay) / duration)
                return -distance * CGFloat(progress)
            }
        }
        let start = Date()
        let samples: [TimeInterval] = [0, 0.4, 0.9, 1.1, 2.0, 3.0]
        let short = offsets(textWidth: 60, containerWidth: 120, speed: 26, delay: 0.9, from: start, samples: samples)
        print("短句（放得下）偏移：" + short.map { String(format: "%.0f", $0) }.joined(separator: " "))
        let long = offsets(textWidth: 220, containerWidth: 120, speed: 26, delay: 0.9, from: start, samples: samples)
        print("长句偏移：" + long.map { String(format: "%.1f", $0) }.joined(separator: " "))
        print("停留期内偏移为 0：\(long[0] == 0 && long[1] == 0 && long[2] == 0)")
        print("之后逐段向左推进：\(long[3] > long[4] && long[4] > long[5])")
    }

    // 切歌时歌词必须立即清空，不能残留上一首的词
    @MainActor
    static func lyricSwitchTest() async {
        let model = DeckModel.shared
        SettingsStore.shared.update { $0.lyricsEnabled = true }
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 先给第一首塞入歌词，模拟已解析完成的状态
        model.seedLyricsForTest([LyricLine(time: 0, text: "上一首的第一句", translation: nil),
                                 LyricLine(time: 2, text: "上一首的第二句", translation: nil)],
                                current: "上一首的第一句", next: "上一首的第二句")
        print("切歌前：当前=\(model.music.currentLyric) 下一句=\(model.music.nextLyric) 翻译=\(model.music.currentTranslation)")

        // 切到另一首（时长不同，保证 key 变化）
        let next = NowPlaying(bundleIdentifier: "com.netease.163music", title: "全新的一首歌", artist: "新歌手",
                              album: "新专辑", duration: 240, elapsed: 0, timestamp: Date(), rate: 1,
                              playing: true, artwork: nil, uniqueIdentifier: "test-next", shuffleMode: nil,
                              repeatMode: nil, supportsLiked: false, liked: false)
        model.applyNowPlayingForTest(next)
        print("切歌后（查询未完成）：当前=\(model.music.currentLyric.isEmpty ? "空" : model.music.currentLyric)"
              + " 下一句=\(model.music.nextLyric.isEmpty ? "空" : model.music.nextLyric)"
              + " 翻译=\(model.music.currentTranslation.isEmpty ? "空" : model.music.currentTranslation)"
              + " 行数=\(model.music.lyrics.count)")
        // 同一首歌继续播放（key 不变）时不应清空，避免每次刷新都闪一下。
        // 歌词时间取负值，确保当前位置一定落在这一句之后
        model.seedLyricsForTest([LyricLine(time: -60, text: "同曲第一句", translation: nil)],
                                current: "同曲第一句", next: "")
        model.applyNowPlayingForTest(next)
        print("同一首再次更新后：当前=\(model.music.currentLyric.isEmpty ? "空" : model.music.currentLyric)（应保留）")
    }

    // 内存单位：不足 1 GB 用 MB，超过用 GB
    @MainActor
    static func memoryUnitTest() {
        let samples: [(UInt64, String)] = [
            (0, "0 MB"),
            (512 * 1_048_576, "512 MB"),
            (1023 * 1_048_576, "1023 MB"),
            (1024 * 1_048_576, "1.0 GB"),
            (9011 * 1_048_576, "8.8 GB"),
            (16 * 1_073_741_824, "16.0 GB")
        ]
        for (bytes, expected) in samples {
            let got = MonitorPageView.memory(bytes)
            print("\(bytes / 1_048_576) MB → \(got) \(got == expected ? "✓" : "✗ 期望 \(expected)")")
        }
    }

    // 走马灯在暂停/恢复/尺寸变化后文本仍然可见（对应「展开后收起歌词消失」）
    @MainActor
    static func marqueeVisibilityTest() {
        let view = MarqueeLayerView()
        view.frame = NSRect(x: 0, y: 0, width: 120, height: 16)
        view.configure(text: "This Is A Very Long Lyric Line For Testing",
                       font: .systemFont(ofSize: 11), color: .white,
                       spacing: 28, speed: 26, initialDelay: 0.1, paused: false)
        view.layout()
        func report(_ label: String) {
            let layers = view.layer?.sublayers ?? []
            guard layers.count >= 2 else { print("\(label)：层数不足"); return }
            let first = layers[0]
            let second = layers[1]
            print(String(format: "%@：第一份位置 x=%.1f 宽=%.1f 隐藏=%@｜第二份隐藏=%@",
                         label, first.position.x, first.bounds.width,
                         first.isHidden ? "是" : "否", second.isHidden ? "是" : "否"))
        }
        report("初始")
        view.setPaused(true)
        report("暂停后")
        view.setPaused(false)
        view.layout()
        report("恢复后")
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 16)
        view.layout()
        report("改宽到 200（仍溢出）")
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 16)
        view.layout()
        report("改宽到 300（放得下）")
    }

    // 系统监控采样自检：打印两次采样，确认速率类读数有变化
    static func monitorTest() async {
        let sampler = SystemSampler.shared
        _ = sampler.sample(includeProcesses: true)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let sample = sampler.sample(includeProcesses: true, processLimit: 10)
        switch sample.cpu {
        case let value where value.hasValue:
            if let cpu = value.orNil {
                print(String(format: "CPU 总占用 %.1f%%，%d 个核心", cpu.usage * 100, cpu.cores.count))
                let listed = cpu.cores.prefix(8).map { String(format: "%.0f%%", $0.usage * 100) }
                print("  逐核心：" + listed.joined(separator: " "))
            }
        default:
            print("CPU 不可用：\(sample.cpu.reason)")
        }
        if let memory = sample.memory.orNil {
            let used = Double(memory.used) / 1_073_741_824
            let total = Double(memory.total) / 1_073_741_824
            print(String(format: "内存 %.1f / %.1f GB（%.0f%%）", used, total, memory.fraction * 100))
        } else {
            print("内存不可用：\(sample.memory.reason)")
        }
        if let network = sample.network.orNil {
            print(String(format: "网络 下行 %.1f KB/s 上行 %.1f KB/s",
                         network.receiveBytesPerSecond / 1024, network.sendBytesPerSecond / 1024))
        } else {
            print("网络不可用：\(sample.network.reason)")
        }
        print("GPU：\(sample.gpu.hasValue ? "有读数" : "不可用：" + sample.gpu.reason)")
        print("内存占用最高的应用（前 10）：")
        for process in sample.processes {
            print("  \(process.name)  CPU \(String(format: "%.1f%%", process.cpu * 100))  内存 \(MonitorPageView.memory(process.memory))")
        }
    }

    @MainActor
    static func sessionTest() async {
        let center = SessionCenter.shared
        SettingsStore.shared.update { $0.sessionNotifications.claude = true }
        center.start()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let payloads: [(String, String)] = [
            ("SessionStart", #"{"hook_event_name":"SessionStart","session_id":"selftest-1","cwd":"/Users/wood/Downloads/WorkSpace/AgentDir/WoodDeck"}"#),
            ("PreToolUse", #"{"hook_event_name":"PreToolUse","session_id":"selftest-1","cwd":"/Users/wood/Downloads/WorkSpace/AgentDir/WoodDeck","tool_name":"Bash","tool_input":{"command":"swift build"}}"#),
            ("PermissionRequest", #"{"hook_event_name":"PermissionRequest","session_id":"selftest-1","cwd":"/Users/wood/Downloads/WorkSpace/AgentDir/WoodDeck","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#),
            ("Stop", #"{"hook_event_name":"Stop","session_id":"selftest-1","cwd":"/Users/wood/Downloads/WorkSpace/AgentDir/WoodDeck","message":"处理完毕"}"#)
        ]

        for (name, payload) in payloads {
            let process = Process()
            process.executableURL = URL(filePath: CommandLine.arguments[0])
            process.arguments = ["--hook", "claude"]
            process.environment = ProcessInfo.processInfo.environment
            let input = Pipe()
            process.standardInput = input
            try? process.run()
            input.fileHandleForWriting.write(Data(payload.utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            try? await Task.sleep(nanoseconds: 250_000_000)
            // 按 id 找这条测试会话：sessions 里可能还有其它助手留下的会话
            let target = center.sessions.first { $0.id.hasSuffix("selftest-1") }
            print("发送 \(name) 后：\(center.sessions.count) 个会话｜测试会话状态 \(target?.status.rawValue ?? "缺失")，工具 \(target?.tool ?? "-")，消息 \(target?.message ?? "-")")
        }

        print("需要关注的会话：\(center.attentionSessions.count)")
        center.stop()
    }

    // 验证 DeepSeek Harness 的会话观察：读取真实会话记录并打印解析出的事件
    @MainActor
    static func watchTest() async {
        SettingsStore.shared.update { $0.sessionNotifications.dsh = true }
        let center = SessionCenter.shared
        center.start()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        print("观察到 \(center.sessions.count) 个会话")
        for session in center.activeSessions.prefix(6) {
            print("  \(session.agent.shortName) · \(session.projectName) · \(session.status.label) · \(session.tool) · \(session.message.prefix(40))")
        }
        center.stop()
    }

    // 打印屏幕清单与面板目标的解析结果
    @MainActor
    static func screenTest() {
        let settings = SettingsStore.shared.settings
        print("屏幕清单：")
        for info in ScreenCatalog.current() {
            print("  id=\(info.id) \(info.name) \(Int(info.width))x\(Int(info.height)) 主屏=\(info.isMain) 刘海=\(info.hasNotch)")
        }
        print("设置：模式=\(settings.displayMode.rawValue) 指定屏=\(settings.displayID) 排版=\(settings.notchLayout.rawValue) 左=\(Int(settings.notchLeftWidth)) 右=\(Int(settings.notchRightWidth)) 额度=\(settings.showQuota)")
        // 非刘海屏：确认走的是「内容自适应宽度的胶囊」而不是原来的窄带
        if let external = NSScreen.screens.first(where: { !ScreenMetrics.of($0).hasNotch }) {
            let metrics = ScreenMetrics.of(external)
            let geometry = CompactGeometry.compact(settings, style: .notch, metrics: metrics)
            print(String(format: "非刘海屏 %@：notch 样式几何 %.0fx%.0f 顶距=%.0f 圆角=%.0f",
                         external.localizedName, geometry.width, geometry.height, geometry.topInset, geometry.cornerRadius))
        }

        // 分列布局下，让开的缺口中心必须与屏幕中心对齐（物理摄像头位置）
        if let screen = ScreenCatalog.target(for: settings) {
            let controller = IslandController()
            let frame = controller.compactFrame(settings: settings, style: .notch, screen: screen)
            let geometry = CompactGeometry.compact(settings, style: .notch, metrics: ScreenMetrics.of(screen))
            if geometry.splitLeft > 0 {
                let notchCenter = frame.minX + geometry.splitLeft + geometry.splitNotch / 2
                let screenCenter = screen.frame.midX + CompactGeometry.offsetX(settings, style: .notch)
                print(String(format: "缺口中心 %.1f 屏幕中心 %.1f 偏差 %.1f pt", notchCenter, screenCenter, notchCenter - screenCenter))
                print(String(format: "左段 %.0f 右段 %.0f 整条宽 %.0f", geometry.splitLeft, geometry.splitRight, frame.width))
            }
        }

        for style in CompactStyle.allCases {
            let g = CompactGeometry.compact(settings, style: style, metrics: ScreenMetrics.of(ScreenCatalog.target(for: settings)))
            print("  \(style.rawValue) 几何：\(Int(g.width))x\(Int(g.height)) 顶距=\(Int(g.topInset)) 内容下移=\(Int(g.contentTopPadding)) 分列左=\(Int(g.splitLeft)) 右=\(Int(g.splitRight)) 刘海=\(Int(g.splitNotch))")
        }
        if let target = ScreenCatalog.target(for: settings) {
            let metrics = ScreenMetrics.of(target)
            print("目标屏幕=\(target.localizedName) 刘海高度=\(metrics.notchHeight) 刘海宽度=\(metrics.notchWidth)")
        } else {
            print("目标屏幕=无")
        }
    }

    // 打印界面将显示的内容，用于在没有视觉的情况下核对数据链路
    @MainActor
    static func dumpUI() async {
        let model = DeckModel.shared
        model.start()
        // 音乐适配器需要启动 perl 并等待第一份状态，这里留出足够时间
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        let content = model.compactContent()
        print("收起样式：\(content.style.rawValue) 缩放：\(String(format: "%.2f", content.scale))")
        print("配额环：\(content.rings.map { String(format: "%.0f%%", $0.percent) }.joined(separator: ", "))")
        print("时间：\(content.clock.isEmpty ? "（未显示）" : content.clock) 样式=\(content.clockStyle.rawValue)")
        print("音乐文字：\(content.musicText.isEmpty ? "（无）" : content.musicText) 律动条=\(content.equalizer) 播放中=\(content.playing)")
        print("提醒：\(content.alertText ?? "（无）")")
        print("列数：\(model.columns.count)")
        for column in model.columns {
            print("  \(column.name)：连接=\(column.connected) 套餐=\(column.plan) 配额=\(column.metrics.map { "\($0.label)=\($0.valueText)" }.joined(separator: ", ")) 今日=\(column.todayTokens) 七日=\(column.weekTokens) 状态=\(column.statusLabel)\(column.status.isEmpty ? "" : "（\(column.status)）")")
        }
        print("活跃会话：\(SessionCenter.shared.activeSessions.count) 个，需关注 \(SessionCenter.shared.attentionSessions.count) 个")
        for session in SessionCenter.shared.activeSessions.prefix(4) {
            print("  \(session.agent.shortName) · \(session.projectName) · \(session.status.label) · \(session.tool)")
        }
        print("正在播放：\(model.music.title.isEmpty ? "无" : model.music.title + " · " + model.music.artist + " / 歌词 " + String(model.music.lyrics.count) + " 行")")
        if !model.music.lyrics.isEmpty {
            print("  当前行：\(model.music.currentLyric.isEmpty ? "（尚未到第一行）" : model.music.currentLyric)")
        }
        model.shutdown()
    }

    private static func firstNowPlaying(_ adapter: MediaRemoteAdapter) async -> NowPlaying? {
        do {
            try await adapter.start()
        } catch {
            print("媒体流启动失败：\(error.localizedDescription)")
            return nil
        }
        let stream = await adapter.updates()
        var result: NowPlaying?
        let deadline = Date().addingTimeInterval(4)
        let task = Task {
            for await update in stream {
                if let update, !update.title.isEmpty { result = update; return }
            }
        }
        while Date() < deadline && result == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        task.cancel()
        await adapter.stop()
        return result
    }

    private static func describe(_ track: NowPlaying?) -> String {
        guard let track else { return "无" }
        return "\(track.title) · \(track.artist)（\(track.bundleIdentifier)，\(TimeFormatting.duration(track.duration))，封面 \(track.artwork?.count ?? 0) 字节）"
    }
}
