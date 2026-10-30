import Foundation

// 命令行入口：各助手调用 `WoodDeck --hook <agent>`，从标准输入读取事件并转给应用
enum HookEmitter {
    static let fallbackArgument = "--hook"

    // 返回是否已经按 hook 模式处理完毕
    static func handleIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: fallbackArgument), index + 1 < arguments.count else { return false }
        guard let agent = AgentKind(rawValue: arguments[index + 1]) else { return false }
        let event = arguments.count > index + 2 ? arguments[index + 2] : ""
        run(agent: agent, explicitEvent: event)
        return true
    }

    private static func run(agent: AgentKind, explicitEvent: String) {
        // 对端提前关闭时不要因为 SIGPIPE 直接终止，先拿到真实错误
        signal(SIGPIPE, SIG_IGN)
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let payload = (try? JSONValue.parse(data)) ?? .null
        guard var event = normalize(agent: agent, payload: payload, explicitEvent: explicitEvent) else {
            exit(0)
        }
        event.pid = event.pid ?? Int(getppid())
        send(event)
        exit(0)
    }

    // 把各助手的原始事件转换成统一格式
    static func normalize(agent: AgentKind, payload: JSONValue, explicitEvent: String) -> AgentEvent? {
        switch agent {
        case .claude:
            let name = payload["hook_event_name"].text
            let session = payload["session_id"].text
            let cwd = payload["cwd"].text
            let tool = payload["tool_name"].text
            let message = firstText(payload, ["message", "reason", "error", "notification"])
            let event: String
            switch name {
            case "SessionStart": event = "session_start"
            case "SessionEnd": event = "session_end"
            case "UserPromptSubmit": event = "prompt"
            case "PreToolUse": event = "tool_start"
            case "PostToolUse": event = "tool_end"
            case "PostToolUseFailure": event = "tool_failed"
            case "PermissionRequest": event = "permission_request"
            case "PermissionDenied": event = "permission_denied"
            case "Notification": event = "notification"
            case "Stop", "SubagentStop": event = "stop"
            case "StopFailure": event = "error"
            case "PreCompact", "PostCompact": event = "compact"
            default: event = explicitEvent.isEmpty ? name.lowercased() : explicitEvent
            }
            // 提问事件的正文是用户这一句话，用来在没有标题时给会话起名
            let text = event == "prompt" ? firstText(payload, ["prompt", "message"]) : message
            // 工具事件很密集，只在会弹提醒或换轮次的事件上读会话标题
            let title = titleEvents.contains(event) ? claudeTitle(transcript: payload["transcript_path"].text) : ""
            return AgentEvent(agent: .claude, event: event, session: session, cwd: cwd,
                              title: payload["tool_input"]["description"].text,
                              name: title,
                              message: text, tool: tool, pid: nil, timestamp: payload["timestamp"].float)

        case .codex:
            // Codex 的 notify 程序收到 {"type":"agent-turn-complete", ...}；
            // thread-id 是整段对话，turn-id 每轮都会变，按对话合并会话
            let type = payload["type"].text
            let session = payload["thread-id"].text.isEmpty ? payload["turn-id"].text : payload["thread-id"].text
            let message = firstText(payload, ["last-assistant-message", "message"])
            let event = type == "agent-turn-complete" ? "stop" : (explicitEvent.isEmpty ? type : explicitEvent)
            let firstInput = payload["input-messages"].array?.first?.text ?? ""
            return AgentEvent(agent: .codex, event: event, session: session, cwd: payload["cwd"].text,
                              title: "", name: firstInput, message: message, tool: "", pid: nil, timestamp: nil)

        case .gemini:
            let name = payload["hook_event_name"].text
            let session = payload["session_id"].text
            let cwd = payload["cwd"].text.isEmpty ? payload["workspace"].text : payload["cwd"].text
            let tool = payload["tool_name"].text
            let event: String
            switch name {
            case "SessionStart": event = "session_start"
            case "SessionEnd": event = "session_end"
            case "BeforeAgent": event = "prompt"
            case "AfterAgent": event = "stop"
            case "BeforeTool": event = "tool_start"
            case "AfterTool": event = "tool_end"
            case "Notification": event = "notification"
            default: event = explicitEvent.isEmpty ? name.lowercased() : explicitEvent
            }
            return AgentEvent(agent: .gemini, event: event, session: session, cwd: cwd,
                              title: "",
                              message: firstText(payload, event == "prompt" ? ["prompt", "message"] : ["message", "prompt_response", "error"]),
                              tool: tool, pid: nil, timestamp: nil)

        case .opencode, .dsh:
            let event = payload["event"].text.isEmpty ? explicitEvent : payload["event"].text
            let session = payload["session"].text.isEmpty ? payload["sessionID"].text : payload["session"].text
            return AgentEvent(agent: agent, event: event, session: session,
                              cwd: payload["cwd"].text.isEmpty ? payload["directory"].text : payload["cwd"].text,
                              title: payload["title"].text,
                              name: payload["name"].text,
                              message: firstText(payload, ["message", "text", "summary"]),
                              tool: payload["tool"].text, pid: nil, timestamp: payload["timestamp"].float)
        }
    }

    private static let titleEvents: Set<String> = ["session_start", "prompt", "permission_request", "notification", "stop", "error", "tool_failed"]
    // 会话记录可能有几十兆，只读末尾这一段：Claude Code 每轮都会把标题重新写一遍
    private static let transcriptTailBytes = 512 * 1024

    // Claude Code 的会话记录里，用户改过的标题记作 custom-title，自动生成的记作 ai-title
    static func claudeTitle(transcript path: String) -> String {
        guard !path.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        let start = size > UInt64(transcriptTailBytes) ? size - UInt64(transcriptTailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return "" }
        var custom = ""
        var generated = ""
        for line in data.split(separator: 0x0A) {
            // 先按字节筛一遍，绝大多数行是消息，不必逐行解析
            guard line.range(of: Data("-title\"".utf8)) != nil else { continue }
            guard let json = try? JSONValue.parse(Data(line)) else { continue }
            switch json["type"].text {
            case "custom-title":
                let text = json["customTitle"].text
                if !text.isEmpty { custom = text }
            case "ai-title":
                let text = json["aiTitle"].text
                if !text.isEmpty { generated = text }
            default:
                break
            }
        }
        return custom.isEmpty ? generated : custom
    }

    private static func firstText(_ payload: JSONValue, _ keys: [String]) -> String {
        for key in keys {
            let value = payload[key]
            if value.isNull { continue }
            let text = value.text
            if !text.isEmpty { return String(text.prefix(600)) }
        }
        return ""
    }

    // 发送失败直接忽略：助手的命令不能因为应用没启动而报错
    private static func send(_ event: AgentEvent) {
        guard let encoded = try? JSONEncoder().encode(event) else { return }
        var message = encoded
        message.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = HookSocket.path.path(percentEncoded: false)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                _ = strncpy(chars, path, capacity - 1)
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connected == 0 else { return }
        _ = message.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return writeAll(fd: fd, buffer: base, count: buffer.count)
        }
    }

        private static func writeAll(fd: Int32, buffer: UnsafeRawPointer, count: Int) -> Int {
        var written = 0
        while written < count {
            let result = Darwin.write(fd, buffer.advanced(by: written), count - written)
            if result <= 0 { break }
            written += result
        }
        return written
    }
}
