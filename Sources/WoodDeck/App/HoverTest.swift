import AppKit
import SwiftUI

// 悬停逻辑自检：直接给判定函数喂坐标，不移动真实光标、不显示窗口
@MainActor
enum HoverTest {
    static func run(mode: String) {
        IslandController.pointerTestMode = true
        SettingsStore.shared.update {
            $0.expandTrigger = .hover
            $0.openDelay = 300
            $0.closeDelay = 0
        }
        let controller = IslandController()
        let settings = SettingsStore.shared.settings
        guard let screen = ScreenCatalog.target(for: settings) else {
            print("找不到目标屏幕")
            exit(1)
        }
        if mode == "capsule" {
            SettingsStore.shared.update { $0.style = .capsule }
        } else {
            SettingsStore.shared.update { $0.style = .notch }
        }
        let style = SettingsStore.shared.settings.style
        let compact = controller.compactFrame(settings: SettingsStore.shared.settings, style: style, screen: screen)
        let expanded = controller.expandedFrame(settings: SettingsStore.shared.settings, screen: screen)
        let inside = NSPoint(x: compact.midX, y: compact.midY)
        let outside = NSPoint(x: screen.frame.maxX - 40, y: screen.frame.midY)
        // 右上角是设置按钮所在位置，要沿着「进入 → 移到右上角 → 停留」走一遍
        let gear = NSPoint(x: expanded.maxX - 18, y: expanded.maxY - 16)

        print("样式=\(style.rawValue) 收起=\(describe(compact)) 展开=\(describe(expanded))")
        print("内部点=\(describePoint(inside)) 右上角设置=\(describePoint(gear)) 外部点=\(describePoint(outside))")
        // 时间线：外部 → 进入 → 移到右上角设置按钮 → 停留 → 离开
        var steps: [(Double, NSPoint?, String)] = []
        steps.append((0.0, outside, "在外部"))
        steps.append((0.5, inside, "进入"))
        steps.append((1.2, gear, "移动到右上角设置"))
        steps.append((2.0, gear, "停在设置上"))
        steps.append((3.0, gear, "继续停在设置上"))
        steps.append((3.5, outside, "离开"))
        steps.append((4.5, outside, "离开 1 秒"))

        var index = 0
        var lastState = controller.isExpanded
        var leaveAt: Date?
        var collapseDelay: String = "未发生"
        let start = Date()
        while Date().timeIntervalSince(start) < 5.0 {
            let elapsed = Date().timeIntervalSince(start)
            while index < steps.count && elapsed >= steps[index].0 {
                if steps[index].2 == "离开" { leaveAt = Date() }
                if let point = steps[index].1 {
                    let before = controller.isExpanded
                    controller.handlePointer(at: point)
                    if before && !controller.isExpanded, let leaveAt {
                        collapseDelay = String(format: "%.3f 秒", Date().timeIntervalSince(leaveAt))
                    }
                }
                if controller.isExpanded != lastState {
                    lastState = controller.isExpanded
                    print(String(format: "%.2fs 状态变为 ", elapsed) + (lastState ? "展开" : "收起") + "（\(steps[index].2)）")
                }
                index += 1
            }
            // 让主运行循环处理展开的排程（停留计时器）
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        // 收尾时再看一次状态，把最后一次变化打印出来
        print("离开到收起耗时：" + collapseDelay)
        print("最终状态：" + (controller.isExpanded ? "展开" : "收起"))
    }

    // 验证滚动文本：在 80pt 容器里放一句 169pt 的歌词，应该出现两段重复内容
    @MainActor
    static func scrollingTextReport(directory: String) {
        let view = MarqueeText(text: "We were both naked baby as can be",
                               font: .system(size: 9.5, weight: .medium),
                               color: .white)
            .frame(width: 80, height: 16)
            .background(Color.black)
            .padding(8)
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            print("渲染失败")
            return
        }
        let url = URL(filePath: directory).appending(path: "scrolling-text.png")
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        // 统计每一列是否有亮像素，能看出文本是否延伸出容器边界（滚动副本）
        var columnsWithInk: [Int] = []
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                if let c = bitmap.colorAt(x: x, y: y), c.brightnessComponent > 0.35 {
                    columnsWithInk.append(x)
                    break
                }
            }
        }
        let containerStart = 8 * 4
        let containerEnd = containerStart + 80 * 4
        let outside = columnsWithInk.filter { $0 < containerStart || $0 > containerEnd }.count
        print("渲染尺寸 \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)，有墨迹的列数 \(columnsWithInk.count)，容器外列数 \(outside)")
        print("已写入 \(url.lastPathComponent)")
    }

    // 用真实会话渲染对话视图，检查左右分列与 markdown 是否正常出图
    @MainActor
    static func renderConversation(directory: String) {
        let sessions = SessionCenter.shared.activeSessions
        guard let session = sessions.first(where: { $0.agent == .dsh }) ?? sessions.first else {
            print("没有可用会话")
            return
        }
        let messages = ConversationReader.load(session: session, limit: 40)
        print("会话 \(session.agent.shortName) · \(session.projectName)，读取 \(messages.count) 条")
        let roles = Dictionary(grouping: messages, by: \.role).mapValues(\.count)
        print("角色分布: \(roles)")
        let view = ConversationView(session: session, onBack: {})
            .frame(width: 520, height: 420)
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            print("渲染失败")
            return
        }
        let url = URL(filePath: directory).appending(path: "conversation.png")
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        // 左右两半各自的墨迹量，验证「助手在左、用户在右」
        var leftInk = 0, rightInk = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let c = bitmap.colorAt(x: x, y: y) else { continue }
                if c.brightnessComponent > 0.25 || (c.redComponent + c.greenComponent + c.blueComponent) > 0.35 {
                    if x < bitmap.pixelsWide / 2 { leftInk += 1 } else { rightInk += 1 }
                }
            }
        }
        print("左半墨迹 \(leftInk)  右半墨迹 \(rightInk)")
        print("已写入 \(url.lastPathComponent) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")

    }

    // 采样开销：模拟 60Hz 轮询跑 3000 次，测每次耗时
    @MainActor
    static func hoverCostReport() {
        var settings = SettingsStore.shared.settings
        guard let screen = ScreenCatalog.target(for: settings) else { return }
        let controller = IslandController()
        IslandController.pointerTestMode = true
        // 按实际生效的样式取点，否则会一直在测区域外的路径
        if settings.expandTrigger != .hover { settings.expandTrigger = .hover }
        let style = controller.effectiveStyleForTest(settings)
        let frame = controller.compactFrame(settings: settings, style: style, screen: screen)
        let inside = NSPoint(x: frame.midX, y: frame.midY)
        let outside = NSPoint(x: screen.frame.maxX - 40, y: screen.frame.midY)
        print("样式=\(settings.style.rawValue) 生效样式=\(style.rawValue) 排版=\(settings.notchLayout.rawValue) 区内点=\(inside) 区外点=\(outside)")
        for _ in 0..<100 { controller.handlePointer(at: inside); controller.handlePointer(at: outside) }
        let rounds = 3000
        // 稳态：指针停在区内，排程已存在，每帧只是复核
        let start = Date()
        for _ in 0..<rounds {
            controller.handlePointer(at: inside)
            controller.handlePointer(at: outside)
        }
        let steady = Date().timeIntervalSince(start) / Double(rounds * 2) * 1_000_000
        // 进入：每次都要重新判段并排程，属于最贵的一帧
        let enterStart = Date()
        for _ in 0..<rounds {
            controller.handlePointer(at: inside)
            controller.handlePointer(at: outside)
            controller.cancelPendingOpenForTest()
        }
        let enter = Date().timeIntervalSince(enterStart) / Double(rounds * 2) * 1_000_000
        print(String(format: "稳态每帧 %.2f 微秒（60Hz 每秒 %.3f 毫秒）", steady, steady * 60 / 1000))
        print(String(format: "进入帧 %.2f 微秒（只发生在划入的那一帧）", enter))
        IslandController.pointerTestMode = false
    }

    // 分段测量各环节耗时
    @MainActor
    static func hoverBreakdownReport() {
        let settings = SettingsStore.shared.settings
        guard let screen = ScreenCatalog.target(for: settings) else { return }
        let controller = IslandController()
        func bench(_ name: String, _ rounds: Int, _ body: () -> Void) {
            for _ in 0..<50 { body() }
            let start = Date()
            for _ in 0..<rounds { body() }
            let per = Date().timeIntervalSince(start) / Double(rounds) * 1_000_000
            print(String(format: "  %@：%.2f 微秒/次", name, per))
        }
        bench("SettingsStore.shared.settings", 2000) { _ = SettingsStore.shared.settings.style }
        bench("ScreenMetrics.of", 2000) { _ = ScreenMetrics.of(screen) }
        bench("ScreenCatalog.target", 2000) { _ = ScreenCatalog.target(for: settings) }
        let metrics = ScreenMetrics.of(screen)
        bench("CompactGeometry.compact", 2000) { _ = CompactGeometry.compact(settings, style: .notch, metrics: metrics) }
        bench("compactFrame", 2000) { _ = controller.compactFrame(settings: settings, style: .notch, screen: screen) }
        bench("page(for:)", 2000) { _ = controller.page(for: NSPoint(x: 700, y: 970), settings: settings, screen: screen) }
    }

    // 左段/右段命中：分别给出应该打开的页面
    @MainActor
    static func hitZoneReport() {
        let settings = SettingsStore.shared.settings
        guard let screen = ScreenCatalog.target(for: settings) else { print("没有目标屏幕"); return }
        let controller = IslandController()
        let frame = controller.compactFrame(settings: settings, style: .notch, screen: screen)
        let geometry = CompactGeometry.compact(settings, style: .notch, metrics: ScreenMetrics.of(screen))
        let leftPoint = NSPoint(x: frame.minX + geometry.splitLeft / 2, y: frame.midY)
        let notchPoint = NSPoint(x: frame.minX + geometry.splitLeft + geometry.splitNotch / 2, y: frame.midY)
        let rightPoint = NSPoint(x: frame.minX + geometry.splitLeft + geometry.splitNotch + geometry.splitRight / 2, y: frame.midY)
        func page(_ point: NSPoint) -> String {
            controller.page(for: point, settings: settings, screen: screen)?.rawValue ?? "无（落在缺口）"
        }
        print("排版=\(settings.notchLayout.rawValue) 左段=\(Int(geometry.splitLeft)) 缺口=\(Int(geometry.splitNotch)) 右段=\(Int(geometry.splitRight))")
        print("左段命中 → \(page(leftPoint))")
        print("缺口处命中 → \(page(notchPoint))")
        print("右段命中 → \(page(rightPoint))（设置里的右侧页面=\(settings.notchRightPage.rawValue)）")
    }

    // 渲染音乐页（真实尺寸），确认封面、歌词、进度与控制都在框内
    @MainActor
    static func renderMusic(directory: String) {
        let model = DeckModel.shared
        model.start()
        RunLoop.main.run(until: Date().addingTimeInterval(3.5))
        let music = model.music
        print("曲目：\(music.title) · \(music.artist)，歌词 \(music.lyrics.count) 行，"
              + "可改模式=\(music.canChangeMode) 可喜欢=\(music.canLike)")
        // 校验布局不变式：标题 + 歌手 + 歌词行数必须放得进封面高度，且整页不超过可用高度
        for available in [120.0, 158.0, 196.0, 240.0] {
            let progressHeight: CGFloat = 20, controlsHeight: CGFloat = 24, spacing: CGFloat = 8
            let reserved = progressHeight + controlsHeight + spacing * 2
            let cover = max(30, min(96, available - reserved))
            let room = max(0, cover - 18 - 16 - 2)
            let lines = min(3, max(0, Int(room / 15)))
            let used = cover + reserved
            let textHeight = CGFloat(18 + 16) + CGFloat(lines) * 15 + 3
            print(String(format: "H=%3.0f → 封面 %.0f，歌词行数 %d，文字列 %.0f/%.0f，整页 %.0f/%.0f %@",
                         available, cover, lines, textHeight, cover, used, available,
                         (textHeight <= cover && used <= available) ? "✓" : "✗ 溢出"))
        }
        for height in [158.0, 196.0, 120.0] {
            let view = MusicPageView(music: music, onCommand: { _ in }, onSeek: { _ in }, onMode: {})
                .frame(width: 518, height: height)
                .background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(filePath: directory).appending(path: "music-\(Int(height)).png"))
            var ink = 0
            var bottomInk = 0
            let bottomStart = bitmap.pixelsHigh - 60   // 最后 30pt（2x）
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    if let c = bitmap.colorAt(x: x, y: y), c.brightnessComponent > 0.28 {
                        ink += 1
                        if y >= bottomStart { bottomInk += 1 }
                    }
                }
            }
            print("音乐页 H=\(Int(height))：\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) 内容 \(ink)，底部 30pt 内 \(bottomInk)")
        }
    }

    // 渲染监控页，确认各读数卡片有内容
    @MainActor
    static func renderMonitor(directory: String) {
        let model = SystemMonitorModel.shared
        model.start(includeProcesses: true)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        print("模型数据：CPU=\(model.sample.cpu.hasValue) 内存=\(model.sample.memory.hasValue) 网络=\(model.sample.network.hasValue) 应用=\(model.sample.processes.count)")
        for (name, width, height) in [("panel", 500.0, 158.0), ("wide", 700.0, 300.0)] {
            let view = MonitorPageView(monitor: model).content
                .frame(width: width, height: height, alignment: .topLeading)
                .background(Color.black)
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let image = r.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(filePath: directory).appending(path: "monitor-\(name).png"))
            var ink = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    if let c = bitmap.colorAt(x: x, y: y), c.brightnessComponent > 0.28 { ink += 1 }
                }
            }
            print("监控页 \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) 内容像素 \(ink)")

            // 展开态：应比收起态更高（多出 10 行进程）
            let expandedView = MonitorPageView(monitor: model, expandedProcesses: true).content
                .frame(width: width, alignment: .topLeading)
                .background(Color.black)
            let expRenderer = ImageRenderer(content: expandedView)
            expRenderer.scale = 2
            if let expImage = expRenderer.nsImage, let expTiff = expImage.tiffRepresentation,
               let expBitmap = NSBitmapImageRep(data: expTiff) {
                var expInk = 0
                for y in stride(from: 0, to: expBitmap.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: expBitmap.pixelsWide, by: 2) {
                        if let c = expBitmap.colorAt(x: x, y: y), c.brightnessComponent > 0.28 { expInk += 1 }
                    }
                }
                print("展开态 \(expBitmap.pixelsWide)x\(expBitmap.pixelsHigh) 内容像素 \(expInk)（收起态 \(ink)）")
            }
        }
        let view = MonitorPageView(monitor: model)
            .frame(width: 520, height: 300)
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            print("渲染失败"); return
        }
        try? png.write(to: URL(filePath: directory).appending(path: "monitor.png"))
        var ink = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let c = bitmap.colorAt(x: x, y: y), c.brightnessComponent > 0.4 { ink += 1 }
            }
        }
        print("监控页 \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) 有内容像素 \(ink)")
    }

    // 渲染收起形态（胶囊与分列刘海），检查文字区是否有内容且铺满宽度
    @MainActor
    static func renderCompact(directory: String) {
        let model = DeckModel.shared
        let originalStyle = SettingsStore.shared.settings.style
        defer { SettingsStore.shared.update { $0.style = originalStyle } }
        model.start()
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        for mode in ["capsule", "notch"] {
            SettingsStore.shared.update { $0.style = mode == "capsule" ? .capsule : .notch }
            var content = model.compactContent()
            if content.musicText.isEmpty {
                // 没有正在播放的音乐时，用一段长文本验证走马灯布局
                content.musicText = "This Is A Very Long Song Title For Marquee Testing"
                content.equalizer = true
                content.playing = true
            }
            let view = CompactIslandView(content: content)
                .frame(width: content.style == .capsule ? 308 : 557, height: content.style == .capsule ? 44 : 32)
                .background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                print("\(mode)：渲染失败"); continue
            }
            try? png.write(to: URL(filePath: directory).appending(path: "compact-\(mode).png"))
            var ink = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 1) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 1) {
                    if let c = bitmap.colorAt(x: x, y: y), c.brightnessComponent > 0.45 { ink += 1 }
                }
            }
            print("\(mode)：\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)，亮像素 \(ink)，音乐文字=\(content.musicText.prefix(20))")
        }
    }

    // 会话提醒链路：用真实进程发一条 dsh 的 stop 事件，检查岛上是否出现提示文字
    @MainActor
    static func sessionPopupReport() {
        SettingsStore.shared.update {
            $0.sessionNotifications.dsh = true
            $0.sessionNotifications.islandPopup = true
        }
        let center = SessionCenter.shared
        center.start()
        let model = DeckModel.shared
        center.onAttention = { session in model.flashSession(session) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        print("发送前提示文字：\(model.compactContent().alertText ?? "无")")

        let payload = #"{"agent":"dsh","event":"stop","session":"popup-test","cwd":"/tmp","message":"end_turn"}"#
        let process = Process()
        process.executableURL = URL(filePath: CommandLine.arguments[0])
        process.arguments = ["--hook", "dsh"]
        let input = Pipe()
        process.standardInput = input
        try? process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let content = model.compactContent()
        print("发送后提示文字：\(content.alertText ?? "无")")
        print("提示颜色与状态：\(content.alertColor.description)")
        print("会话状态：\(center.sessions.map { $0.id + "=" + $0.status.rawValue }.joined(separator: ", "))")
        center.stop()
    }

    // 打印设置窗口的工具栏与标题栏视图，找出侧栏折叠按钮的真实归属
    @MainActor
    static func settingsChromeReport() {
        let controller = SettingsWindowController.shared
        guard let window = controller.inspectWindowForTest() else { print("没有窗口"); return }
        print("工具栏条目：\(window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? [])")
        print("工具栏可见：\(window.toolbar?.isVisible ?? false)，样式=\(window.toolbarStyle.rawValue)")
        var found: [String] = []
        func walk(_ view: NSView, depth: Int) {
            guard depth < 14 else { return }
            let name = String(describing: type(of: view))
            let interesting = ["Sidebar", "Split", "Toggle", "Button", "Titlebar"]
            if interesting.contains(where: { name.contains($0) }) {
                found.append("\(String(repeating: " ", count: depth))\(name) frame=\(Int(view.frame.width))x\(Int(view.frame.height))")
            }
            for child in view.subviews { walk(child, depth: depth + 1) }
        }
        if let frameView = window.contentView?.superview { walk(frameView, depth: 0) }
        print("标题栏附近的视图：")
        for line in found.prefix(24) { print("  " + line) }
    }

    // 渲染「关于」页，确认退出按钮在位
    @MainActor
    static func renderAbout(directory: String) {
        let view = AboutSection()
            .environmentObject(DeckModel.shared)
            .frame(width: 560, height: 320)
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("渲染失败")
            return
        }
        let url = URL(filePath: directory).appending(path: "about.png")
        try? png.write(to: url)
        var ink = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 1) {
                if let c = bitmap.colorAt(x: x, y: y), c.brightnessComponent > 0.5 { ink += 1 }
            }
        }
        // 逐行统计墨迹，确认有多行表单内容（标题、数据目录、退出、重置）
        var rowsWithInk = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            var found = false
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let c = bitmap.colorAt(x: x, y: y), c.brightnessComponent > 0.45 { found = true; break }
            }
            if found { rowsWithInk += 1 }
        }
        print("关于页 \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)，有内容的行 \(rowsWithInk)，已写入 \(url.lastPathComponent)")
    }

    // 打印面板的页面组成，确认额度与会话是两页
    static func pagesReport() {
        let settings = SettingsStore.shared.settings
        var pages: [String] = []
        if settings.quotaPage { pages.append(DeckPage.quota.displayName) }
        if settings.sessionsPage { pages.append(DeckPage.sessions.displayName) }
        if settings.musicPage { pages.append(DeckPage.music.displayName) }
        if settings.monitorPage { pages.append(DeckPage.monitor.displayName) }
        print("页面顺序：\(pages.joined(separator: " / "))")
        print("默认页面：\(settings.defaultPage.displayName) 上次停留：\(settings.lastPage.displayName)")
        print("面板尺寸：\(Int(settings.width))x\(Int(settings.height))")
    }

    // 用 SwiftUI 的离屏渲染检查各页面能否正常画出来（不需要窗口与录屏权限）
    @MainActor
    static func renderPages(directory: String) {
        let model = DeckModel.shared
        model.refresh()
        // 让会话观察跑起来，渲染真实会话列表
        SessionCenter.shared.start()
        CFRunLoopRunInMode(.defaultMode, 3.0, false)
        // 等一轮刷新把配额与会话读出来
        let deadline = Date().addingTimeInterval(8)
        let loop = CFRunLoopGetMain()
        while Date() < deadline && model.columns.isEmpty {
            CFRunLoopRunInMode(.defaultMode, 0.2, false)
        }
        _ = loop
        let settings = model.settings
        let size = CGSize(width: settings.width, height: settings.height)
        let cases: [(String, AnyView)] = [
            ("switch", AnyView(PageSwitch(page: .sessions, pages: [.quota, .sessions, .music], onChange: { _ in })
                .padding(12).background(Color.black))),
            ("quota", AnyView(QuotaPageView(columns: model.columns, onDetails: { _ in }, onOpenSettings: {}).content
                .frame(maxWidth: .infinity, alignment: .top).background(Color.black))),
            ("sessions", AnyView(SessionsPageView(sessions: SessionCenter.shared.activeSessions,
                                                  onDismiss: { _ in }, onClearFinished: {}).content
                .frame(maxWidth: .infinity, alignment: .top).background(Color.black))),
            ("music", AnyView(MusicPageView(music: model.music,
                                            onCommand: { _ in }, onSeek: { _ in },
                                            onMode: {})))
        ]
        for (name, view) in cases {
            let renderer = ImageRenderer(content: view
                .frame(width: size.width, height: size.height)
                .background(Color.black))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                print("\(name)：渲染失败")
                continue
            }
            let url = URL(filePath: directory).appending(path: "page-\(name).png")
            try? png.write(to: url)
            // 统计非背景像素比例，判断页面确实画出了内容
            var nonBackground = 0
            var total = 0
            let step = max(1, bitmap.pixelsWide / 200)
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                    total += 1
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                        let sum = color.redComponent + color.greenComponent + color.blueComponent
                        if sum > 0.06 { nonBackground += 1 }
                    }
                }
            }
            let ratio = total > 0 ? Double(nonBackground) / Double(total) : 0
            print(String(format: "%@：%dx%d 像素，内容占比 %.1f%%，已写入 %@",
                         name, bitmap.pixelsWide, bitmap.pixelsHigh, ratio * 100, url.lastPathComponent))
        }
    }

    private static func describePoint(_ point: NSPoint) -> String {
        "(\(Int(point.x)),\(Int(point.y)))"
    }

    private static func describe(_ rect: NSRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }
}
