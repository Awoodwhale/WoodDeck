import AppKit
import SwiftUI

// 收起与展开之间的目标尺寸与位置
struct IslandRect {
    var frame: NSRect
    var style: CompactStyle
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 238, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // 面板贴着菜单栏，层级必须高于菜单栏，否则鼠标移动与点击会被菜单栏吃掉
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }
}

// 覆盖整块面板的追踪视图，负责悬停进出
final class TrackingContainerView<Content: View>: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onTap: (() -> Void)?
    private var tracking: NSTrackingArea?
    private let hosting: NSHostingView<Content>

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        // 用 frame 与自动调整尺寸而不是约束，宿主的固有尺寸就不会改动窗口大小
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    private var trackedBounds: NSRect = .zero

    override func layout() {
        super.layout()
        hosting.frame = bounds
        if bounds != trackedBounds {
            trackedBounds = bounds
            installTrackingArea()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTrackingArea()
    }

    private func installTrackingArea() {
        if let tracking { removeTrackingArea(tracking) }
        guard bounds.width > 0, bounds.height > 0 else {
            tracking = nil
            return
        }
        trackedBounds = bounds
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // 非激活面板的第一次点击默认只用于激活窗口，这里直接接受
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let onTap { onTap() } else { super.mouseDown(with: event) }
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick() } else { super.rightMouseDown(with: event) }
    }
}

@MainActor
final class IslandController {
    private(set) var panel: IslandPanel
    private var container: TrackingContainerView<AnyView>?
    private var expanded = false
    // 最近一次展开的时刻，用于抑制刚展开就收起的抖动
    private var lastExpandAt = Date.distantPast
    private var openWork: DispatchWorkItem?
    // 已排程的展开目标页：指针停在同一段时不必每帧重建定时器
    private var pendingOpenPage: DeckPage??
    private var escapeMonitor: Any?
    private var mouseMonitor: Any?
    private var clickMonitor: Any?
    private var pointerInside = false
    private var fullscreenActive = false
    private var hiddenByRule = false

    var isExpanded: Bool { expanded }
    // 自检用：丢弃待执行的展开，模拟每次都是新进入
    func cancelPendingOpenForTest() {
        openWork?.cancel()
        openWork = nil
        pendingOpenPage = nil
    }

    // 供自检按实际生效的样式取判定点
    func effectiveStyleForTest(_ settings: DeckSettings) -> CompactStyle { effectiveStyle(settings) }
    var windowNumber: Int { panel.windowNumber }

    var onRightClickSettings: (() -> Void)?
    var onTapRequest: (() -> Void)?
    // 请求展开时带上要显示的页面（分列布局下按左右段决定）
    var onOpenRequest: ((DeckPage) -> Void)?
    // 面板开始或结束变尺寸，用于暂停律动条重绘
    var onAnimationChanged: ((Bool) -> Void)?
    var onExpandChanged: ((Bool) -> Void)?

    init() {
        panel = IslandPanel()
        let view = TrackingContainerView(rootView: AnyView(Color.clear))
        container = view
        panel.contentView = view
        // 悬停只由全局指针监听驱动，视图追踪区域不再参与，避免改尺寸时重复触发
        view.onRightClick = { [weak self] in
            guard let self, self.expanded else { return }
            self.onRightClickSettings?()
        }
        view.onTap = { [weak self] in self?.onTapRequest?() }
        // 面板贴着菜单栏时，鼠标事件可能被菜单栏吃掉，这里直接按全局指针位置判断进出
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.keepPollingAwake()
                self.pointerMoved()
            }
        }
        // 菜单栏那一条的点击由系统接管，点击只能通过全局监听拿到
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.pointerClicked(at: point) }
            _ = event
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.expanded, event.keyCode == 53 else { return event }
            self.collapse()
            return nil
        }
    }

    deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    // 全局监听拿到的点击：落在面板上就展开或收起
    private func pointerClicked(at point: NSPoint) {
        guard panel.isVisible, !hiddenByRule else { return }
        guard panel.frame.contains(point) else { return }
        if expanded {
            collapse()
            onTapRequest?()
            return
        }
        let settings = SettingsStore.shared.settings
        let target = page(for: point, settings: settings, screen: ScreenCatalog.target(for: settings))
        expand(requestedPage: target)
        onTapRequest?()
    }

    // 悬停判定用的区域：收起时是收起形态，展开后是收起形态与面板的并集。
    // 直接拿 panel.frame 判断会在展开的瞬间把光标判成「在外面」，从而反复收起再展开
    // 缓存失效：设置、屏幕、窗口尺寸或展开状态变化时
    func invalidateRegions() {
        regionsDirty = true
    }

    private var hoverRegion: NSRect {
        let settings = SettingsStore.shared.settings
        guard let screen = ScreenCatalog.target(for: settings) else { return panel.frame }
        let compact = compactFrame(settings: settings, style: effectiveStyle(settings), screen: screen)
        var region = expanded ? compact.union(expandedFrame(settings: settings, screen: screen)) : compact
        // 收起形态贴着屏幕顶部，把上边界延伸到屏幕顶，光标落在菜单栏那一条也算在里面
        region.size.height = screen.frame.maxY - region.minY
        return region
    }

    // 进入判定比面板略大一点，方便从边缘划进来；收起判定必须覆盖整个面板，
    // 否则面板边缘（例如右上角的设置按钮）会被判成区域之外，鼠标还没到就收起了
    private var regions: (expand: NSRect, collapse: NSRect) {
        if !regionsDirty, let cached = cachedRegions, cached.expanded == expanded {
            return (cached.expand, cached.collapse)
        }
        let region = hoverRegion
        let expandRect = NSRect(x: region.minX - 8, y: region.minY,
                                width: region.width + 16, height: region.height + 6)
        // 收起判定向外放 2pt，避免光标压在边界像素上时来回抖动
        let collapseRect = NSRect(x: region.minX - 2, y: region.minY - 2,
                                  width: region.width + 4, height: region.height + 4)
        cachedRegions = (expanded, expandRect, collapseRect)
        regionsDirty = false
        return (expandRect, collapseRect)
    }

    private var expandRegion: NSRect { regions.expand }

    private var collapseRegion: NSRect { regions.collapse }

    // 分列布局下指针所在的段：左段返回音乐页，右段返回设置的页面
    func page(for point: NSPoint, settings: DeckSettings, screen: NSScreen?) -> DeckPage? {
        guard settings.style == .notch, let screen else { return nil }
        let metrics = ScreenMetrics.of(screen)
        guard metrics.hasNotch, settings.notchLayout == .split else { return nil }
        let geometry = CompactGeometry.compact(settings, style: .notch, metrics: metrics)
        guard geometry.splitLeft > 0 else { return nil }
        let frame = compactFrame(settings: settings, style: .notch, screen: screen)
        let notchStart = frame.minX + geometry.splitLeft
        let notchEnd = notchStart + geometry.splitNotch
        if point.x < notchStart { return .music }
        if point.x > notchEnd { return settings.notchRightPage }
        return nil
    }

    // 窗口刚改过尺寸的一小段时间内忽略指针判定，避免尺寸变化引起反复开合
    private var lastFrameChangeAt = Date.distantPast
    // 悬停由定时轮询驱动：面板是非激活窗口，指针压在它上面时全局 mouseMoved 收不到事件，
    // 只靠事件监听会在「指针停在岛上」这段静默，进出边界就变得不跟手
    private var hoverTimer: Timer?
    // 动画进行中不切换展开状态，避免半途改变目标尺寸
    private var animating = false
    // 判定区域按状态缓存：轮询每秒 60 次，不必每次都重算屏幕与窗口矩形
    private var cachedRegions: (expanded: Bool, expand: NSRect, collapse: NSRect)?
    private var regionsDirty = true

    private var lastPointerPoint = NSPoint.zero

    // 自检模式下允许在没有显示面板时驱动悬停判定
    nonisolated(unsafe) static var pointerTestMode = false

    private func pointerMoved() {
        handlePointer(at: NSEvent.mouseLocation)
    }

    // 指针进入或离开面板。展开要等停留时间，收起立刻发生
    func handlePointer(at point: NSPoint) {
        guard panel.isVisible || Self.pointerTestMode, !hiddenByRule else { return }
        lastPointerPoint = point
        // 尺寸正在动画中，等落位后再判定，否则会在过渡帧上反复切换
        guard !animating else { return }

        if collapseRegion.contains(point) {
            // 仍在区域内：未展开时按停留时间排程展开
            pointerInside = true
            if !expanded {
                scheduleOpen()
            }
            return
        }

        // 离开区域：无条件取消待执行的展开，并立刻收起
        openWork?.cancel()
        pointerInside = false
        if expanded {
            collapse()
        }
    }

    private func scheduleOpen() {
        guard !expanded, !hiddenByRule else {
            openWork?.cancel()
            openWork = nil
            pendingOpenPage = nil
            return
        }
        // 鼠标已经离开时不再展开
        guard expandRegion.contains(lastPointerPoint) else {
            openWork?.cancel()
            openWork = nil
            pendingOpenPage = nil
            return
        }
        let settings = SettingsStore.shared.settings
        // 设置为点击展开时，悬停不展开
        guard settings.expandTrigger == .hover else {
            openWork?.cancel()
            openWork = nil
            pendingOpenPage = nil
            return
        }
        // 已经在等同一段的目标页，保持原定时器不动（轮询每帧都会走到这里）
        if openWork != nil, let pending = pendingOpenPage, pending == page(for: lastPointerPoint, settings: settings, screen: ScreenCatalog.target(for: settings)) {
            return
        }
        openWork?.cancel()
        let target = page(for: lastPointerPoint, settings: settings, screen: ScreenCatalog.target(for: settings))
        let delay = max(0, settings.openDelay)
        guard delay > 0 else {
            pendingOpenPage = nil
            expand(requestedPage: target)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.openWork = nil
            self.pendingOpenPage = nil
            self.expand(requestedPage: target)
        }
        openWork = work
        pendingOpenPage = target
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }

    func setContent<Content: View>(_ content: Content) {
        if let container {
            container.removeFromSuperview()
        }
        let view = TrackingContainerView(rootView: AnyView(content))
        // 悬停只由全局指针监听驱动，视图追踪区域不再参与，避免改尺寸时重复触发
        view.onRightClick = { [weak self] in
            guard let self, self.expanded else { return }
            self.onRightClickSettings?()
        }
        view.onTap = { [weak self] in self?.onTapRequest?() }
        panel.contentView = view
        container = view
    }

    // 收起形态的目标矩形：贴在选中屏幕顶部中央
    func compactFrame(settings: DeckSettings, style: CompactStyle, screen: NSScreen?) -> NSRect {
        guard let screen else { return .zero }
        let geometry = CompactGeometry.compact(settings, style: style, metrics: ScreenMetrics.of(screen))
        let visible = screen.frame
        let width = min(geometry.width, visible.width)
        let offsetX = CompactGeometry.offsetX(settings, style: style)
        // 分列布局下按「让开的缺口」对齐物理摄像头：左右宽度不对称时整条居中是错的，
        // 那样缺口会偏离屏幕中心 (left - right) / 2，右侧内容也会跟着移位
        let originX: CGFloat
        if geometry.splitLeft > 0 {
            originX = visible.midX + offsetX - geometry.splitLeft - geometry.splitNotch / 2
        } else {
            originX = visible.midX + offsetX - width / 2
        }
        let clampedX = min(max(originX, visible.minX), visible.maxX - width)
        let originY = visible.maxY - geometry.topInset - geometry.height
        return NSRect(x: clampedX, y: originY, width: width, height: geometry.height)
    }

    func expandedFrame(settings: DeckSettings, screen: NSScreen?) -> NSRect {
        guard let screen else { return .zero }
        let visible = screen.frame
        let metrics = ScreenMetrics.of(screen)
        let width = min(settings.width, visible.width)
        let height = min(settings.height, visible.height)
        // 展开面板挂在刘海下方，不遮挡内容
        let styleTop = settings.style == .notch ? 0 : max(CompactGeometry.compact(settings, style: settings.style, metrics: metrics).topInset - metrics.notchHeight, 0)
        let topInset = metrics.notchHeight + styleTop
        let originX = min(max(visible.midX - width / 2, visible.minX), visible.maxX - width)
        let originY = visible.maxY - topInset - height
        return NSRect(x: originX, y: originY, width: width, height: height)
    }

    func apply(settings: DeckSettings, screen: NSScreen?, animated: Bool) {
        let style = effectiveStyle(settings)
        let target = expanded ? expandedFrame(settings: settings, screen: screen)
                              : compactFrame(settings: settings, style: style, screen: screen)
        let visible = !hiddenByRule
        panel.ignoresMouseEvents = !visible
        panel.alphaValue = visible ? 1 : 0

        lastFrameChangeAt = Date()
        regionsDirty = true
        guard target != panel.frame else { return }
        guard animated && settings.animations && panel.isVisible else {
            panel.setFrame(target, display: true)
            return
        }
        animating = true
        onAnimationChanged?(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Double(settings.animationDuration) / 1000
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            // 动画被打断时也要落到目标位置
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.panel.frame != target {
                    self.panel.setFrame(target, display: true)
                }
                self.lastFrameChangeAt = Date()
                self.animating = false
                self.onAnimationChanged?(false)
                // 动画期间指针可能已经移动，落位后立刻按当前位置判定一次
                self.pollPointer()
            }
        }
    }

    func show() {
        panel.orderFrontRegardless()
        startHoverPolling()
    }

    func hide() {
        panel.orderOut(nil)
        stopHoverPolling()
    }

    // 采样全局指针位置：靠近岛时 60Hz，远离时 10Hz。
    // 指针静止时也能正确判定进出，同时避免远离时白白唤醒主线程
    private var hoverInterval: TimeInterval = 0
    // 高频轮询的截止时间：只有指针在动或面板展开时才需要每帧采样，
    // 静止时停掉定时器，进程才能进入 App Nap，不拖住重绘与刷新
    private var pollUntil = Date.distantPast

    private func startHoverPolling() {
        pollUntil = Date().addingTimeInterval(1.5)
        ensureHoverTimer()
    }

    // 有指针事件时续期并保证定时器在跑
    private func keepPollingAwake() {
        pollUntil = Date().addingTimeInterval(1.5)
        ensureHoverTimer()
    }

    private func ensureHoverTimer() {
        guard hoverTimer == nil else {
            scheduleHoverTimer(interval: 1.0 / 60)
            return
        }
        scheduleHoverTimer(interval: 1.0 / 60)
    }

    private func scheduleHoverTimer(interval: TimeInterval) {
        guard hoverInterval != interval || hoverTimer == nil else { return }
        hoverTimer?.invalidate()
        hoverInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pollPointer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    // 指针离岛还有一段距离时就开始高频采样，进入之前就切到 60Hz
    private func watchRegion() -> NSRect {
        expandRegion.insetBy(dx: -140, dy: -140)
    }

    private func stopHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverInterval = 0
    }

    private func pollPointer() {
        guard panel.isVisible || Self.pointerTestMode, !hiddenByRule else { return }
        let point = NSEvent.mouseLocation
        let near = expanded || watchRegion().contains(point)
        let active = Date() <= pollUntil
        // 指针在动或就在附近时 60Hz，其余保持 10Hz 常驻低速采样。
        // 不能彻底停表：全局 mouseMoved 收不到发生在自己面板上的事件，
        // 停表之后指针移到岛上并静止，就再没有东西把它唤醒，表现为「失去焦点、悬停不出面板」
        scheduleHoverTimer(interval: active && near ? 1.0 / 60 : 1.0 / 10)
        handlePointer(at: point)
    }

    func expand() {
        expand(requestedPage: nil)
    }

    func expand(requestedPage: DeckPage?) {
        openWork?.cancel()
        guard !expanded, !hiddenByRule else { return }
        expanded = true
        lastExpandAt = Date()
        // 展开后取得键盘焦点，Esc 才能收起面板
        panel.makeKeyAndOrderFront(nil)
        if let requestedPage {
            onOpenRequest?(requestedPage)
        }
        onExpandChanged?(true)
    }

    func collapse() {
        guard expanded else { return }
        expanded = false
        regionsDirty = true
        onExpandChanged?(false)
    }

    // 全屏时按设置隐藏或只用指示条
    func setFullscreenActive(_ active: Bool) {
        guard active != fullscreenActive else { return }
        fullscreenActive = active
    }

    func effectiveStyle(_ settings: DeckSettings) -> CompactStyle {
        guard fullscreenActive else { return settings.style }
        switch settings.fullscreenBehavior {
        case .line: return .line
        case .hide, .normal: return settings.style
        }
    }

    func setHiddenByRule(_ hidden: Bool) {
        guard hidden != hiddenByRule else { return }
        hiddenByRule = hidden
        if hidden {
            expanded = false
            onExpandChanged?(false)
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }
}
