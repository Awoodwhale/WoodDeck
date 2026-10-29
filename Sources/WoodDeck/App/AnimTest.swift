import AppKit
import Combine
import SwiftUI

// 展开与收起的动画诊断：记录每一次真实的布局节拍与耗时
enum AnimTest {
    // 记录宿主视图每次布局的时刻与耗时
    private final class ProbeHosting<Content: View>: NSHostingView<Content> {
        struct Pass {
            var at: CFTimeInterval
            var size: CGSize
            var cost: Double
        }

        var passes: [Pass] = []
        var recording = false

        override func layout() {
            guard recording else {
                super.layout()
                return
            }
            let start = CACurrentMediaTime()
            super.layout()
            let end = CACurrentMediaTime()
            passes.append(Pass(at: start, size: bounds.size, cost: (end - start) * 1000))
        }
    }

    @MainActor
    static func run(arguments: [String]) {
        // capsule / notch：临时换成指定的收起样式测一遍；below：刘海样式改用整条向下延伸的排版。结束后恢复用户原来的设置
        let originalStyle = SettingsStore.shared.settings.style
        let originalLayout = SettingsStore.shared.settings.notchLayout
        if arguments.contains("capsule") {
            SettingsStore.shared.update { $0.style = .capsule }
        } else if arguments.contains("notch") {
            SettingsStore.shared.update { $0.style = .notch }
        }
        if arguments.contains("below") {
            SettingsStore.shared.update { $0.notchLayout = .below }
        }
        defer {
            if SettingsStore.shared.settings.style != originalStyle || SettingsStore.shared.settings.notchLayout != originalLayout {
                SettingsStore.shared.update {
                    $0.style = originalStyle
                    $0.notchLayout = originalLayout
                }
            }
        }
        let settings = SettingsStore.shared.settings
        let model = DeckModel.shared
        model.start()
        // 等真实数据就位，面板里才有要布局的内容
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline && model.music.title.isEmpty && model.columns.isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }

        for screen in NSScreen.screens {
            let metrics = ScreenMetrics.of(screen)
            print("屏幕 \(metrics.hasNotch ? "内建（有刘海）" : "外接")：刷新率上限 \(screen.maximumFramesPerSecond) Hz，尺寸 \(Int(screen.frame.width))×\(Int(screen.frame.height))")
        }
        print("设置：动画开关=\(settings.animations) 时长=\(settings.animationDuration) 毫秒")

        let pages: [DeckPage]
        if arguments.contains("music") {
            pages = [.music]
        } else if arguments.contains("quota") {
            pages = [.quota]
        } else if arguments.contains("sessions") {
            pages = [.sessions]
        } else {
            pages = [.music, .quota]
        }

        if arguments.contains("idle") {
            for page in pages {
                idle(page: page, settings: settings, model: model)
            }
            return
        }

        if arguments.contains("collapse") {
            // pixels：动画中途截图检查面板是否只剩纯色底。截图本身很慢，会拉长那几帧的间隔
            collapseReport(settings: settings, model: model, checkPixels: arguments.contains("pixels"))
            return
        }

        if arguments.contains("swap") {
            let warm = arguments.contains("warm")
            for page in pages {
                swapCost(page: page, settings: settings, model: model, warmUp: warm)
            }
            return
        }

        // 每个进程只跑一种驱动：同一进程里建多个面板宿主会互相干扰，读数就不可信
        let drivers: [Driver]
        if arguments.contains("appkit") {
            drivers = [.appKit]
        } else if arguments.contains("link") {
            drivers = [.displayLink]
        } else {
            drivers = [.appKit, .displayLink]
        }
        for page in pages {
            for driver in drivers {
                measure(page: page, settings: settings, model: model, driver: driver)
            }
        }
    }

    // 收起过程中收起条里的歌词在屏幕上的位置：与真实面板一样，窗口从展开矩形缩回收起矩形，
    // 收起条按窗口尺寸布局。逐帧记录歌词层相对摄像头中线与屏幕顶边的偏移
    @MainActor
    private static func collapseReport(settings: DeckSettings, model: DeckModel, checkPixels: Bool) {
        guard let screen = NSScreen.screens.first else { return }
        // 歌词要等媒体流与歌词查询都回来
        let lyricDeadline = Date().addingTimeInterval(10)
        while Date() < lyricDeadline && model.compactContent().musicText.isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let controller = IslandController()
        let expandedReal = controller.expandedFrame(settings: settings, screen: screen)
        let compactReal = controller.compactFrame(settings: settings, style: settings.style, screen: screen)
        let geometry = CompactGeometry.compact(settings, style: settings.style, metrics: ScreenMetrics.of(screen))
        // 摄像头中线（分列时）或收起条中线：收起之后歌词应当停在的参照
        let anchorX = geometry.splitLeft > 0 ? compactReal.minX + geometry.splitLeft + geometry.splitNotch / 2 : compactReal.midX
        let screenTop = screen.frame.maxY

        // 窗口整体平移到主屏左下角，相对几何不变；透明度为 0，用户看不到
        let shift = NSPoint(x: screen.frame.minX + 20 - compactReal.minX, y: screen.frame.minY + 20 - expandedReal.minY)
        func moved(_ rect: NSRect) -> NSRect { rect.offsetBy(dx: shift.x, dy: shift.y) }
        let expandedRect = moved(expandedReal)
        let compactRect = moved(compactReal)
        let movedAnchorX = anchorX + shift.x
        let movedTop = screenTop + shift.y

        let content = model.compactContent()
        // 与应用一致：根视图开始时停在展开面板，窗口缩回收起矩形后才换成收起条
        let state = DeckAppState()
        state.page = .quota
        state.expanded = true
        let root = IslandRootView(model: model,
                                  state: state,
                                  onMusicCommand: { _ in },
                                  onSeek: { _ in },
                                  onDetails: { _, _ in },
                                  onExpandRequest: {})
        let hosting = ProbeHosting(rootView: AnyView(root))
        hosting.frame = NSRect(origin: .zero, size: expandedRect.size)
        let container = NSView(frame: NSRect(origin: .zero, size: expandedRect.size))
        container.clipsToBounds = true
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let window = NSWindow(contentRect: expandedRect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.alphaValue = 0
        window.animationBehavior = NSWindow.AnimationBehavior.none
        window.ignoresMouseEvents = true
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        func lyricView(in view: NSView) -> NSView? {
            if view is MarqueeLayerView { return view }
            for child in view.subviews {
                if let found = lyricView(in: child) { return found }
            }
            return nil
        }

        // 屏幕上实际看到的不透明度：沿父视图把各层正在显示的不透明度乘起来
        func visibleOpacity(_ view: NSView) -> Float {
            var current: NSView? = view
            var opacity: Float = 1
            while let item = current, item !== container {
                opacity *= Float(item.alphaValue)
                if let layer = item.layer {
                    opacity *= layer.presentation()?.opacity ?? layer.opacity
                }
                current = item.superview
            }
            return opacity
        }

        // 截一帧：和底色明显不同的像素数（为 0 说明只画了纯色底），以及顶边最左侧空出的宽度（点）。
        // 刘海样式收起时，顶部圆角应随高度缩小逐渐变成直角，空出的宽度逐渐变为 0
        let panelColor = PanelThemeCatalog.palette(id: settings.panelTheme).panelColor
        struct Shot {
            var height: CGFloat
            var content: Int
            var topGap: CGFloat
        }
        func shot() -> Shot? {
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
                  let base = NSColor(panelColor).usingColorSpace(.sRGB) else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            var count = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.5 else { continue }
                    let diff = abs(pixel.redComponent - base.redComponent) + abs(pixel.greenComponent - base.greenComponent) + abs(pixel.blueComponent - base.blueComponent)
                    if diff > 0.1 { count += 1 }
                }
            }
            var gap = 0
            while gap < bitmap.pixelsWide, (bitmap.colorAt(x: gap, y: 0)?.alphaComponent ?? 0) < 0.5 { gap += 1 }
            let scale = CGFloat(bitmap.pixelsWide) / max(hosting.bounds.width, 1)
            return Shot(height: hosting.bounds.height, content: count, topGap: CGFloat(gap) / scale)
        }
        let before = checkPixels ? shot() : nil

        struct Sample {
            var at: Double
            var window: NSRect
            // 只在收起条已经显示时记录歌词位置
            var lyric: NSRect?
            var compactShown: Bool
        }
        var samples: [Sample] = []
        var shots: [Shot] = []
        let begin = CACurrentMediaTime()
        func record() {
            hosting.layoutSubtreeIfNeeded()
            let shown = !state.expanded
            let lyric = shown ? lyricView(in: hosting).map { view in
                window.convertToScreen(view.convert(view.bounds, to: nil))
            } : nil
            samples.append(Sample(at: (CACurrentMediaTime() - begin) * 1000, window: window.frame, lyric: lyric, compactShown: shown))
            if checkPixels, let item = shot() { shots.append(item) }
        }
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                             object: window,
                                                             queue: nil) { _ in
            MainActor.assumeIsolated { record() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        // 与 AppDelegate.showExpanded(false) 相同：开始收起时只留纯色底
        state.collapseFromHeight = expandedRect.height
        state.collapseToHeight = compactRect.height
        state.collapsing = true
        record()
        hosting.passes = []
        hosting.recording = true
        var finished = false
        let animator = PanelFrameAnimator(window: window)
        animator.animate(to: compactRect, duration: Double(settings.animationDuration) / 1000) {
            finished = true
        }
        let wait = Date().addingTimeInterval(3)
        while !finished && Date() < wait {
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
        }
        hosting.recording = false
        let animationFrames = samples.count
        let compactDuringAnimation = samples.filter(\.compactShown).count
        // 窗口到达收起尺寸后换成收起条，与 AppDelegate.finishCollapse 相同
        let swap = CACurrentMediaTime()
        state.expanded = false
        state.collapsing = false
        record()
        let swapCost = (CACurrentMediaTime() - swap) * 1000
        var fade: [(Double, Float)] = []
        while CACurrentMediaTime() - swap < 0.5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            if let view = lyricView(in: hosting) {
                fade.append(((CACurrentMediaTime() - swap) * 1000, visibleOpacity(view)))
            }
        }

        print("收起：\(Int(expandedRect.width))×\(Int(expandedRect.height)) → \(Int(compactRect.width))×\(Int(compactRect.height))，当前歌词「\(content.musicText)」")
        print("动画期间 \(animationFrames) 帧，其中显示收起条的帧数 \(compactDuringAnimation)")
        if checkPixels, let before {
            print(String(format: "收起前（展开面板）：与底色不同的像素 %d，顶边左侧空出 %.1f 点", before.content, before.topGap))
            for (index, item) in shots.enumerated() {
                let label = index == shots.count - 1 ? "换上收起条" : "第 \(index) 帧"
                print(String(format: "  %@ 高 %.1f：与底色不同的像素 %d，顶边左侧空出 %.1f 点", label, item.height, item.content, item.topGap))
            }
        }
        print("换上收起条后歌词的不透明度：" + fade.map { String(format: "%.0f 毫秒 %.2f", $0.0, $0.1) }.joined(separator: "，"))
        let times = samples.prefix(animationFrames).map(\.at)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        if !gaps.isEmpty {
            print(String(format: "改尺寸间隔 平均 %.1f 毫秒 最大 %.1f 毫秒，超过 16 毫秒 %d 次；动画时长 %.0f 毫秒",
                         gaps.reduce(0, +) / Double(gaps.count), gaps.max() ?? 0, gaps.filter { $0 > 16 }.count, times.last ?? 0))
        }
        print(String(format: "动画结束后换成收起条耗时 %.2f 毫秒", swapCost))
        guard let final = samples.last?.lyric else {
            print("没有找到歌词层（当前没有歌词）")
            return
        }
        let expected = movedAnchorX - geometry.splitNotch / 2 - geometry.splitLeft
        print(String(format: "换上收起条的第一帧：歌词左边相对摄像头中线 %+.1f 点，中线距屏幕顶边 %.1f 点；收起条左边缘 %+.1f 点",
                     final.minX - movedAnchorX, movedTop - final.midY, expected - movedAnchorX))
    }

    // 从收起条换成展开面板要花多久：动画开始前先付掉这笔开销，动画才不会被卡住
    @MainActor
    private static func swapCost(page: DeckPage, settings: DeckSettings, model: DeckModel, warmUp: Bool) {
        let metrics = ScreenMetrics.of(NSScreen.screens.first)
        let geometry = CompactGeometry.compact(settings, style: settings.style, metrics: metrics)
        let compact = CGSize(width: geometry.width, height: geometry.height)
        let state = DeckAppState()
        state.page = page
        state.expanded = false
        let root = IslandRootView(model: model,
                                  state: state,
                                  onMusicCommand: { _ in },
                                  onSeek: { _ in },
                                  onDetails: { _, _ in },
                                  onExpandRequest: {})
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = NSRect(origin: .zero, size: compact)
        let container = NSView(frame: NSRect(origin: .zero, size: compact))
        container.clipsToBounds = true
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let base = NSScreen.screens.first?.frame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: base.x + 20, y: base.y + 20, width: compact.width, height: compact.height),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        container.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        // 启动预热：和应用启动时做的一样，先把展开面板建好再切回收起
        if warmUp {
            state.expanded = true
            container.layoutSubtreeIfNeeded()
            state.expanded = false
            container.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }

        // 展开：把换内容与布局一起同步做完，这正是 apply 里提前付掉的那一步
        let first = CACurrentMediaTime()
        state.expanded = true
        container.layoutSubtreeIfNeeded()
        let firstCost = (CACurrentMediaTime() - first) * 1000
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        // 收起再展开：视图树已经建好，这一次只剩重排
        let back = CACurrentMediaTime()
        state.expanded = false
        container.layoutSubtreeIfNeeded()
        let backCost = (CACurrentMediaTime() - back) * 1000
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let again = CACurrentMediaTime()
        state.expanded = true
        container.layoutSubtreeIfNeeded()
        let againCost = (CACurrentMediaTime() - again) * 1000

        print("")
        print("页面 \(page.displayName)\(warmUp ? "（启动已预热）" : "")：第一次换成展开面板并布局 \(String(format: "%.2f", firstCost)) 毫秒，换回收起条 \(String(format: "%.2f", backCost)) 毫秒，第二次展开 \(String(format: "%.2f", againCost)) 毫秒（120 Hz 一帧 8.3）")
    }

    // 面板静止不动时的布局次数：持续重排本身就会让动画掉帧
    @MainActor
    private static func idle(page: DeckPage, settings: DeckSettings, model: DeckModel) {
        let expanded = CGSize(width: CGFloat(settings.width), height: CGFloat(settings.height))
        let hosting = ProbeHosting(rootView: AnyView(panelView(page: page, settings: settings, model: model)))
        hosting.frame = NSRect(origin: .zero, size: expanded)
        let container = NSView(frame: NSRect(origin: .zero, size: expanded))
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let base = NSScreen.screens.first?.frame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: base.x + 20, y: base.y + 20, width: expanded.width, height: expanded.height),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        hosting.recording = true
        // 模型发布一次就意味着整棵树重算一遍，和布局次数一起看
        var modelPublishes = 0
        let modelToken = model.objectWillChange.sink { _ in modelPublishes += 1 }
        for round in 1...3 {
            hosting.passes = []
            modelPublishes = 0
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let cost = hosting.passes.map(\.cost).reduce(0, +)
            print("页面 \(page.displayName) 静止第 \(round) 秒：布局 \(hosting.passes.count) 次，合计 \(String(format: "%.1f", cost)) 毫秒；模型发布 \(modelPublishes) 次")
        }
        modelToken.cancel()
        hosting.recording = false
    }

    @MainActor
    private static func panelView(page: DeckPage, settings: DeckSettings, model: DeckModel) -> ExpandedPanelView {
        // 参数与实际根视图完全一致
        ExpandedPanelView(settings: settings,
                          columns: model.columns,
                          music: model.music,
                          page: page,
                          refreshing: model.refreshing,
                          lastRefresh: model.lastRefresh,
                          onPageChange: { _ in },
                          onRefresh: {},
                          onSettings: {},
                          onMusicCommand: { _ in },
                          onSeek: { _ in },
                          onMode: {},
                          onDetails: { _, _ in },
                          sessions: SessionCenter.shared.activeSessions,
                          onDismissSession: { _ in },
                          onClearFinished: {},
                          pages: [.quota, .sessions, .music],
                          alertText: model.compactAlert?.text ?? "",
                          alertColor: model.compactAlert?.color ?? .white)
    }

    private enum Driver {
        case appKit
        case displayLink

        var title: String {
            switch self {
            case .appKit: return "AppKit window.animator()"
            case .displayLink: return "显示器节拍逐帧"
            }
        }
    }

    @MainActor
    private static func measure(page: DeckPage,
                                settings: DeckSettings,
                                model: DeckModel,
                                driver: Driver) {
        let screen = NSScreen.screens.first
        let metrics = ScreenMetrics.of(screen)
        let geometry = CompactGeometry.compact(settings, style: settings.style, metrics: metrics)
        let compact = CGSize(width: geometry.width, height: geometry.height)
        let expanded = CGSize(width: CGFloat(settings.width), height: CGFloat(settings.height))

        // 宿的是展开面板本体：根视图配合探针的轮询会反复触发重入布局，读数不可用
        let hosting = ProbeHosting(rootView: AnyView(panelView(page: page, settings: settings, model: model)))
        hosting.frame = NSRect(origin: .zero, size: compact)
        hosting.clipsToBounds = true
        // 与实际面板一致：宿主是普通视图的子视图并按 frame 跟随，
        // 直接当 contentView 时它的固有尺寸会把窗口尺寸顶回去
        let container = NSView(frame: NSRect(origin: .zero, size: compact))
        container.clipsToBounds = true
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        // 显示器节拍需要窗口真的落在某块屏幕上，这里放到主屏左下角并把透明度设为 0，用户看不到
        let base = (NSScreen.screens.first?.frame.origin ?? .zero)
        let originX = base.x + 20
        let originY = base.y + 20
        let window = NSWindow(contentRect: NSRect(x: originX, y: originY, width: compact.width, height: compact.height),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.alphaValue = 0
        window.animationBehavior = NSWindow.AnimationBehavior.none
        window.ignoresMouseEvents = true
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // 第一次构建整棵视图树并布局的耗时：面板第一次展开时要付这笔钱
        let build = CACurrentMediaTime()
        hosting.layoutSubtreeIfNeeded()
        let buildCost = (CACurrentMediaTime() - build) * 1000
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // 静止 1 秒的布局次数：与动画无关的持续重排会单独表现为卡顿
        hosting.recording = true
        hosting.passes = []
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let idlePasses = hosting.passes.count
        let idleCost = hosting.passes.map(\.cost).reduce(0, +)

        let expandedRect = NSRect(x: originX, y: originY, width: expanded.width, height: expanded.height)
        let compactRect = NSRect(x: originX, y: originY, width: compact.width, height: compact.height)

        // 一次落位的布局代价：动画每一步都要重复付出
        hosting.passes = []
        let single = CACurrentMediaTime()
        window.setFrame(expandedRect, display: true)
        hosting.layoutSubtreeIfNeeded()
        let singleCost = (CACurrentMediaTime() - single) * 1000
        window.setFrame(compactRect, display: true)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        hosting.passes = []
        // 窗口每改一次尺寸都会发通知，这是与驱动方式无关的真实节拍
        var steps: [(at: CFTimeInterval, size: CGSize)] = []
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                             object: window,
                                                             queue: nil) { note in
            guard let target = note.object as? NSWindow else { return }
            steps.append((CACurrentMediaTime(), target.frame.size))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let begin = CACurrentMediaTime()
        var finished = false
        let seconds = Double(settings.animationDuration) / 1000
        switch driver {
        case .appKit:
            NSAnimationContext.runAnimationGroup { context in
                context.duration = seconds
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                window.animator().setFrame(expandedRect, display: true)
            } completionHandler: {
                finished = true
            }
        case .displayLink:
            let animator = PanelFrameAnimator(window: window)
            animator.animate(to: expandedRect, duration: seconds) {
                finished = true
            }
        }
        let wait = Date().addingTimeInterval(3)
        while !finished && Date() < wait {
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
        }
        let total = (CACurrentMediaTime() - begin) * 1000
        let passes = hosting.passes

        // 展开落位后静止 1 秒：动画之后是否留下持续重排
        hosting.passes = []
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let afterPasses = hosting.passes.count
        let afterCost = hosting.passes.map(\.cost).reduce(0, +)
        hosting.recording = false

        let costs = passes.map(\.cost)
        let layoutTotal = costs.reduce(0, +)
        let worstLayout = costs.max() ?? 0
        let distinct = Set(steps.map { "\(Int($0.size.width))x\(Int($0.size.height))" }).count
        var gaps: [(at: Double, value: Double)] = []
        if steps.count > 1 {
            for index in 1..<steps.count {
                gaps.append(((steps[index].at - begin) * 1000,
                             (steps[index].at - steps[index - 1].at) * 1000))
            }
        }
        let values = gaps.map(\.value)
        let meanGap = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let worstGap = values.max() ?? 0

        print("")
        print("页面 \(page.displayName) · \(driver.title)：\(Int(compact.width))×\(Int(compact.height)) → \(Int(expanded.width))×\(Int(expanded.height))")
        print("  第一次构建视图树并布局 \(String(format: "%.2f", buildCost)) 毫秒")
        print("  一次落位的布局耗时 \(String(format: "%.2f", singleCost)) 毫秒")
        print("  静止 1 秒里布局 \(idlePasses) 次，合计 \(String(format: "%.1f", idleCost)) 毫秒")
        print("  动画实际时长 \(String(format: "%.0f", total)) 毫秒（设定 \(settings.animationDuration)）")
        print("  窗口改尺寸 \(steps.count) 次，\(distinct) 个不同尺寸；间隔 平均 \(String(format: "%.1f", meanGap)) 毫秒 最大 \(String(format: "%.1f", worstGap)) 毫秒（120 Hz 为 8.3）")
        if let first = steps.first, let last = steps.last {
            print("  第一次改尺寸在 \(String(format: "%.0f", (first.at - begin) * 1000)) 毫秒，最后一次在 \(String(format: "%.0f", (last.at - begin) * 1000)) 毫秒")
        }
        let late = gaps.filter { $0.value > 16 }
        print("  间隔超过 16 毫秒的次数 \(late.count)\(late.isEmpty ? "" : "，分别在 " + late.map { String(format: "%.0f 毫秒处停 %.1f", $0.at, $0.value) }.joined(separator: "、"))")
        print("  动画期间 SwiftUI 布局合计 \(String(format: "%.1f", layoutTotal)) 毫秒，最慢单次 \(String(format: "%.2f", worstLayout)) 毫秒，共 \(passes.count) 次")
        let heavy = passes.filter { $0.cost > 1 }
        if !heavy.isEmpty {
            print("  超过 1 毫秒的布局：" + heavy.map { String(format: "%.0f 毫秒处 %.2f", ($0.at - begin) * 1000, $0.cost) }.joined(separator: "、"))
        }
        print("  落位后静止 1 秒：布局 \(afterPasses) 次，合计 \(String(format: "%.1f", afterCost)) 毫秒")
    }
}
