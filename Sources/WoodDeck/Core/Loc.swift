import Foundation

// 界面语言。中文与英文各一条，默认跟随系统
enum Language: String, Codable, CaseIterable, Identifiable {
    case system, chinese = "zh-CN", english = "en-US"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: Loc.t("跟随系统", "Follow system")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }

    var resolved: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? "zh-CN" : "en-US"
        case .chinese: return "zh-CN"
        case .english: return "en-US"
        }
    }
}

enum Loc {
    nonisolated(unsafe) static var language: String = Language.system.resolved

    static var isChinese: Bool { language == "zh-CN" }

    static func t(_ chinese: String, _ english: String) -> String {
        isChinese ? chinese : english
    }

    static func count(_ number: Int, _ chineseUnit: String) -> String {
        isChinese ? "\(number) \(chineseUnit)" : "\(number) \(chineseUnit)\(number == 1 ? "" : "s")"
    }

    // 相对时间，用于重置倒计时
    static func remaining(until date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return t("即将重置", "Resetting now") }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if isChinese {
            if days > 0 { return hours > 0 ? "\(days) 天 \(hours) 时后" : "\(days) 天后" }
            if hours > 0 { return minutes > 0 ? "\(hours) 时 \(minutes) 分后" : "\(hours) 时后" }
            return "\(max(1, minutes)) 分后"
        } else {
            if days > 0 { return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d" }
            if hours > 0 { return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h" }
            return "in \(max(1, minutes))m"
        }
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return t("刚刚", "just now") }
        if seconds < 3600 { return t("\(seconds / 60) 分钟前", "\(seconds / 60) min ago") }
        if seconds < 86400 { return t("\(seconds / 3600) 小时前", "\(seconds / 3600) h ago") }
        return t("\(seconds / 86400) 天前", "\(seconds / 86400) d ago")
    }
}
