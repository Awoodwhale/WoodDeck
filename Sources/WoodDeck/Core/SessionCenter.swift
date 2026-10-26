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

    private var server: HookSocketServer?
    private var watcher: SessionLogWatcher?
    private var pruneTimer: Timer?
    private var lastNotificationAt: [String: Date] = [:]
    // 会话进入需要关注状态时的回调：岛上弹提示、可选自动展开
    var onAttention: ((AgentSession) -> Void)?

    private init() {}

    func start() {
        guard server == nil else { return }
        let server = HookSocketServer { event in
            Task { @MainActor in SessionCenter.shared.ingest(event) }
        }
        server.start()
        self.server = server

        // DeepSeek Harness 没有命令式 hook，改为观察它的会话记录
        let watcher = SessionLogWatcher { event in
            Task { @MainActor in SessionCenter.shared.ingest(event) }
        }
        watcher.start()
        self.watcher = watcher
        refreshInstalledState()
        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
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
        if !event.message.isEmpty { session.message = event.message }
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
        case "permission_denied":
            session.status = .working
            if session.message.isEmpty { session.message = Loc.t("权限被拒绝", "Permission denied") }
        case "notification":
            // 通知类事件（例如等待输入、达到限额）说明助手在等人
            session.status = .waitingInput
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

        // 从工作状态转为需要关注时才提醒，避免重复打扰
        if session.status.needsAttention, !previous.needsAttention {
            notify(session)
        }
        lastAttention = session.status.needsAttention ? session : lastAttention
    }

    func dismiss(_ session: AgentSession) {
        sessions.removeAll { $0.id == session.id }
    }

    func clearFinished() {
        sessions.removeAll { $0.status == .done || $0.status == .idle }
    }

    private func notify(_ session: AgentSession) {
        lastAttention = session
        let settings = SettingsStore.shared.settings
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
        let body = session.message.isEmpty ? session.projectName : "\(session.projectName)：\(session.message)"
        content.body = String(body.prefix(180))
        content.sound = settings.sessionNotifications.sound ? .default : nil
        let request = UNNotificationRequest(identifier: session.id + "-" + UUID().uuidString,
                                            content: content, trigger: nil)
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
            map[agent] = HookInstaller.isInstalled(agent)
        }
        installedAgents = map
    }

    func install(_ agent: AgentKind) {
        HookInstaller.install(agent)
        refreshInstalledState()
    }

    func uninstall(_ agent: AgentKind) {
        HookInstaller.uninstall(agent)
        refreshInstalledState()
    }

    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
