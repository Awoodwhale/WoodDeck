import Foundation
import SwiftUI

// 界面使用的派生数据，与数据来源解耦
struct AppColumn: Identifiable {
    var id: UUID
    var entry: AppEntry
    var name: String
    var quotas: [Quota]
    var metrics: [UsageMetric]
    var plan: String
    var planSource: String
    var statusLabel: String
    var status: String
    var connected: Bool
    // 今日与最近七日的 Token 用量与费用
    var todayTokens: Int = 0
    var todayCost: Decimal?
    var weekTokens: Int = 0
    var weekCost: Decimal?
    var usageNote: String = ""
    var usageAvailable: Bool = false
}

struct MusicDisplay {
    var available: Bool = false
    var playing: Bool = false
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var artwork: Data?
    var duration: Double = 0
    var position: Double = 0
    // 位置对应的时刻，用于插值
    var positionStamp: Date = Date()
    var canToggle: Bool = false
    var canPrevious: Bool = false
    var canNext: Bool = false
    var canSeek: Bool = false
    var canShuffle: Bool = false
    var canRepeat: Bool = false
    var shuffle: Bool = false
    var repeatMode: Int = 1
    var sourceName: String = ""
    var lyrics: [LyricLine] = []
    var currentLyric: String = ""
    var currentTranslation: String = ""
    var nextLyric: String = ""
    var previousLyric: String = ""
    // 喜欢状态：只有既能读出也能修改的播放器才可用
    var canLike: Bool = false
    var liked: Bool = false

    // 播放模式是否可切换：播放器至少要报告随机或循环之一
    var canChangeMode: Bool { canShuffle || canRepeat }

    var caption: String {
        artist.isEmpty ? title : "\(title) · \(artist)"
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    // 按发布时刻插值出当前位置，供进度条平滑显示
    func livePosition(at now: Date = Date()) -> Double {
        guard playing else { return position }
        let advance = max(0, now.timeIntervalSince(positionStamp))
        return min(max(position + advance, 0), duration > 0 ? duration : position + advance)
    }

    func liveProgress(at now: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(livePosition(at: now) / duration, 0), 1)
    }

    var hasTrack: Bool { !title.isEmpty }
}

// 收起形态需要显示的内容
struct CompactContent {
    var style: CompactStyle
    var rings: [(percent: Double, color: Color)]
    var clock: String
    var musicText: String
    var equalizer: Bool
    var playing: Bool
    var artwork: Data?
    // 从封面提取的主色，用于律动条与进度条着色；封面取色关闭时为空
    var coverTint: Color?
    var alertText: String?
    var alertColor: Color
    var lineProgress: Double?
    var scale: Double
    var clockColor: Color
    var clockStyle: ClockStyle
    // 需要关注的助手会话
    // 有刘海时内容要下移，让开摄像头区域
    var contentTopPadding: CGFloat = 0
    // 分列刘海两侧时每侧的宽度与中间让开的宽度，为 0 表示不使用分列
    var splitLeft: CGFloat = 0
    var splitRight: CGFloat = 0
    var splitNotch: CGFloat = 0
    // 两个角标：左侧音乐、右侧 AI
    var leftTag: String?
    var rightTag: String?
    var sessionBadge: Int = 0
    var sessionAgent: AgentKind?
    var sessionSymbol: String?
    // 收起形态的系统读数：CPU 与内存占用，以及网络速率文本
    var monitorCpu: Double?
    var monitorMemory: Double?
    var monitorNetwork: String?
    // 面板正在变尺寸
    var animating: Bool = false
}

enum TimeFormatting {
    static func clock(_ date: Date, hour24: Bool, style: ClockStyle) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Loc.isChinese ? "zh_CN" : "en_US")
        switch style {
        case .stacked:
            formatter.dateFormat = hour24 ? "HH\nmm" : "hh\nmm"
        case .dots:
            // 用间隔点代替冒号
            formatter.dateFormat = hour24 ? "HH·mm" : "h·mm"
        case .segment:
            // 用竖线分隔时分
            formatter.dateFormat = hour24 ? "HH|mm" : "h|mm"
        case .minimal, .serif, .wide, .condensed, .neon, .digits:
            formatter.dateFormat = hour24 ? "HH:mm" : "h:mm"
        }
        return formatter.string(from: date)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // 缩写数字：千用 K、百万用 M、十亿用 B，小数位按量级取一到两位并去掉末尾的零
    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return scaled(Double(count) / 1_000, decimals: 1) + "K"
        case ..<1_000_000_000: return scaled(Double(count) / 1_000_000, decimals: 2) + "M"
        default: return scaled(Double(count) / 1_000_000_000, decimals: 2) + "B"
        }
    }

    // 完整的数字，带千位分隔，用在提示与合计
    static func exactTokens(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private static func scaled(_ value: Double, decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
