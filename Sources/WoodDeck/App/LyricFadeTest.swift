import AppKit
import SwiftUI

// 自检：换句时应当有一帧同时看得到新旧两句（交叉淡入淡出）；硬切则任一瞬间只有一句
@MainActor
enum LyricFadeTest {
    final class Model: ObservableObject {
        @Published var text = "第一句歌词内容在这里"
    }

    struct Host: View {
        @ObservedObject var model: Model

        var body: some View {
            LyricCrossfadeText(text: model.text,
                               font: .system(size: 13, weight: .medium),
                               color: .white)
                .padding(6)
                .background(Color.black)
        }
    }

    final class PageModel: ObservableObject {
        @Published var display = LyricFadeTest.display(current: "第一句歌词内容在这里", next: "紧接着的第二句")
    }

    struct PageHost: View {
        @ObservedObject var model: PageModel

        var body: some View {
            MusicPageView(music: model.display,
                          showTranslation: false,
                          onCommand: { _ in },
                          onSeek: { _ in },
                          onMode: {})
                .frame(width: 520, height: 200)
                .background(Color.black)
        }
    }

    static func run() async {
        await rowFade()
        await musicPageFade()
        tickerReport()
    }

    // 单句控件
    private static func rowFade() async {
        let model = Model()
        let hosting = NSHostingView(rootView: Host(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 34)
        let window = makeWindow(hosting)
        defer { window.orderOut(nil) }

        try? await Task.sleep(nanoseconds: 400_000_000)
        let before = capture(hosting)
        model.text = "第二句完全不同的另一个句子"
        var samples: [NSBitmapImageRep?] = []
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            samples.append(capture(hosting))
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let after = capture(hosting)
        report(label: "单句", before: before, after: after, samples: samples, box: hosting.bounds)
    }

    // 真实音乐页
    private static func musicPageFade() async {
        let model = PageModel()
        let hosting = NSHostingView(rootView: PageHost(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
        let window = makeWindow(hosting)
        defer { window.orderOut(nil) }

        try? await Task.sleep(nanoseconds: 400_000_000)
        // 先换一次句子，用两帧的像素差异自动找出歌词区域，避开封面与控制条的墨迹
        let first = capture(hosting)
        model.display = display(current: "完全不同的另一句歌词", next: "完全不同的下一句")
        try? await Task.sleep(nanoseconds: 600_000_000)
        let second = capture(hosting)
        guard let box = diffBox(first, second) else {
            print("整页：没有找到变化的区域 ✗")
            return
        }
        print("整页：歌词区域 \(Int(box.width))x\(Int(box.height)) 像素")

        model.display = display(current: "第三句替换后的句子内容", next: "第三句之后的下一句")
        var samples: [NSBitmapImageRep?] = []
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            samples.append(capture(hosting))
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let after = capture(hosting)
        report(label: "整页", before: second, after: after, samples: samples, box: box)
    }

    // 歌词推进节拍与单次开销
    private static func tickerReport() {
        let deck = DeckModel.shared
        deck.fastLyricTicker = false
        let idle = deck.lyricTickInterval
        deck.fastLyricTicker = true
        let fast = deck.lyricTickInterval
        deck.fastLyricTicker = false
        print("歌词推进节拍：常态 \(idle) 秒，展开音乐页 \(fast) 秒 " + (fast < idle ? "✓" : "✗"))

        deck.applyNowPlayingForTest(NowPlaying(bundleIdentifier: "com.apple.Music",
                                               title: "开销测量", artist: "自检", album: "自检",
                                               duration: 240, elapsed: 30, timestamp: Date(), rate: 1,
                                               playing: true, artwork: nil, uniqueIdentifier: "cost",
                                               shuffleMode: nil, repeatMode: nil,
                                               supportsLiked: false, liked: false))
        let lines = stride(from: 0, to: 240, by: 3).map {
            LyricLine(time: Double($0), text: "第 \($0) 秒的歌词行", translation: nil)
        }
        deck.seedLyricsForTest(lines, current: "", next: "")
        let rounds = 2000
        let start = Date()
        for _ in 0..<rounds { deck.updateLyricPositionForTest() }
        let perTick = Date().timeIntervalSince(start) / Double(rounds) * 1_000_000
        print(String(format: "歌词推进一拍 %.1f 微秒（%d 行），20 次/秒合计 %.2f 毫秒/秒",
                     perTick, lines.count, perTick * 20 / 1000))
    }

    // 判定：存在一帧，旧句独占的像素与新句独占的像素同时带墨迹
    private static func report(label: String,
                               before: NSBitmapImageRep?,
                               after: NSBitmapImageRep?,
                               samples: [NSBitmapImageRep?],
                               box: NSRect) {
        guard let before, let after else {
            print("\(label)：取不到画面 ✗")
            return
        }
        let old = luminance(before, box: box)
        let new = luminance(after, box: box)
        guard old.count == new.count, !old.isEmpty else {
            print("\(label)：两帧尺寸不一致 ✗")
            return
        }
        var oldOnly: [Int] = []
        var newOnly: [Int] = []
        for index in 0..<old.count {
            if old[index] > 0.5 && new[index] < 0.05 { oldOnly.append(index) }
            if new[index] > 0.5 && old[index] < 0.05 { newOnly.append(index) }
        }
        guard oldOnly.count > 20, newOnly.count > 20 else {
            print("\(label)：两句没有各自独占的像素位置，无法判定 ✗")
            return
        }
        var pairs: [(Int, Int)] = []
        for sample in samples {
            let frame = luminance(sample, box: box)
            guard frame.count == old.count else { continue }
            let oldCount = oldOnly.reduce(0) { $0 + (frame[$1] > 0.15 ? 1 : 0) }
            let newCount = newOnly.reduce(0) { $0 + (frame[$1] > 0.15 ? 1 : 0) }
            pairs.append((oldCount, newCount))
        }
        print("\(label)：旧句独占 \(oldOnly.count) 像素，新句独占 \(newOnly.count) 像素")
        print("\(label)：每 30 毫秒（旧,新）= "
              + pairs.map { "(\($0.0),\($0.1))" }.joined(separator: " "))
        let oldFloor = oldOnly.count / 100
        let newFloor = newOnly.count / 100
        let both = pairs.contains { $0.0 > oldFloor && $0.1 > newFloor }
        print(both
              ? "\(label)：有一帧同时看得到新旧两句 → 交叉淡入淡出 ✓"
              : "\(label)：从未同时出现 → 仍是硬切 ✗")
    }

    private static func makeWindow(_ hosting: NSView) -> NSWindow {
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = hosting
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.orderFrontRegardless()
        return window
    }

    private static func capture(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    // 区域内逐像素的红色分量，按行优先展平
    private static func luminance(_ rep: NSBitmapImageRep?, box: NSRect) -> [Double] {
        guard let rep else { return [] }
        var values: [Double] = []
        let maxY = min(Int(box.maxY), rep.pixelsHigh)
        let maxX = min(Int(box.maxX), rep.pixelsWide)
        var y = max(0, Int(box.minY))
        while y < maxY {
            var x = max(0, Int(box.minX))
            while x < maxX {
                let red = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0
                values.append(Double(red))
                x += 1
            }
            y += 1
        }
        return values
    }

    // 两帧之间发生变化的像素范围
    private static func diffBox(_ lhs: NSBitmapImageRep?, _ rhs: NSBitmapImageRep?) -> NSRect? {
        guard let lhs, let rhs, lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else {
            return nil
        }
        var minX = lhs.pixelsWide
        var maxX = -1
        var minY = lhs.pixelsHigh
        var maxY = -1
        var y = 0
        while y < lhs.pixelsHigh {
            var x = 0
            while x < lhs.pixelsWide {
                let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                if let a, let b, abs(a.redComponent - b.redComponent) > 0.08 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
                x += 1
            }
            y += 1
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    nonisolated static func display(current: String, next: String) -> MusicDisplay {
        var display = MusicDisplay(available: true)
        display.title = "自检曲目"
        display.artist = "自检歌手"
        display.album = "自检专辑"
        display.duration = 240
        display.position = 30
        // 位置固定不动，进度条就不会在采样期间变化，像素差异只来自歌词
        display.playing = false
        display.lyrics = [LyricLine(time: -30, text: current, translation: nil),
                          LyricLine(time: 60, text: next, translation: nil)]
        display.currentLyric = current
        display.nextLyric = next
        return display
    }
}
