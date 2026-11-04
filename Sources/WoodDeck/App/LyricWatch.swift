import AppKit

// 观察真实播放时收起形态的歌词文字什么时候变、变成什么。
// 换歌时如果文字反复变来变去，界面上就是歌词一闪一闪
enum LyricWatch {
    @MainActor
    static func run(seconds: Double) {
        let model = DeckModel.shared
        model.start()
        let end = Date().addingTimeInterval(seconds)
        var lastText = ""
        var lastTitle = ""
        let start = Date()
        func stamp() -> String {
            String(format: "%.1fs", Date().timeIntervalSince(start))
        }
        while Date() < end {
            let text = model.compactContent().musicText
            let title = model.music.title
            if title != lastTitle {
                lastTitle = title
                log("\(stamp()) 曲目「\(title)」 歌词 0 行")
            }
            if text != lastText {
                lastText = text
                log("\(stamp()) 文字「\(text)」（歌词行 \(model.music.lyrics.count)，当前句「\(model.music.currentLyric)」）")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
