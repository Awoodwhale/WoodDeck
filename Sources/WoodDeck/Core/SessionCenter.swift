import Foundation
import SwiftUI
import UserNotifications

// 汇总各助手的事件并按会话维护状态
@MainActor
final class SessionCenter: ObservableObject {
    static let shared = SessionCenter()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var lastAttention: AgentSession?
    @Published private(set) var installedAgents: [AgentKind: Bool] = [:]
    @Published private(set) var notificationPermission: NotificationPermission = .unknown
    // 最近一次安装或卸载的结果，供设置页显示
    @Published private(set) var hookMessage: String?
    @Published private(set) var hookError: String?

    private var server: HookSocketServer?
    private var watcher: SessionLogWatcher?
    private var pruneTimer: Timer?
    private var lastNotificationAt: [String: Date] = [:]
    // 每个会话已经发出的系统横幅，处理完之后从通知中心撤回
    private var bannerIdentifiers: [String: [String]] = [:]
    // 会话进入需要关注状态时的回调：岛上弹提示、可选自动展开
    var onAttention: ((AgentSession) -> Void)?
    // 会话离开需要关注的状态（例如用户已经在助手里批准）时的回调：收回提示
    var onAttentionCleared: ((AgentSession) -> Void)?

    private init() {}

    func start() {
        guard server == nil else { return }
        let server = HookSocketServer { event in
            Task { @MainActor in SessionCenter.shared.ingest(event) }
        }
        server.start()
        self.server = server

        // DeepSeek Harness 插件没装时的兜底：观察它的会话记录。
        // 插件已经实时上报时不再采用，记录要隔几秒才扫到，旧事件会把已经处理的审批重新标成等待
        let watcher = SessionLogWatcher { event in
            Task { @MainActor in
                guard SessionCenter.shared.installedAgents[.dsh] != true else { return }
                SessionCenter.shared.ingest(event)
            }
        }
        watcher.start()
        self.watcher = watcher
        refreshInstalledState()
        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        // 用户可能在系统设置里改授权，回到前台时重新读一次
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in SessionCenter.shared.refreshNotificationPermission() }
        }
        refreshNotificationPermission()
    }

    func stop() {
        server?.stop()
        server = nil
        watcher?.stop()
        watcher = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    // 需要用户注意的会话
    var attentionSessions: [AgentSession] {
        sessions.filter { $0.status.needsAttention }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var activeSessions: [AgentSession] {
        sessions.sorted { lhs, rhs in
            if lhs.status.priority != rhs.status.priority { return lhs.status.priority > rhs.status.priority }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var badgeCount: Int { attentionSessions.count }

    func ingest(_ event: AgentEvent) {
        guard SettingsStore.shared.settings.sessionNotifications.enabled(for: event.agent) else { return }
        guard !event.event.isEmpty else { return }

        let key = "\(event.agent.rawValue):\(event.session.isEmpty ? "default" : event.session)"
        var session = sessions.first { $0.id == key } ?? AgentSession(
            id: key,
            agent: event.agent,
            project: "",
            cwd: event.cwd,
            title: "",
            message: "",
            tool: "",
            status: .working,
            startedAt: event.date,
            updatedAt: event.date,
            eventCount: 0
        )

        if !event.cwd.isEmpty { session.cwd = event.cwd }
        if !event.tool.isEmpty { session.tool = event.tool }
        if !event.title.isEmpty { session.title = event.title }
        if !event.message.isEmpty, event.event != "title" { session.message = event.message }
        // 助手给出的会话标题优先；没有标题时用第一句提问区分同一项目里的多个会话
        let name = Self.clipName(event.name)
        if !name.isEmpty {
            session.name = name
            session.nameIsTitle = true
        } else if event.event == "prompt", !session.nameIsTitle, session.name.isEmpty {
            session.name = Self.clipName(event.message)
        }
        session.updatedAt = event.date
        session.eventCount += 1

        let previous = session.status
        switch event.event {
        case "session_start":
            session.status = .working
            session.startedAt = event.date
            session.message = Loc.t("会话已开始", "Session started")
        case "prompt":
            session.status = .working
        case "tool_start":
            session.status = .working
            if !event.tool.isEmpty {
                session.message = event.tool
            }
        case "tool_end":
            session.status = .working
        case "tool_failed", "error":
            session.status = .error
        case "permission_request":
            session.status = .waitingPermission
        case "permission_resolved":
            // 用户已经在助手里批准或拒绝，助手接着往下执行
            session.status = .working
        case "permission_denied":
            session.status = .working
            if session.message.isEmpty { session.message = Loc.t("权限被拒绝", "Permission denied") }
        case "notification":
            // 通知类事件（例如等待输入、达到限额）说明助手在等人；
            // 等待授权时 Claude Code 还会再发一条「需要授权」的通知，状态保持等待授权
            if previous != .waitingPermission { session.status = .waitingInput }
        case "stop":
            session.status = .waitingInput
        case "session_end":
            session.status = .done
        default:
            break
        }

        if let index = sessions.firstIndex(where: { $0.id == key }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }

        // 离开原来需要关注的状态：用户已经在助手里处理过了，收回这条会话的提示
        if previous.needsAttention, session.status != previous {
            clearAttention(session)
        }
        // 进入新的需要关注的状态才提醒，同一状态的重复事件不再打扰
        if session.status.needsAttention, session.status != previous {
            notify(session)
        }
        lastAttention = session.status.needsAttention ? session : (lastAttention?.id == session.id ? nil : lastAttention)
    }

    private static func clipName(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 40 ? String(collapsed.prefix(40)) + "…" : collapsed
    }

    func dismiss(_ session: AgentSession) {
        sessions.removeAll { $0.id == session.id }
        clearAttention(session)
    }

    func clearFinished() {
        sessions.removeAll { $0.status == .done || $0.status == .idle }
    }

    // 收回某个会话的提示：岛上提示、提醒保持的展开以及已经发出的系统横幅
    private func clearAttention(_ session: AgentSession) {
        onAttentionCleared?(session)
        guard let identifiers = bannerIdentifiers.removeValue(forKey: session.id), !identifiers.isEmpty else { return }
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func notify(_ session: AgentSession) {
        let settings = SettingsStore.shared.settings
        // 用户关掉了这个状态的提醒：会话页照常显示，岛上与系统通知保持安静
        guard settings.sessionNotifications.alerts(for: session.status) else { return }
        lastAttention = session
        // 岛上提示与系统横幅各自独立开关
        if settings.sessionNotifications.islandPopup {
            onAttention?(session)
        }
        guard settings.sessionNotifications.banner else { return }
        let throttleKey = session.id
        let now = Date()
        if let last = lastNotificationAt[throttleKey], now.timeIntervalSince(last) < 5 { return }
        lastNotificationAt[throttleKey] = now

        // 直接运行可执行文件时没有应用包，系统通知接口不可用
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(session.agent.displayName) · \(session.status.label)"
        content.subtitle = session.fullName
        content.body = String((session.message.isEmpty ? session.status.label : session.message).prefix(180))
        content.sound = settings.sessionNotifications.sound ? .default : nil
        let identifier = session.id + "-" + UUID().uuidString
        bannerIdentifiers[session.id, default: []].append(identifier)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // 十分钟没有更新的会话不再显示
    private func prune() {
        let cutoff = Date().addingTimeInterval(-600)
        sessions.removeAll { $0.updatedAt < cutoff }
    }

    func refreshInstalledState() {
        var map: [AgentKind: Bool] = [:]
        for agent in AgentKind.allCases {
            map[agent] = agent == .dsh
                ? DSHHookInstaller.anyInstalled(names: SettingsStore.shared.settings.dshSelectedProfiles)
                : HookInstaller.isInstalled(agent)
        }
        installedAgents = map
    }

    func clearHookFeedback() {
        hookMessage = nil
        hookError = nil
    }

    func install(_ agent: AgentKind) {
        apply(true, to: agent, reporting: true)
        refreshInstalledState()
    }

    func uninstall(_ agent: AgentKind) {
        apply(false, to: agent, reporting: true)
        refreshInstalledState()
    }

    // 开关某个助手的会话读取：开启时写入 WoodDeck 自己的钩子，关闭时只清理这些条目
    func setEnabled(_ enabled: Bool, for agent: AgentKind) {
        SettingsStore.shared.update { $0.sessionNotifications.setEnabled(enabled, for: agent) }
        apply(enabled, to: agent, reporting: true)
        refreshInstalledState()
    }

    // 启动时按开关状态对齐一次钩子
    func syncHooks() {
        for agent in AgentKind.allCases {
            let enabled = SettingsStore.shared.settings.sessionNotifications.enabled(for: agent)
            apply(enabled, to: agent, reporting: false)
        }
        refreshInstalledState()
    }

    private func apply(_ enabled: Bool, to agent: AgentKind, reporting: Bool) {
        hookMessage = nil
        hookError = nil
        if agent == .dsh {
            if enabled {
                installDSH(reporting: reporting)
            } else {
                uninstallDSH(reporting: reporting)
            }
            return
        }
        if enabled {
            HookInstaller.install(agent)
            if reporting {
                hookMessage = Loc.t("已开启 \(agent.displayName) 的会话读取", "Reading \(agent.displayName) sessions")
            }
        } else {
            HookInstaller.uninstall(agent)
            if reporting {
                hookMessage = Loc.t("已关闭 \(agent.displayName) 的会话读取", "Stopped reading \(agent.displayName) sessions")
            }
        }
    }

    private func installDSH(reporting: Bool) {
        let settings = SettingsStore.shared.settings
        guard DSHHookInstaller.locateDSH(customPath: settings.dshPath) != nil else {
            hookError = Loc.t("没有找到 dsh 可执行文件，请在配置面板里填写它的路径。",
                              "dsh was not found; set its path in the Configure panel.")
            return
        }
        guard let executable = Bundle.main.executablePath else {
            hookError = Loc.t("拿不到 WoodDeck 的可执行文件路径。", "The WoodDeck executable path is unavailable.")
            return
        }
        let names = settings.dshSelectedProfiles
        do {
            let profiles = try DSHHookInstaller.install(executablePath: executable, names: names)
            // 取消勾选的 profile 里也要清掉，否则关掉之后插件还在上报
            let selected = Set(DSHHookInstaller.selectedProfiles(names).map(\.name))
            let dropped = DSHHookInstaller.profiles.map(\.name).filter { !selected.contains($0) }
            if !dropped.isEmpty { _ = DSHHookInstaller.uninstall(names: dropped) }
            if reporting {
                let list = profiles.map(\.name).joined(separator: "、")
                hookMessage = Loc.t("已开启会话读取，插件写入 \(list)", "Reading sessions; plugin written to \(list)")
            }
        } catch {
            hookError = error.localizedDescription
        }
    }

    private func uninstallDSH(reporting: Bool) {
        let profiles = DSHHookInstaller.uninstall(names: [])
        if reporting {
            let list = profiles.map(\.name).joined(separator: "、")
            hookMessage = Loc.t("已关闭会话读取，插件从 \(list) 移除", "Stopped reading sessions; plugin removed from \(list)")
        }
    }

    func refreshNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else {
            notificationPermission = .unavailable
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let value = NotificationPermission(settings.authorizationStatus)
            Task { @MainActor in SessionCenter.shared.notificationPermission = value }
        }
    }

    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else {
            notificationPermission = .unavailable
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in SessionCenter.shared.refreshNotificationPermission() }
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }
}

// 系统通知权限的当前状态
enum NotificationPermission: Sendable {
    case unknown
    case unavailable
    case notDetermined
    case denied
    case authorized

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .authorized
        @unknown default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .unknown: Loc.t("读取中…", "Checking…")
        case .unavailable: Loc.t("直接运行可执行文件时不可用", "Not available when running the bare executable")
        case .notDetermined: Loc.t("尚未请求", "Not requested yet")
        case .denied: Loc.t("已拒绝", "Denied")
        case .authorized: Loc.t("已允许", "Allowed")
        }
    }

    // 需要在设置里请求授权
    var needsRequest: Bool { self == .notDetermined || self == .unknown }

    // 只能去系统设置里改
    var needsSystemSettings: Bool { self == .denied }
}
