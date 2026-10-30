import Foundation
import SwiftUI

// 支持通知的编程助手
enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, gemini, opencode, dsh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .opencode: "opencode"
        case .dsh: "DeepSeek Harness"
        }
    }

    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .opencode: "opencode"
        case .dsh: "DSH"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .gemini: "sparkle"
        case .opencode: "terminal"
        case .dsh: "waveform.path"
        }
    }

    var accent: Color {
        switch self {
        case .claude: Theme.color("#E5A385")
        case .codex: Theme.color("#98DBB0")
        case .gemini: Theme.color("#9CB9FF")
        case .opencode: Theme.color("#D4D5DF")
        case .dsh: Theme.color("#6081DA")
        }
    }

    // 接入方式：hook 命令或会话记录观察
    var mechanism: String {
        switch self {
        case .claude: Loc.t("Claude Code 的 hooks 命令", "Claude Code hook commands")
        case .codex: Loc.t("Codex 的 notify 程序", "The Codex notify program")
        case .gemini: Loc.t("Gemini CLI 的 hooks 配置", "Gemini CLI hook settings")
        case .opencode: Loc.t("opencode 插件", "An opencode plugin")
        case .dsh: Loc.t("会话记录观察", "Watching session records")
        }
    }
}

// 会话当前的状态
enum SessionStatus: String, Codable, Sendable {
    case working
    case waitingPermission
    case waitingInput
    case done
    case error
    case idle

    var label: String {
        switch self {
        case .working: Loc.t("处理中", "Working")
        case .waitingPermission: Loc.t("等待授权", "Needs permission")
        case .waitingInput: Loc.t("等待输入", "Waiting for you")
        case .done: Loc.t("已完成", "Finished")
        case .error: Loc.t("出错", "Error")
        case .idle: Loc.t("空闲", "Idle")
        }
    }

    // 需要用户注意的状态
    var needsAttention: Bool {
        self == .waitingPermission || self == .waitingInput || self == .error
    }

    var color: Color {
        switch self {
        case .working: Theme.color("#7FD1C4")
        case .waitingPermission: Theme.color("#E5C890")
        case .waitingInput: Theme.color("#9CB9FF")
        case .done: Theme.color("#98DBB0")
        case .error: Theme.color("#E78284")
        case .idle: Color.white.opacity(0.4)
        }
    }

    var priority: Int {
        switch self {
        case .waitingPermission: 4
        case .waitingInput: 3
        case .error: 2
        case .working: 1
        case .done: 0
        case .idle: 0
        }
    }
}

// 一个正在运行的助手会话
struct AgentSession: Identifiable, Codable, Sendable {
    var id: String
    var agent: AgentKind
    var project: String
    var cwd: String
    var title: String
    // 会话名称：助手自己给出的标题，没有标题时用第一句提问
    var name: String = ""
    // name 来自助手给出的标题时为 true，之后不再被提问文本覆盖
    var nameIsTitle: Bool = false
    var message: String
    var tool: String
    var status: SessionStatus
    var startedAt: Date
    var updatedAt: Date
    var eventCount: Int

    var projectName: String {
        let trimmed = project.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        let path = cwd.isEmpty ? "" : cwd
        return path.isEmpty ? Loc.t("未知项目", "Unknown project") : (path as NSString).lastPathComponent
    }

    // 区分同一项目里多个会话用的名称；拿不到名称时退回项目名
    var displayName: String {
        name.isEmpty ? projectName : name
    }

    // 「项目 · 会话名」，名称缺失时只有项目名
    var fullName: String {
        name.isEmpty ? projectName : "\(projectName) · \(name)"
    }

    var ageText: String {
        Loc.ago(updatedAt)
    }
}

// 助手推送过来的原始事件
struct AgentEvent: Codable, Sendable {
    var agent: AgentKind
    var event: String
    var session: String
    var cwd: String
    var title: String
    // 会话名称（助手给出的会话标题），没有时为空
    var name: String = ""
    var message: String
    var tool: String
    var pid: Int?
    var timestamp: Double?

    var date: Date {
        if let timestamp, timestamp > 0 {
            return Date(timeIntervalSince1970: timestamp > 100_000_000_000 ? timestamp / 1000 : timestamp)
        }
        return Date()
    }
}
