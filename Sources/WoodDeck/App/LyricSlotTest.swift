import AppKit
import SwiftUI

// 歌词槽位的过渡诊断：换句与换歌时逐帧量歌词区域的着色像素。
// 中间掉到接近两端较低的取值就是「歌词一闪」，说明旧内容已经消失、新内容还没画出来
enum LyricSlotTest {
    private static let first = "上一首的歌词第一句内容在这里"
    private static let second = "新歌的第一句歌词就是这一句内容"
    private static let caption = "新歌名称 · 歌手名"

    @MainActor
    static func run() {
        compactSequence()
        expandedSequence()
        rowLayout()
        layerSequence()
    }

    // 歌词的几行必须各占一行：叠在同一行上的话，只有一句和有三句看起来一样
    @MainActor
    private static func rowLayout() {
        let region = NSRect(x: 96, y: 40, width: 300, height: 120)
        var display = MusicDisplay(available: true)
        display.title = "自检曲目"
        display.artist = "自检歌手"
        display.duration = 240
        display.position = 30
        display.playing = false
        display.lyrics = [LyricLine(time: 0, text: "当前句的歌词文字", translation: nil)]
        display.currentLyric = "当前句的歌词文字"

        let single = bands(of: display, region: region)
        display.lyrics = [LyricLine(time: 0, text: "当前句的歌词文字", translation: "当前句的翻译"),
                          LyricLine(time: 5, text: "下一句的歌词文字", translation: nil)]
        display.currentTranslation = "当前句的翻译"
        display.nextLyric = "下一句的歌词文字"
        let triple = bands(of: display, region: region)
        print("—— 展开面板歌词行：只有当前句时 \(single) 条横带，加上翻译与下一句后 \(triple) 条（应当多出 2 条）\(triple >= single + 2 ? " ✓ 各占一行" : " ✗ 叠在一起了")")
    }

    @MainActor
    private static func bands(of display: MusicDisplay, region: NSRect) -> Int {
        let box = MusicPageBox(display: display)
        let window = makeWindow(MusicPageProbe(box: box, showTranslation: true),
                                size: CGSize(width: 520, height: 200))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        defer { window.orderOut(nil) }
        guard let rep = capture(window) else { return 0 }
        return textBands(rep, box: region)
    }

    // 区域内按行统计亮度足够高的像素，连成一片的算一条横带
    @MainActor
    private static func textBands(_ rep: NSBitmapImageRep, box: NSRect) -> Int {
        let scale = CGFloat(rep.pixelsHigh) / max(rep.size.height, 1)
        let left = max(Int(box.minX * scale), 0)
        let right = min(Int(box.maxX * scale), rep.pixelsWide)
        let top = max(Int(box.minY * scale), 0)
        let bottom = min(Int(box.maxY * scale), rep.pixelsHigh)
        var rows: [Bool] = []
        var y = top
        while y < bottom {
            var bright = 0
            var x = left
            while x < right {
                if let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let luminance = 0.2126 * Double(pixel.redComponent)
                        + 0.7152 * Double(pixel.greenComponent)
                        + 0.0722 * Double(pixel.blueComponent)
                    if luminance > 0.35 { bright += 1 }
                }
                x += 1
            }
            rows.append(bright > 2)
            y += 1
        }
        var bands = 0
        var run = 0
        for row in rows {
            if row {
                run += 1
            } else {
                if run >= Int(2 * scale) { bands += 1 }
                run = 0
            }
        }
        if run >= Int(2 * scale) { bands += 1 }
        return bands
    }

    // 换句时文字层内部的一次替换：旧句淡出，随后新句淡入，逐帧读真正呈现出的不透明度。
    // 截面截图只能看到图层模型的最终值，看不到 Core Animation 正在插值的过程，所以这里直接问呈现层
    @MainActor
    private static func layerSequence() {
        print("—— 换句时文字的不透明度")
        let view = MarqueeLayerView(frame: NSRect(x: 0, y: 0, width: 192, height: 16))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 192, height: 16),
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.contentView = view
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        view.configure(text: first, font: font, color: .white, spacing: 28, speed: 26,
                       initialDelay: 0.9, paused: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let start = Date()
        view.configure(text: second, font: font, color: .white, spacing: 28, speed: 26,
                       initialDelay: 0.9, paused: false)
        var samples: [(ms: Int, alpha: Double, total: Double)] = []
        while Date().timeIntervalSince(start) < 0.6 {
            let alphas = view.presentedAlphas()
            let ghosts = view.presentedGhostAlphas().reduce(0, +)
            let alpha = max(alphas.first, alphas.second)
            samples.append((Int(Date().timeIntervalSince(start) * 1000), alpha, min(1, alpha + ghosts)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        window.orderOut(nil)
        let curve = samples.map { String(format: "%.2f", $0.alpha) }.joined(separator: " ")
        let totalCurve = samples.map { String(format: "%.2f", $0.total) }.joined(separator: " ")
        print("  新句的不透明度曲线：\(curve)")
        print("  画面上文字量的曲线：\(totalCurve)")
        let transitional = samples.filter { $0.alpha > 0.05 && $0.alpha < 0.95 }.count
        let ended = samples.last?.alpha ?? 0
        let started = samples.first?.alpha ?? 0
        let dimmest = samples.map(\.total).min() ?? 0
        print("  起点 \(String(format: "%.2f", started))，过渡帧 \(transitional) 个，结束 \(String(format: "%.2f", ended))")
        print("  换句过程中文字量最低 \(String(format: "%.2f", dimmest))")
        print("  换句有渐变而不是硬切：\(transitional >= 1 ? "是 ✓" : "否 ✗")")
        print("  换完回到完全不透明：\(ended > 0.99 ? "是 ✓" : "否 ✗")")
        print("  换句过程中不会整体变暗：\(dimmest > 0.9 ? "是 ✓" : "否 ✗")")
    }

    // 收起形态：分列刘海的左段
    @MainActor
    private static func compactSequence() {
        guard let cover = NSImage(contentsOfFile: "docs/icon.png")?.tiffRepresentation else {
            print("—— 收起形态歌词过渡：docs 目录下没有可用的封面图片，这次跳过 ✗")
            return
        }
        var content = CompactContent(style: .notch,
                                     rings: [],
                                     clock: "",
                                     musicText: first,
                                     equalizer: false,
                                     playing: true,
                                     artwork: cover,
                                     coverTint: nil,
                                     alertColor: .white,
                                     lineProgress: nil,
                                     scale: 1,
                                     clockColor: .white,
                                     clockStyle: .minimal)
        content.artworkToken = "self#1"
        content.splitLeft = 238
        content.splitNotch = 185
        content.splitRight = 56

        let box = SlotBox(content: content)
        let size = CGSize(width: 238 + 185 + 56, height: 32)
        let window = makeWindow(SlotProbe(box: box), size: size)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        let region = NSRect(x: 46, y: 8, width: 192, height: 16)
        print("—— 收起形态换句时的歌词像素（区域从封面右侧到左段末尾）")
        print("  稳定时的歌词像素：\(ink(of: window, box: region))")
        trace(name: "换成另一句", to: second, box: box, window: window, region: region)
        sequence(name: "换歌：先标题再歌词（相隔 0.6 秒）",
                 steps: [(first, 0.6), (caption, 0.6), (second, 0.9)],
                 box: box, window: window, region: region)
        sequence(name: "换歌：标题与歌词几乎同时到（相隔 0.15 秒）",
                 steps: [(first, 0.6), (caption, 0.15), (second, 0.9)],
                 box: box, window: window, region: region)
    }

    // 展开面板：音乐页的歌词区
    @MainActor
    private static func expandedSequence() {
        var base = MusicDisplay(available: true)
        base.title = "新歌名称"
        base.artist = "歌手名"
        base.album = "专辑名"
        base.duration = 240
        base.position = 30
        base.playing = false
        base.lyrics = [LyricLine(time: -30, text: first, translation: nil)]
        base.currentLyric = first
        base.nextLyric = "上一首的第二句"

        let page = MusicPageBox(display: base)
        let size = CGSize(width: 520, height: 200)
        let window = makeWindow(MusicPageProbe(box: page), size: size)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        let withLyrics = capture(window)
        var cleared = base
        cleared.lyrics = []
        cleared.currentLyric = ""
        cleared.nextLyric = ""
        page.display = cleared
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let clearedFrame = capture(window)
        guard let region = changedBox(withLyrics, clearedFrame) else {
            print("—— 展开面板音乐页：找不到歌词变化的区域 ✗")
            return
        }
        let full = ink(of: window, box: region)
        print("—— 展开面板音乐页：歌词区 \(Int(region.width))×\(Int(region.height)) 点，有歌词时 \(full) 个着色像素")

        var restored = base
        restored.lyrics = [LyricLine(time: -30, text: second, translation: nil)]
        restored.currentLyric = second
        restored.nextLyric = "新歌的第二句"
        var lowest = Int.max
        let begin = CACurrentMediaTime()
        page.display = restored
        while CACurrentMediaTime() - begin < 1.0 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.008))
            lowest = min(lowest, ink(of: window, box: region))
        }
        let rest = ink(of: window, box: region)
        print(String(format: "  歌词清空后再填回来：全程最低 %d，结束于 %d，有歌词时 %d", lowest, rest, full))
        print("  填回来的过程中没有掉成清空时的样子：\(lowest > max(200, full / 2) ? "是 ✓" : "否 ✗")")
    }

    @MainActor
    private static func trace(name: String,
                              to text: String,
                              box: SlotBox,
                              window: NSWindow,
                              region: NSRect) {
        let before = ink(of: window, box: region)
        let begin = CACurrentMediaTime()
        box.content.musicText = text
        var samples: [(Double, Int)] = []
        while CACurrentMediaTime() - begin < 0.7 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.008))
            samples.append(((CACurrentMediaTime() - begin) * 1000, ink(of: window, box: region)))
        }
        let after = ink(of: window, box: region)
        report(name: name, samples: samples, before: before, after: after)
    }

    // 连续几步改文字，全程逐帧采样：任何一步之间掉成空白都会被抓到
    @MainActor
    private static func sequence(name: String,
                                 steps: [(String, Double)],
                                 box: SlotBox,
                                 window: NSWindow,
                                 region: NSRect) {
        print("—— \(name)")
        var lowest = Int.max
        var lowestAt: Double = 0
        for (text, hold) in steps {
            let begin = CACurrentMediaTime()
            box.content.musicText = text
            while CACurrentMediaTime() - begin < hold {
                RunLoop.main.run(until: Date().addingTimeInterval(0.008))
                let value = ink(of: window, box: region)
                if value < lowest {
                    lowest = value
                    lowestAt = (CACurrentMediaTime() - begin) * 1000
                }
            }
        }
        let rest = ink(of: window, box: region)
        print(String(format: "  全程最低 %d（出现在换字后 %.0f 毫秒），结束于 %d", lowest, lowestAt, rest))
        print("  全程没有掉成空白：\(lowest > max(400, rest / 3) ? "是 ✓" : "否 ✗")")
    }

    private static func report(name: String, samples: [(Double, Int)], before: Int, after: Int) {
        let low = samples.map(\.1).min() ?? 0
        let floor = Int(Double(min(before, after)) * 0.4)
        let dips = samples.filter { $0.1 < floor }
        let list = samples.prefix(16).map { String(format: "%.0f:%d", $0.0, $0.1) }.joined(separator: " ")
        print("—— \(name)：起点 \(before) → 终点 \(after)")
        print("  \(list)")
        print(String(format: "  最低 %d（两端较低者的 %d%%），掉到 40%% 以下的帧 %d 个 %@",
                     low,
                     min(before, after) > 0 ? low * 100 / min(before, after) : 0,
                     dips.count,
                     dips.isEmpty ? "✓" : "✗"))
    }

    @MainActor
    private static func makeWindow(_ view: some View, size: CGSize) -> NSWindow {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.clipsToBounds = true
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.clipsToBounds = true
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        // 窗口放在主屏左下角、几乎全透明：用户看不到，但窗口在屏幕上，动画照常推进
        let origin = NSScreen.screens.first?.frame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: origin.x + 20, y: origin.y + 20, width: size.width, height: size.height),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.alphaValue = 0.02
        window.animationBehavior = .none
        window.ignoresMouseEvents = true
        window.contentView = container
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private static func capture(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.subviews.first,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    // 区域内与面板底色不同的像素个数，区域按点给出
    @MainActor
    private static func ink(of window: NSWindow, box: NSRect) -> Int {
        guard let rep = capture(window) else { return 0 }
        let scale = CGFloat(rep.pixelsHigh) / max(rep.size.height, 1)
        let fill = (NSColor(PanelThemeCatalog.palette(id: SettingsStore.shared.settings.panelTheme).surfaceColor)
            .usingColorSpace(.sRGB) ?? NSColor.black)
        let left = max(Int(box.minX * scale), 0)
        let right = min(Int(box.maxX * scale), rep.pixelsWide)
        let top = max(Int(box.minY * scale), 0)
        let bottom = min(Int(box.maxY * scale), rep.pixelsHigh)
        var count = 0
        var y = top
        while y < bottom {
            var x = left
            while x < right {
                if let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.4 {
                    let delta = max(abs(pixel.redComponent - fill.redComponent),
                                    max(abs(pixel.greenComponent - fill.greenComponent),
                                        abs(pixel.blueComponent - fill.blueComponent)))
                    if delta > 0.1 { count += 1 }
                }
                x += 1
            }
            y += 1
        }
        return count
    }

    // 两帧之间发生变化的像素范围，按点返回
    @MainActor
    private static func changedBox(_ lhs: NSBitmapImageRep?, _ rhs: NSBitmapImageRep?) -> NSRect? {
        guard let lhs, let rhs, lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else {
            return nil
        }
        let scale = CGFloat(lhs.pixelsHigh) / max(lhs.size.height, 1)
        var minX = lhs.pixelsWide
        var maxX = -1
        var minY = lhs.pixelsHigh
        var maxY = -1
        var y = 0
        while y < lhs.pixelsHigh {
            var x = 0
            while x < lhs.pixelsWide {
                if let one = lhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   let two = rhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let delta = max(abs(one.redComponent - two.redComponent),
                                    max(abs(one.greenComponent - two.greenComponent),
                                        abs(one.blueComponent - two.blueComponent)))
                    if delta > 0.06 {
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                        minY = min(minY, y)
                        maxY = max(maxY, y)
                    }
                }
                x += 1
            }
            y += 1
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NSRect(x: CGFloat(minX) / scale,
                      y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale,
                      height: CGFloat(maxY - minY + 1) / scale)
    }
}

@MainActor
private final class SlotBox: ObservableObject {
    @Published var content: CompactContent

    init(content: CompactContent) {
        self.content = content
    }
}

private struct SlotProbe: View {
    @ObservedObject var box: SlotBox

    var body: some View {
        CompactIslandView(content: box.content, themeID: SettingsStore.shared.settings.panelTheme)
    }
}

@MainActor
private final class MusicPageBox: ObservableObject {
    @Published var display: MusicDisplay

    init(display: MusicDisplay) {
        self.display = display
    }
}

private struct MusicPageProbe: View {
    @ObservedObject var box: MusicPageBox
    var showTranslation: Bool = false

    var body: some View {
        MusicPageView(music: box.display,
                      showTranslation: showTranslation,
                      onCommand: { _ in },
                      onSeek: { _ in },
                      onMode: {})
            .frame(width: 520, height: 200)
            .background(Color.black)
    }
}
