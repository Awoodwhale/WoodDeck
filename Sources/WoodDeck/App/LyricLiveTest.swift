import AppKit
import SwiftUI

// 用真实播放数据走一遍「切歌 → 查到歌词 → 上屏」，判定三件事：
// 收起形态的文字层是否被复用、换字是否走了淡出淡入、展开面板的歌词区是否自己换上新词
@MainActor
enum LyricLiveTest {
    private static let canvas = CGSize(width: 479, height: 32)
    private static let slot = NSRect(x: 44, y: 6, width: 196, height: 20)
    private static let expandedCanvas = CGSize(width: 520, height: 200)
    private static let expandedLyrics = NSRect(x: 96, y: 40, width: 300, height: 120)

    static func run() {
        let model = DeckModel.shared
        guard let window = makeWindow(size: canvas, offset: 20) else {
            print("无法建立渲染窗口")
            return
        }
        let box = LiveBox(model: model)
        let probe = LiveProbe(box: box)
            .frame(width: canvas.width, height: canvas.height)
        let host = NSHostingView(rootView: probe)
        host.frame = NSRect(origin: .zero, size: canvas)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        guard let musicWindow = makeWindow(size: expandedCanvas, offset: 120) else { return }
        let musicHost = NSHostingView(rootView: MusicProbe(model: model)
            .frame(width: expandedCanvas.width, height: expandedCanvas.height))
        musicHost.frame = NSRect(origin: .zero, size: expandedCanvas)
        musicWindow.contentView = musicHost
        musicHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let first = track(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269, key: "live-a")
        let second = track(title: "七里香", artist: "周杰伦", album: "七里香", duration: 299, key: "live-b")

        feed(first, model: model, window: window, musicWindow: musicWindow, name: "第一首 晴天")
        feedEmpty(model: model, window: window, name: "切歌前先来一条空报文")
        feed(second, model: model, window: window, musicWindow: musicWindow, name: "切到第二首 七里香")
        window.orderOut(nil)
        musicWindow.orderOut(nil)
    }

    // 切歌时系统会先给一条没有曲名的报文，这段时间岛上的文字不能变成空白
    private static func feedEmpty(model: DeckModel, window: NSWindow, name: String) {
        model.applyNowPlayingForTest(nil)
        var blanks = 0
        var samples = 0
        let started = Date()
        while Date().timeIntervalSince(started) < 0.42 {
            samples += 1
            if model.compactContent().musicText.isEmpty { blanks += 1 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        print("— \(name) —")
        print("  \(samples) 个采样里文字为空的有 \(blanks) 个\(blanks == 0 ? " ✓ 没有闪成空白" : " ✗ 文字被清空了")")
    }

    private static func track(title: String, artist: String, album: String, duration: Double,
                              key: String) -> NowPlaying {
        NowPlaying(bundleIdentifier: "com.netease.163music", title: title, artist: artist, album: album,
                   duration: duration, elapsed: 60, timestamp: Date(), rate: 1, playing: true,
                   artwork: nil, uniqueIdentifier: key, shuffleMode: nil, repeatMode: nil,
                   supportsLiked: false, liked: false)
    }

    // 喂一条新曲目，然后每 40 毫秒采一次画面，直到歌词上屏或超时
    private static func feed(_ update: NowPlaying, model: DeckModel, window: NSWindow,
                             musicWindow: NSWindow, name: String) {
        let madeBefore = MarqueeLayerView.makeCount
        model.applyNowPlayingForTest(update)
        let expandedBefore = ink(in: musicWindow, rect: expandedLyrics)
        let deadline = Date().addingTimeInterval(8)
        var samples: [(at: Double, text: String, brightness: Double)] = []
        var swapSamples: [(first: Double, second: Double, ghosts: Double)] = []
        let layer = findMarquee(in: window)
        let started = Date()
        while Date() < deadline {
            let text = model.music.currentLyric
            let brightness = self.brightness(in: window)
            samples.append((Date().timeIntervalSince(started), text, brightness))
            if let layer {
                let alphas = layer.presentedAlphas()
                swapSamples.append((alphas.first, alphas.second, layer.presentedGhostAlphas().reduce(0, +)))
            }
            if !text.isEmpty, samples.count > 3, let last = samples.suffix(3).first, !last.text.isEmpty,
               abs(last.at - Date().timeIntervalSince(started)) < 0.2 {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        // 歌词上屏后再多采一段，看稳定性
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            samples.append((Date().timeIntervalSince(started), model.music.currentLyric,
                            brightness(in: window)))
            if let layer {
                let alphas = layer.presentedAlphas()
                swapSamples.append((alphas.first, alphas.second, layer.presentedGhostAlphas().reduce(0, +)))
            }
        }
        let visible = samples.filter { !$0.text.isEmpty }
        let made = MarqueeLayerView.makeCount - madeBefore
        let expandedAfter = ink(in: musicWindow, rect: expandedLyrics)
        print("— \(name) —")
        print("  歌词行数：\(model.music.lyrics.count)　当前句：\(model.music.currentLyric.isEmpty ? "无" : model.music.currentLyric)")
        print("  文字层新建次数：\(made)\(made == 0 ? " ✓ 复用同一个视图" : " ✗ 视图被重建")")
        if let firstVisible = visible.first {
            print("  文字上屏：\(String(format: "%.2f", firstVisible.at)) 秒")
        } else {
            print("  直到超时都没有文字上屏 ✗")
        }
        print("  展开面板歌词区：换歌前 \(expandedBefore) 个像素 → 歌词到位后 \(expandedAfter) 个像素\(expandedAfter > expandedBefore ? " ✓ 自己换上了新词" : " ✗ 没有变化")")
        reportSwap(name: name, samples: swapSamples)
        let curve = samples.map { String(format: "%.2f", $0.brightness) }.joined(separator: " ")
        print("  亮度曲线：\(curve)")
    }

    // 换字过程中文字要有渐变：既不能一直满不透明（等于硬切），
    // 也不能整块变暗（等于闪一下）。旧句由替身淡出、新句同时淡入，两者相加才是画面上的文字量
    private static func reportSwap(name: String, samples: [(first: Double, second: Double, ghosts: Double)]) {
        guard !samples.isEmpty else {
            print("  换字过程：没有采到样本")
            return
        }
        let top = samples.map { max($0.first, $0.second) }
        let total = samples.map { min(1, max($0.first, $0.second) + $0.ghosts) }
        let dimmest = total.min() ?? 0
        let gradient = top.filter { $0 > 0.05 && $0 < 0.95 }.count
        let ended = top.last ?? 0
        let smooth = gradient >= 2 && dimmest > 0.9 && ended > 0.99
        print("  换字过程：\(samples.count) 个样本，新句最低不透明度 \(String(format: "%.2f", top.min() ?? 0))，画面上文字量最低 \(String(format: "%.2f", dimmest))，过渡帧 \(gradient) 个，结束 \(String(format: "%.2f", ended))\(smooth ? " ✓ 有渐变且没有变暗" : " ✗ 过渡不对")")
    }

    // 找到窗口里那颗走马灯文字层
    private static func findMarquee(in window: NSWindow) -> MarqueeLayerView? {
        guard let root = window.contentView else { return nil }
        return search(root)
    }

    private static func search(_ view: NSView) -> MarqueeLayerView? {
        if let marquee = view as? MarqueeLayerView { return marquee }
        for child in view.subviews {
            if let found = search(child) { return found }
        }
        return nil
    }

    // 指定区域内与面板底色差得开的像素数
    private static func ink(in window: NSWindow, rect: NSRect) -> Int {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
        let scaleY = CGFloat(rep.pixelsHigh) / max(view.bounds.height, 1)
        let baseColor = NSColor(PanelThemeCatalog.palette(id: SettingsStore.shared.settings.panelTheme).surfaceColor)
        let base = baseColor.usingColorSpace(.sRGB) ?? baseColor
        let x0 = Int(rect.minX * scaleX)
        let x1 = min(rep.pixelsWide, Int(rect.maxX * scaleX))
        let y0 = Int((view.bounds.height - rect.maxY) * scaleY)
        let y1 = min(rep.pixelsHigh, Int((view.bounds.height - rect.minY) * scaleY))
        guard x1 > x0, y1 > y0 else { return 0 }
        var count = 0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.4 {
                    let red = abs(color.redComponent - base.redComponent)
                    let green = abs(color.greenComponent - base.greenComponent)
                    let blue = abs(color.blueComponent - base.blueComponent)
                    if red + green + blue > 0.1 { count += 1 }
                }
                x += 2
            }
            y += 2
        }
        return count
    }

    // 槽位内所有像素相对面板底色的亮度总和（0…1 归一）
    private static func brightness(in window: NSWindow) -> Double {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
        let scaleY = CGFloat(rep.pixelsHigh) / max(view.bounds.height, 1)
        let inset = slot.insetBy(dx: 1, dy: 1)
        let x0 = Int(inset.minX * scaleX)
        let x1 = min(rep.pixelsWide, Int(inset.maxX * scaleX))
        let y0 = Int((view.bounds.height - inset.maxY) * scaleY)
        let y1 = min(rep.pixelsHigh, Int((view.bounds.height - inset.minY) * scaleY))
        guard x1 > x0, y1 > y0 else { return 0 }
        var total = 0.0
        var count = 0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    x += 2
                    continue
                }
                let luminance = 0.2126 * Double(color.redComponent)
                    + 0.7152 * Double(color.greenComponent)
                    + 0.0722 * Double(color.blueComponent)
                total += max(0, luminance - 0.06)
                count += 1
                x += 2
            }
            y += 2
        }
        guard count > 0 else { return 0 }
        return total / Double(count)
    }

    private static func makeWindow(size: CGSize, offset: CGFloat) -> NSWindow? {
        guard let screen = NSScreen.screens.first else { return nil }
        let frame = NSRect(x: screen.visibleFrame.minX + offset, y: screen.visibleFrame.minY + 20,
                           width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        return window
    }
}

@MainActor
private final class LiveBox: ObservableObject {
    let model: DeckModel
    init(model: DeckModel) {
        self.model = model
    }
}

private struct LiveProbe: View {
    @ObservedObject var box: LiveBox
    @ObservedObject private var model: DeckModel

    init(box: LiveBox) {
        self.box = box
        self.model = box.model
    }

    var body: some View {
        CompactIslandView(content: model.compactContent(), onTap: {})
    }
}

private struct MusicProbe: View {
    @ObservedObject var model: DeckModel

    var body: some View {
        MusicPageView(music: model.music,
                      showTranslation: true,
                      onCommand: { _ in },
                      onSeek: { _ in },
                      onMode: {})
    }
}
