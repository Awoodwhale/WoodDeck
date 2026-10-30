import AppKit

// 会话提醒的完整链路自检：事件经 `--hook dsh` 子进程真实送进套接字，
// 检查提醒展开不取得焦点、审批处理后自动收回、按状态的提醒开关、会话名称。
// 指针位置直接喂给悬停判定，不合成任何键盘或鼠标事件
@MainActor
enum AttentionTest {
    private final class Box {
        var attentionID: String?
    }

    static func run() {
        let original = SettingsStore.shared.settings.sessionNotifications
        SettingsStore.shared.update {
            $0.sessionNotifications.dsh = true
            $0.sessionNotifications.claude = true
            $0.sessionNotifications.islandPopup = true
            $0.sessionNotifications.autoExpand = true
            $0.sessionNotifications.banner = false
            $0.sessionNotifications.islandSeconds = 8
            $0.sessionNotifications.alertPermission = true
            $0.sessionNotifications.alertInput = true
            $0.sessionNotifications.alertError = true
        }
        defer { SettingsStore.shared.update { $0.sessionNotifications = original } }

        let settings = SettingsStore.shared.settings
        guard let screen = ScreenCatalog.target(for: settings) else { print("没有目标屏幕"); return }
        IslandController.pointerTestMode = true
        defer { IslandController.pointerTestMode = false }
        let controller = IslandController()
        let model = DeckModel.shared
        let center = SessionCenter.shared
        let box = Box()
        center.onAttention = { session in
            model.flashSession(session)
            box.attentionID = session.id
            controller.expandForAttention(requestedPage: .sessions, holdFor: settings.sessionNotifications.islandSeconds)
        }
        center.onAttentionCleared = { session in
            model.clearSessionAlert(for: session.id)
            guard box.attentionID == session.id else { return }
            box.attentionID = nil
            controller.releaseAttention()
        }
        center.start()
        defer { center.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        // 用户的指针停在屏幕另一侧，正在别的应用里干活
        let outside = NSPoint(x: screen.frame.minX + 40, y: screen.frame.midY)
        let panelFrame = controller.expandedFrame(settings: settings, screen: screen)
        let onIsland = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
        controller.handlePointer(at: outside)

        let cwd = "/Users/wood/Downloads/WorkSpace/AgentDir/WoodDeck"
        print("一、会话名称")
        send(["event": "title", "session": "attn-a", "cwd": cwd, "name": "修复弹窗抢焦点"])
        send(["event": "prompt", "session": "attn-b", "cwd": cwd, "message": "帮我看看  歌词\n为什么提前了"])
        for id in ["dsh:attn-a", "dsh:attn-b"] {
            let session = center.sessions.first { $0.id == id }
            print("  \(id) → 名称「\(session?.displayName ?? "无")」，完整「\(session?.fullName ?? "无")」")
        }

        print("二、等待授权的提醒不抢焦点")
        send(["event": "permission_request", "session": "attn-a", "cwd": cwd, "tool": "bash", "message": "运行 swift build"])
        var input = controller.panelInputStateForTest
        print("  展开：\(mark(controller.isExpanded))  只提示：\(mark(controller.isPassive))  键盘焦点在面板：\(mark(!input.isKey, yes: "否", no: "是"))  点击穿过面板：\(mark(input.ignoresMouse))")
        print("  岛上提示：\(model.compactContent().alertText ?? "无")")
        controller.handlePointer(at: outside)
        print("  指针在岛外时仍保持展开：\(mark(controller.isExpanded))")

        print("三、在助手里批准之后自动收回")
        send(["event": "permission_resolved", "session": "attn-a", "cwd": cwd, "message": "allowed-once"])
        let status = center.sessions.first { $0.id == "dsh:attn-a" }?.status
        print("  会话状态：\(status?.label ?? "无")  已收起：\(mark(!controller.isExpanded))  岛上提示已清除：\(mark(model.compactContent().alertText == nil))")

        print("四、指针移到岛上之后交给用户操作")
        send(["event": "permission_request", "session": "attn-a", "cwd": cwd, "tool": "bash", "message": "再运行一次"])
        controller.handlePointer(at: onIsland)
        input = controller.panelInputStateForTest
        print("  只提示阶段结束：\(mark(!controller.isPassive))  面板接收点击：\(mark(!input.ignoresMouse))")
        send(["event": "tool_end", "session": "attn-a", "cwd": cwd, "tool": "bash"])
        print("  用户正在看面板时，处理完审批不强行收起：\(mark(controller.isExpanded))  提示已清除：\(mark(model.compactContent().alertText == nil))")
        controller.handlePointer(at: outside)
        print("  指针离开后收起：\(mark(!controller.isExpanded))")

        print("五、按状态关闭提醒")
        SettingsStore.shared.update { $0.sessionNotifications.alertError = false }
        send(["event": "error", "session": "attn-b", "cwd": cwd, "message": "rate limit"])
        let errored = center.sessions.first { $0.id == "dsh:attn-b" }?.status
        print("  出错（提醒已关）：会话状态 \(errored?.label ?? "无")  没有展开：\(mark(!controller.isExpanded))  没有提示：\(mark(model.compactContent().alertText == nil))")
        send(["event": "stop", "session": "attn-b", "cwd": cwd, "message": "end_turn"])
        print("  等待输入（提醒开着）：展开：\(mark(controller.isExpanded))  提示：\(model.compactContent().alertText ?? "无")")
        controller.collapse()

        print("六、Claude Code 会话标题")
        let titled = latestClaudeTitle()
        print("  \(titled.summary)")
        if let path = titled.path {
            send(["hook_event_name": "PermissionRequest", "session_id": "attn-c", "cwd": cwd,
                  "transcript_path": path, "tool_name": "Bash"], agent: "claude")
            let session = center.sessions.first { $0.id == "claude:attn-c" }
            print("  经 --hook claude 送达后会话名称：「\(session?.displayName ?? "无")」  状态：\(session?.status.label ?? "无")")
            print("  岛上提示：\(model.compactContent().alertText ?? "无")")
            controller.collapse()
        }
    }

    private static func send(_ fields: [String: String], agent: String = "dsh") {
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { fatalError("事件无法编码") }
        let process = Process()
        process.executableURL = URL(filePath: CommandLine.arguments[0])
        process.arguments = ["--hook", agent]
        let pipe = Pipe()
        process.standardInput = pipe
        do {
            try process.run()
        } catch {
            fatalError("无法启动 --hook 子进程：\(error.localizedDescription)")
        }
        pipe.fileHandleForWriting.write(data)
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    private static func mark(_ ok: Bool, yes: String = "是", no: String = "否") -> String {
        ok ? "\(yes) ✓" : "\(no) ✗"
    }

    // 从新到旧找 Claude Code 会话记录，读出第一个有标题的会话的标题；
    // 用 -p 跑的非交互会话不生成标题，这类会话靠第一句提问命名
    private static func latestClaudeTitle() -> (summary: String, path: String?) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return ("没有会话记录", nil) }
        var files: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, date))
        }
        var skipped = 0
        for file in files.sorted(by: { $0.date > $1.date }).prefix(60) {
            let path = file.url.path(percentEncoded: false)
            let started = Date()
            let title = HookEmitter.claudeTitle(transcript: path)
            guard !title.isEmpty else { skipped += 1; continue }
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let cost = Date().timeIntervalSince(started) * 1000
            return ("标题「\(title)」：跳过 \(skipped) 个没有标题的记录，这份记录 \(size / 1024) KB，读取 \(String(format: "%.1f", cost)) 毫秒", path)
        }
        return ("最近 60 个会话记录都没有标题", nil)
    }
}
