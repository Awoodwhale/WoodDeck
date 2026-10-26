import Foundation

// 播放模式：与 BrimDeck 一致的四态——列表循环、单曲循环、随机播放、顺序播放。
// 各播放器报告的能力不同，只在这个集合里循环
enum PlaybackMode: String, CaseIterable {
    case repeatAll
    case repeatOne
    case shuffle
    case inOrder

    var label: String {
        switch self {
        case .repeatAll: Loc.t("列表循环", "Repeat all")
        case .repeatOne: Loc.t("单曲循环", "Repeat one")
        case .shuffle: Loc.t("随机播放", "Shuffle")
        case .inOrder: Loc.t("顺序播放", "In order")
        }
    }

    var symbol: String {
        switch self {
        case .repeatAll: "repeat"
        case .repeatOne: "repeat.1"
        case .shuffle: "shuffle"
        case .inOrder: "arrow.right"
        }
    }

    // 对应到系统的循环模式编号，媒体控制用 1 列表 / 2 单曲 / 3 顺序
    var repeatMode: Int {
        switch self {
        case .repeatAll: 1
        case .repeatOne: 2
        case .inOrder: 3
        case .shuffle: 1
        }
    }

    static func current(shuffle: Bool, repeatMode: Int) -> PlaybackMode {
        if shuffle { return .shuffle }
        switch repeatMode {
        case 2: return .repeatOne
        case 3: return .inOrder
        default: return .repeatAll
        }
    }

    static func available(canShuffle: Bool, canRepeat: Bool) -> [PlaybackMode] {
        if !canShuffle && !canRepeat { return [] }
        if !canShuffle { return [.repeatAll, .repeatOne, .inOrder] }
        if !canRepeat { return [.shuffle] }
        return [.repeatAll, .repeatOne, .shuffle, .inOrder]
    }

    static func next(after current: PlaybackMode, in modes: [PlaybackMode]) -> PlaybackMode {
        guard !modes.isEmpty else { return current }
        guard let index = modes.firstIndex(of: current) else { return modes[0] }
        return modes[(index + 1) % modes.count]
    }
}
