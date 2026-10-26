import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class DeckAppState: ObservableObject {
    @Published var expanded = false
    @Published var page: DeckPage = .quota
    @Published var showingSettings = false
}

struct IslandRootView: View {
    @ObservedObject var model: DeckModel
    @ObservedObject var state: DeckAppState
    var onMusicCommand: (MediaCommand) -> Void
    var onSeek: (Double) -> Void
    var onDetails: (UUID) -> Void
    var onExpandRequest: () -> Void
    var onPageChanged: ((DeckPage) -> Void)?

    @ObservedObject private var sessionCenter = SessionCenter.shared

    var body: some View {
        Group {
            if state.expanded {
                ExpandedPanelView(settings: model.settings,
                                  columns: model.columns,
                                  music: model.music,
                                  // 页面可能在设置里被关掉，渲染时收敛到可用列表
                                  page: pages.contains(state.page) ? state.page : (pages.first ?? .quota),
                                  refreshing: model.refreshing,
                                  lastRefresh: model.lastRefresh,
                                  onPageChange: { page in
                                      state.page = page
                                      model.update { $0.lastPage = page }
                                      // 切到监控页才开始抓进程列表，切走就停掉
                                      onPageChanged?(page)
                                      model.fastLyricTicker = state.expanded && page == .music
                                  },
                                  onRefresh: { model.refresh() },
                                  onSettings: { SettingsWindowController.shared.show() },
                                  onMusicCommand: onMusicCommand,
                                  onSeek: onSeek,
                                  onMode: { model.cyclePlaybackMode() },
                                  onDetails: onDetails,
                                  sessions: sessionCenter.activeSessions,
                                  onDismissSession: { session in sessionCenter.dismiss(session) },
                                  onClearFinished: { sessionCenter.clearFinished() },
                                  pages: pages,
                                  alertText: model.compactAlert?.text ?? "",
                                  alertColor: model.compactAlert?.color ?? .white)
                .transition(.opacity)
            } else {
                CompactIslandView(content: model.compactContent(), onTap: onExpandRequest)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 面板里可切换的页面：额度、会话、音乐各自独立
    private var pages: [DeckPage] {
        var list: [DeckPage] = []
        if model.settings.quotaPage { list.append(.quota) }
        if model.settings.sessionsPage { list.append(.sessions) }
        if model.settings.musicPage { list.append(.music) }
        if model.settings.monitorPage { list.append(.monitor) }
        return list.isEmpty ? [.quota] : list
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = DeckModel.shared
    private let island = IslandController()
    private let state = DeckAppState()
    private var statusItem: NSStatusItem?
    private var settingsToken: UUID?
    private var fullscreenTimer: Timer?
    private var hotkeyIDs: [UInt32] = []
    private var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()

        SessionCenter.shared.start()
        // 会话需要处理或结束时：岛上弹提示，按设置决定是否自动展开
        SessionCenter.shared.onAttention = { [weak self] session in
            guard let self else { return }
            self.model.flashSession(session)
            guard self.model.settings.sessionNotifications.autoExpand else { return }
            let target = self.availablePages.contains(.sessions) ? DeckPage.sessions : (self.availablePages.first ?? .sessions)
            self.state.page = target
            self.island.expand(requestedPage: target)
            self.reflow(animated: true)
        }
        SessionCenter.shared.requestNotificationPermission()
        if model.settings.sessionNotifications.anyEnabled {
            for agent in AgentKind.allCases where model.settings.sessionNotifications.enabled(for: agent) {
                HookInstaller.install(agent)
            }
            SessionCenter.shared.refreshInstalledState()
        }

        state.page = initialPage()
        state.showingSettings = false

        island.onRightClickSettings = {
            guard SettingsStore.shared.settings.rightClickSettings else { return }
            SettingsWindowController.shared.show()
        }
        // 点击收起形态时展开：点击事件在 AppKit 层处理，非激活面板也能收到
        // 打开设置时收起灵动岛，避免它盖在设置窗口上
        SettingsWindowController.shared.onWillShow = { [weak self] in
            guard let self else { return }
            self.island.collapse()
            self.state.expanded = false
            self.reflow(animated: true)
        }
        // 悬停或点击左段进音乐页，右段进设置的页面
        island.onOpenRequest = { [weak self] page in
            guard let self else { return }
            guard self.availablePages.contains(page) || page == .music else { return }
            self.state.page = self.availablePages.contains(page) ? page : (self.availablePages.first ?? .sessions)
            self.model.update { $0.lastPage = self.state.page }
        }
        island.onTapRequest = { [weak self] in
            guard let self else { return }
            self.state.expanded = self.island.isExpanded
            self.reflow(animated: true)
        }
        island.onAnimationChanged = { [model] animating in
            model.panelAnimating = animating
        }
        island.onExpandChanged = { [weak self] expanded in
            guard let self else { return }
            self.state.expanded = expanded
            self.reflow(animated: true)
        }

        installContent()
        reflow(animated: false)
        island.show()

        settingsToken = SettingsStore.shared.observe { [weak self] _ in
            guard let self else { return }
            self.reflow(animated: true)
            self.registerHotkeys()
            self.applyLaunchAtLogin()
        }

        registerHotkeys()
        applyLaunchAtLogin()
        startFullscreenWatcher()
        model.start()

        if CommandLine.arguments.contains("--settings") {
            SettingsWindowController.shared.show()
        }

        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // 分辨率或显示器变化后，缓存的刘海度量失效
                ScreenMetrics.invalidateCache()
                self?.island.invalidateRegions()
                self?.reflow(animated: false)
            }
        }
    }

    // 截图自检：把面板按指定页面展开显示（不激活、不抢焦点），供外部抓图
    var panelWindowNumber: Int { island.windowNumber }

    func showPanelForCapture(page: DeckPage) {
        island.setHiddenByRule(false)
        island.show()
        state.page = page
        island.expand()
        reflow(animated: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    private func installContent() {
        island.setContent(IslandRootView(
            model: model,
            state: state,
            onMusicCommand: { [model] command in model.musicCommand(command) },
            onSeek: { [model] seconds in model.seekMusic(to: seconds) },
            onDetails: { id in
                SettingsWindowController.shared.showDetails(columnID: id)
            },
            onExpandRequest: { [weak self] in
                guard let self else { return }
                self.island.expand()
                self.reflow(animated: true)
            },
            onPageChanged: { [weak self] _ in self?.syncMonitorSampling() }
        ))
    }

    private func reflow(animated: Bool) {
        syncMonitorSampling()
        // 展开且停在音乐页时用更快的节拍推进歌词，其余情况回到低频率
        model.fastLyricTicker = state.expanded && state.page == .music
        island.apply(settings: model.settings, screen: activeScreen(), animated: animated)
        state.objectWillChange.send()
    }

    // 监控采样只在需要时运行：收起形态要读数，或面板正停在监控页。
    // 进程列表最贵，只有监控页可见时才抓；收起形态只取 CPU / 内存 / 网络
    private func syncMonitorSampling() {
        let settings = model.settings
        let pageVisible = state.expanded && state.page == .monitor && settings.monitorPage
        let needed = settings.monitorInCompact || pageVisible
        if needed {
            SystemMonitorModel.shared.start(includeProcesses: pageVisible)
        } else {
            SystemMonitorModel.shared.stop()
        }
    }

    // 打开面板时的页面，避开被关掉的页
    private func initialPage() -> DeckPage {
        let settings = model.settings
        let wanted: DeckPage
        switch settings.defaultPage {
        case .quota: wanted = .quota
        case .sessions: wanted = .sessions
        case .music: wanted = .music
        case .monitor: wanted = .monitor
        case .last: wanted = settings.lastPage
        }
        if isAvailable(wanted) { return wanted }
        return availablePages.first ?? .quota
    }

    private var availablePages: [DeckPage] {
        let settings = model.settings
        var list: [DeckPage] = []
        if settings.quotaPage { list.append(.quota) }
        if settings.sessionsPage { list.append(.sessions) }
        if settings.musicPage { list.append(.music) }
        if settings.monitorPage { list.append(.monitor) }
        return list
    }

    private func isAvailable(_ page: DeckPage) -> Bool {
        availablePages.contains(page)
    }

    // 面板显示在设置里选定的屏幕上
    private func activeScreen() -> NSScreen? {
        ScreenCatalog.target(for: model.settings)
    }

    // 全屏时按设置隐藏或切换为指示条
    private func startFullscreenWatcher() {
        fullscreenTimer?.invalidate()
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateScreenContext() }
        }
    }

    private func evaluateScreenContext() {
        let fullscreen = FullscreenWatcher.isFrontmostFullscreen()
        let settings = model.settings
        island.setFullscreenActive(fullscreen)
        switch fullscreen ? settings.fullscreenBehavior : .normal {
        case .hide:
            island.setHiddenByRule(true)
        default:
            island.setHiddenByRule(false)
        }
        reflow(animated: false)
    }

    private func registerHotkeys() {
        for id in hotkeyIDs { HotkeyCenter.shared.unregister(id) }
        hotkeyIDs.removeAll()
        let settings = model.settings
        if let hotkey = Hotkey.decode(settings.hideHotkey) {
            if let id = HotkeyCenter.shared.register(hotkey, action: { [weak self] in
                Task { @MainActor in self?.island.setHiddenByRule(true) }
            }) { hotkeyIDs.append(id) }
        }
        if let hotkey = Hotkey.decode(settings.expandHotkey) {
            if let id = HotkeyCenter.shared.register(hotkey, action: { [weak self] in
                Task { @MainActor in
                    self?.island.setHiddenByRule(false)
                    self?.island.expand()
                    self?.reflow(animated: true)
                }
            }) { hotkeyIDs.append(id) }
        }
    }

    private func applyLaunchAtLogin() {
        do {
            if model.settings.launchAtStartup {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            SupportFiles.writeCrash("开机启动设置失败：\(error.localizedDescription)")
        }
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "WoodDeck")
        let menu = NSMenu()
        menu.addItem(menuItem(Loc.t("显示面板", "Show panel"), #selector(showPanel)))
        menu.addItem(menuItem(Loc.t("展开面板", "Expand panel"), #selector(expandPanel)))
        menu.addItem(.separator())
        menu.addItem(menuItem(Loc.t("刷新", "Refresh"), #selector(refreshNow)))
        menu.addItem(menuItem(Loc.t("设置…", "Settings…"), #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem(Loc.t("退出 WoodDeck", "Quit WoodDeck"), #selector(quit)))
        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showPanel() {
        island.setHiddenByRule(false)
        island.show()
        reflow(animated: false)
    }

    @objc private func expandPanel() {
        island.setHiddenByRule(false)
        island.show()
        island.expand()
        reflow(animated: true)
    }

    @objc private func refreshNow() {
        model.refresh()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

enum FullscreenWatcher {
    // 判断最前面的应用是否占满一整块屏幕
    static func isFrontmostFullscreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              front.bundleIdentifier != "com.apple.finder" else { return false }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == front.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            for screen in NSScreen.screens where screen.frame.width > 0 {
                if abs(bounds.width - screen.frame.width) < 2, abs(bounds.height - screen.frame.height) < 2 {
                    return true
                }
            }
        }
        return false
    }
}
