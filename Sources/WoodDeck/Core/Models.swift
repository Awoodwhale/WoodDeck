import Foundation

enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, cursor, antigravity, grokBot, zcode, dsh
    case glmChina, glmGlobal, deepSeek, newAPI, sub2API, custom

    var id: String { rawValue }

    // 自动读取的来源从本机应用取得数据，其余需要填写站点或密钥
    var isAutomatic: Bool {
        switch self {
        case .claude, .codex, .cursor, .antigravity, .grokBot, .zcode, .dsh: true
        case .glmChina, .glmGlobal, .deepSeek, .newAPI, .sub2API, .custom: false
        }
    }

    // 提供本地 Token 用量统计的来源
    var isUsageSource: Bool {
        switch self {
        case .claude, .codex, .cursor, .antigravity, .zcode, .dsh: true
        case .grokBot, .glmChina, .glmGlobal, .deepSeek, .newAPI, .sub2API, .custom: false
        }
    }

    var needsSite: Bool {
        switch self {
        case .newAPI, .sub2API, .custom: true
        default: false
        }
    }

    var needsSecret: Bool {
        switch self {
        case .glmChina, .glmGlobal, .deepSeek, .newAPI, .sub2API, .custom: true
        default: false
        }
    }

    // Claude 与 Grok Bot 的每一行可以单独关闭联网读取
    var hasOnlineSwitch: Bool { self == .claude || self == .grokBot }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        case .grokBot: "Grok Bot"
        case .zcode: "ZCode"
        case .dsh: "DeepSeek Harness"
        case .glmChina: "智谱 GLM"
        case .glmGlobal: "Z.ai GLM"
        case .deepSeek: "DeepSeek"
        case .newAPI: "New API"
        case .sub2API: "Sub2API"
        case .custom: "自定义"
        }
    }

    var usageTip: String {
        switch self {
        case .claude: "Claude Code + Claude 桌面版"
        case .codex: "Codex 桌面版 + Codex CLI"
        case .antigravity: "Antigravity 桌面版 + Antigravity CLI"
        case .zcode: "ZCode 桌面应用"
        case .dsh: "DeepSeek Harness 桌面版 + 本地 Web 版"
        case .cursor: "Cursor 账户用量，包含其他设备"
        default: displayName
        }
    }

    var quotaDescription: String {
        switch self {
        case .antigravity: "额度读取自 Antigravity 桌面版，需要桌面版正在运行"
        case .dsh: "DeepSeek Harness 登录的 DeepSeek 账户余额；未登录账户时使用其中保存的 API 密钥"
        case .grokBot: "只显示 Grok Bot 桌面版登录账户的每周额度"
        default: ""
        }
    }

    // 默认调色板，与上游按工具区分的主题色一致
    var defaultColor: String {
        switch self {
        case .claude: "#D97757"
        case .codex: "#10A37F"
        case .cursor: "#6C7BFF"
        case .antigravity: "#4A9EFF"
        case .grokBot: "#8A8F98"
        case .zcode: "#7C5CFF"
        case .dsh: "#4D6BFE"
        case .glmChina: "#2F6BFF"
        case .glmGlobal: "#5B4BFF"
        case .deepSeek: "#4D6BFE"
        case .newAPI: "#00A6A6"
        case .sub2API: "#FF7A45"
        case .custom: "#8E8E93"
        }
    }

    static var automaticSources: [ProviderID] {
        [.claude, .codex, .antigravity, .cursor, .grokBot, .zcode, .dsh]
    }

    static var builtIns: [ProviderID] { [.claude, .codex, .antigravity, .cursor, .dsh] }

    static var usageSources: [ProviderID] { [.claude, .codex, .antigravity, .cursor, .zcode, .dsh] }
}

enum MetricKind: String, Codable, Sendable {
    case percent, balance, spend, count, text
}

struct UsageMetric: Codable, Identifiable, Sendable, Hashable {
    var kind: MetricKind
    var label: String
    var metricID: String = ""
    var window: Int?
    var percent: Double?
    var amount: Decimal?
    var total: Decimal?
    var used: Decimal?
    var currency: String = ""
    var unit: String = ""
    var unlimited: Bool = false
    var resetAt: Date?
    var expiresAt: Date?
    var atLeast: Bool = false
    var value: String = ""
    var suffix: String = ""
    var note: String = ""
    var resetText: String = ""

    var id: String { metricID.isEmpty ? label : metricID }

    // 进度条长度所用的已用比例，余额与次数指标按各自规则换算
    var usedPercent: Double? {
        switch kind {
        case .percent, .text:
            return percent
        case .balance:
            if let total, total > 0, let amount { return Double(truncating: ((total - amount) / total * 100) as NSDecimalNumber) }
            if (total ?? 0) == 0, let amount, amount <= 0 { return 100 }
            return nil
        case .count:
            if let total, total > 0, let used { return Double(truncating: (used / total * 100) as NSDecimalNumber) }
            return nil
        case .spend:
            return nil
        }
    }

    var valueText: String {
        switch kind {
        case .text:
            return value
        case .balance, .spend:
            guard let amount else { return "—" }
            return (atLeast ? "≥" : "") + UsageMetric.money(amount, currency: currency)
        case .count:
            guard let used, let total else { return "—" }
            return "\(UsageMetric.grouped(used)) / \(UsageMetric.grouped(total))"
        case .percent:
            guard let usedPercent else { return "—" }
            return String(format: "%.1f%%", usedPercent)
        }
    }

    var valueSuffix: String {
        switch kind {
        case .text: return value.isEmpty ? "" : suffix
        case .balance: return "可用"
        case .spend: return "已用"
        case .count: return unit
        case .percent: return "已用"
        }
    }

    static func money(_ amount: Decimal, currency: String) -> String {
        let symbol: String
        switch currency {
        case "USD": symbol = "$"
        case "CNY", "RMB": symbol = "¥"
        case "": symbol = ""
        default: symbol = currency + " "
        }
        let negative = amount < 0
        var value = abs(amount)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return (negative ? "−" : "") + symbol + NSDecimalNumber(decimal: rounded).stringValue
    }

    static func grouped(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
    }
}

struct Quota: Codable, Sendable, Hashable {
    var label: String
    var usedPercent: Double?
    var resetAt: Date?
    var windowMinutes: Int?

    var metric: UsageMetric {
        UsageMetric(kind: .percent, label: label, metricID: label, window: windowMinutes,
                    percent: usedPercent, resetAt: resetAt)
    }
}

struct ProviderResult: Sendable {
    var metrics: [UsageMetric]
    var plan: String = ""
    var planSource: String = ""
    var scope: String = ""
    var details: [String: String] = [:]
    var warnings: [String] = []
}

struct ProviderSnapshot: Sendable {
    var id: ProviderID
    var quotas: [Quota] = []
    var metrics: [UsageMetric] = []
    var plan: String = ""
    var planSource: String = ""
    var statusLabel: String = ""
    var status: String = ""
    var usageNote: String = ""
    var usageAvailable: Bool = false
    var usageComplete: Bool = true
    var entries: [TokenEntry] = []
    var usageStart: Date = Date()
    var fetchedAt: Date = Date()
    // 只来自本机记录的额度快照，供关闭联网的行使用
    var localOnly: Bool = false

    var connected: Bool { !quotas.isEmpty || !metrics.isEmpty }
}

struct TokenEntry: Codable, Sendable, Hashable {
    var key: String
    var time: Date
    var model: String
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var cost: Decimal?

    var total: Int { input + output + cacheRead + cacheWrite }
}

enum ProviderError: LocalizedError {
    case notConnected(String)
    case readFailed(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let text), .readFailed(let text), .message(let text): text
        }
    }

    var label: String {
        switch self {
        case .notConnected: "未连接"
        case .readFailed: "读取失败"
        case .message: "读取失败"
        }
    }
}

struct ProviderContext: Sendable {
    var now: Date = Date()
    var site: String = ""
    var secret: String = ""
    var script: String = ""
    var language: String = "zh-CN"
}

// 一行歌词：时间与文本，翻译可选
struct LyricLine: Sendable, Equatable, Hashable {
    var time: Double
    var text: String
    var translation: String?
}

// 系统媒体控制的命令编号，与 MediaRemote 的取值一致
enum MediaCommand: Int, Sendable {
    case play = 0
    case pause = 1
    case toggle = 2
    case stop = 3
    case next = 4
    case previous = 5
    // 喜欢/取消喜欢：只有播放器报告支持时才发送
    case like = 6
}
