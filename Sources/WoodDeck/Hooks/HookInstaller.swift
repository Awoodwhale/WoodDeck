import Foundation

// 各助手的事件接入：Claude Code 与 Gemini CLI 用 hooks 命令，Codex 用 notify，opencode 用插件，
// DeepSeek Harness 没有命令式 hook，改为观察它的会话记录
enum HookInstaller {
    static var executablePath: String {
        if let path = Bundle.main.executablePath { return path }
        return CommandLine.arguments.first ?? "/Applications/WoodDeck.app/Contents/MacOS/WoodDeck"
    }

    static let pluginFileName = "wooddeck.ts"

    static func isInstalled(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claude: return hookInstalled(in: claudeSettings, agent: .claude)
        case .gemini: return hookInstalled(in: geminiSettings, agent: .gemini)
        case .codex: return codexNotifyInstalled()
        case .opencode: return FileManager.default.fileExists(atPath: opencodePlugin.path(percentEncoded: false))
        case .dsh: return false
        }
    }

    static func install(_ agent: AgentKind) {
        switch agent {
        case .claude: installHooks(at: claudeSettings, agent: .claude, events: claudeEvents)
        case .gemini: installHooks(at: geminiSettings, agent: .gemini, events: geminiEvents)
        case .codex: installCodexNotify()
        case .opencode: installOpencodePlugin()
        case .dsh: break
        }
    }

    static func uninstall(_ agent: AgentKind) {
        switch agent {
        case .claude: removeHooks(at: claudeSettings, agent: .claude)
        case .gemini: removeHooks(at: geminiSettings, agent: .gemini)
        case .codex: removeCodexNotify()
        case .opencode: try? FileManager.default.removeItem(at: opencodePlugin)
        case .dsh: break
        }
    }

    // MARK: - 配置位置

    static var claudeSettings: URL {
        DataLocations.detect().claudeHome.appending(path: "settings.json")
    }

    static var geminiSettings: URL {
        DataLocations.detect().home.appending(path: ".gemini/settings.json")
    }

    static var codexConfig: URL {
        DataLocations.detect().codexHome.appending(path: "config.toml")
    }

    static var opencodePlugin: URL {
        DataLocations.detect().home.appending(path: ".config/opencode/plugin/\(pluginFileName)")
    }

    private static var hookCommandSuffix: String { "--hook" }

    // MARK: - Claude Code 与 Gemini CLI 共用的事件表

    private struct HookEventSpec {
        var event: String
        var matcher: String?
    }

    private static var claudeEvents: [HookEventSpec] {
        [
            HookEventSpec(event: "SessionStart", matcher: nil),
            HookEventSpec(event: "SessionEnd", matcher: nil),
            HookEventSpec(event: "UserPromptSubmit", matcher: nil),
            HookEventSpec(event: "PreToolUse", matcher: "*"),
            HookEventSpec(event: "PostToolUse", matcher: "*"),
            HookEventSpec(event: "PostToolUseFailure", matcher: "*"),
            HookEventSpec(event: "PermissionRequest", matcher: "*"),
            // 用户在 Claude Code 里拒绝审批时收回岛上的审批提示
            HookEventSpec(event: "PermissionDenied", matcher: "*"),
            HookEventSpec(event: "Notification", matcher: "*"),
            HookEventSpec(event: "Stop", matcher: nil),
            HookEventSpec(event: "SubagentStop", matcher: nil)
        ]
    }

    private static var geminiEvents: [HookEventSpec] {
        [
            HookEventSpec(event: "SessionStart", matcher: nil),
            HookEventSpec(event: "SessionEnd", matcher: nil),
            HookEventSpec(event: "BeforeAgent", matcher: nil),
            HookEventSpec(event: "AfterAgent", matcher: nil),
            HookEventSpec(event: "BeforeTool", matcher: "*"),
            HookEventSpec(event: "AfterTool", matcher: "*"),
            HookEventSpec(event: "Notification", matcher: "*")
        ]
    }

    private static func command(for agent: AgentKind) -> String {
        // 路径可能包含空格，写进配置时要加引号
        "\"\(executablePath)\" \(hookCommandSuffix) \(agent.rawValue)"
    }

    private static func installHooks(at url: URL, agent: AgentKind, events: [HookEventSpec]) {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // 先清掉旧版本注册的条目，避免重复
        hooks = cleaning(hooks, agent: agent)

        for spec in events {
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command(for: agent)]]]
            if let matcher = spec.matcher { entry["matcher"] = matcher }
            var list = hooks[spec.event] as? [[String: Any]] ?? []
            list.append(entry)
            hooks[spec.event] = list
        }
        root["hooks"] = hooks
        write(root, to: url)
    }

    private static func removeHooks(at url: URL, agent: AgentKind) {
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return }
        let cleaned = cleaning(hooks, agent: agent)
        if cleaned.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = cleaned
        }
        write(root, to: url)
    }

    private static func cleaning(_ hooks: [String: Any], agent: AgentKind) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept = entries.compactMap { entry -> [String: Any]? in
                guard var inner = entry["hooks"] as? [[String: Any]] else { return entry }
                inner.removeAll { hook in
                    let command = hook["command"] as? String ?? ""
                    return command.contains("\(hookCommandSuffix) \(agent.rawValue)")
                }
                if inner.isEmpty { return nil }
                var updated = entry
                updated["hooks"] = inner
                return updated
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func hookInstalled(in url: URL, agent: AgentKind) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                guard let inner = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in inner {
                    let command = hook["command"] as? String ?? ""
                    if command.contains("\(hookCommandSuffix) \(agent.rawValue)") { return true }
                }
            }
        }
        return false
    }

    private static func write(_ root: [String: Any], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            SupportFiles.writeCrash("写入 \(url.lastPathComponent) 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Codex 的 notify

    private static func codexNotifyLine() -> String {
        "notify = [\"\(executablePath)\", \"\(hookCommandSuffix)\", \"codex\"]"
    }

    private static func codexNotifyInstalled() -> Bool {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return false }
        return text.contains("\"\(hookCommandSuffix)\", \"codex\"")
    }

    private static func installCodexNotify() {
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        text = removingCodexNotify(from: text)
        let line = codexNotifyLine()
        if text.isEmpty {
            text = line + "\n"
        } else {
            text = line + "\n" + text
        }
        writeText(text, to: codexConfig)
    }

    private static func removeCodexNotify() {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return }
        writeText(removingCodexNotify(from: text), to: codexConfig)
    }

    private static func removingCodexNotify(from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("\"\(hookCommandSuffix)\", \"codex\"") }
            .joined(separator: "\n")
    }

    private static func writeText(_ text: String, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            SupportFiles.writeCrash("写入 \(url.lastPathComponent) 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - opencode 插件

    private static func installOpencodePlugin() {
        let source = opencodePluginSource
        do {
            try FileManager.default.createDirectory(at: opencodePlugin.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: opencodePlugin, atomically: true, encoding: .utf8)
        } catch {
            SupportFiles.writeCrash("写入 opencode 插件失败：\(error.localizedDescription)")
        }
    }

    // 插件把事件通过标准输入交给 WoodDeck 的命令行入口
    private static var opencodePluginSource: String {
        """
        // WoodDeck 会话通知插件：把 opencode 的事件转给 WoodDeck
        const BINARY = "\(executablePath)"

        function send(payload: Record<string, unknown>) {
          try {
            const proc = Bun.spawn([BINARY, "--hook", "opencode"], {
              stdin: new Blob([JSON.stringify(payload)]),
              stdout: "ignore",
              stderr: "ignore",
            })
            proc.unref()
          } catch {
            // WoodDeck 未安装或已退出时忽略
          }
        }

        export const WoodDeckPlugin = async ({ directory }: { directory: string }) => {
          // 会话 id -> 会话标题，让每条事件都带上会话名称
          const titles = new Map<string, string>()
          return {
            event: async ({ event }: { event: { type: string; properties?: Record<string, any> } }) => {
              const properties = event.properties ?? {}
              // message.updated 的 info 是消息，会话 id 在 info.sessionID；session.* 的 info 是会话本身
              const session = String(properties.sessionID ?? properties.info?.sessionID ?? properties.info?.id ?? "")
              if (event.type.startsWith("session.") && typeof properties.info?.title === "string" && properties.info.title !== "") {
                titles.set(session, properties.info.title)
              }
              const base = {
                cwd: directory,
                session,
                name: titles.get(session) ?? "",
                message: String(properties.part?.text ?? ""),
                title: "",
                tool: String(properties.part?.tool ?? properties.tool ?? ""),
              }
              switch (event.type) {
                case "session.created":
                  send({ ...base, event: "session_start" })
                  break
                case "session.updated":
                  send({ ...base, event: "title" })
                  break
                case "message.updated":
                  send({ ...base, event: "prompt" })
                  break
                case "tool.execute.before":
                case "tool.execute.after":
                  send({ ...base, event: event.type === "tool.execute.before" ? "tool_start" : "tool_end" })
                  break
                case "permission.asked":
                  send({ ...base, event: "permission_request", tool: String(properties.permission ?? base.tool) })
                  break
                case "permission.replied":
                  // 用户在 opencode 里答复审批之后，岛上的审批提示随之收起
                  send({ ...base, event: "permission_resolved", message: String(properties.reply ?? "") })
                  break
                case "session.error":
                  send({ ...base, event: "error", message: String(properties.error?.data?.message ?? properties.error?.name ?? "") })
                  break
                case "session.idle":
                  send({ ...base, event: "stop" })
                  break
                case "session.deleted":
                  titles.delete(session)
                  send({ ...base, event: "session_end" })
                  break
                default:
                  break
              }
            },
          }
        }
        """
    }
}
