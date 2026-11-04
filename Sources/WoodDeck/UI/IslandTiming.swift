import Foundation

// 面板里换内容时共用的节奏
enum IslandTiming {
    // 一段内容淡出、另一段内容淡入的时长，两段同时进行
    static let crossFade: Double = 0.26
    // 换歌时封面与曲名更换的时长，比歌词稍长一点，看起来不抢
    static let coverFade: Double = 0.34
}
