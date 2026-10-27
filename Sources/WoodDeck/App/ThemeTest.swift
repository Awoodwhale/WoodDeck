import AppKit
import SwiftUI

// 自检：切换面板配色后，真正渲染出来的收起形态颜色与歌词颜色都要跟着变
@MainActor
enum ThemeTest {
    static func run() {
        let model = DeckModel.shared
        let original = SettingsStore.shared.settings.panelTheme
        let content = model.compactContent()
        var bars: [(id: String, hex: String)] = []
        var lyrics: [(id: String, hex: String)] = []
        for palette in PanelThemeCatalog.all {
            SettingsStore.shared.update { $0.panelTheme = palette.id }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let bar = barColor(content: content)
            let lyric = lyricColor()
            bars.append((palette.id, bar))
            lyrics.append((palette.id, lyric))
            let expected = blended(palette.lyric, alpha: 0.95)
            print("\(palette.name)：收起形态平均色 \(bar)，歌词采样 \(lyric)（按 \(palette.lyric) 覆盖 0.95 应为 \(expected)）")
        }
        SettingsStore.shared.update { $0.panelTheme = original }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        print("恢复后的面板配色：\(SettingsStore.shared.settings.panelTheme)（原值 \(original)）")

        let barUnique = Set(bars.map(\.hex))
        print("六套配色渲染出 \(barUnique.count) 种不同的收起形态颜色 \(barUnique.count == bars.count ? "✓" : "✗")")
        let lyricUnique = Set(lyrics.map(\.hex))
        print("六套配色渲染出 \(lyricUnique.count) 种不同的歌词颜色 \(lyricUnique.count == lyrics.count ? "✓" : "✗")")
        let expected = PanelThemeCatalog.all.map { blended($0.lyric, alpha: 0.95) }
        // 颜色合成与抗锯齿会带来几个色阶的偏差，判定标准是每套采样都最接近自己那套主题
        let nearest = lyrics.map(\.hex).map { sample in
            expected.enumerated().min { distance(sample, $0.element) < distance(sample, $1.element) }?.offset ?? -1
        }
        let matched = zip(nearest, expected.indices).filter { $0 == $1 }.count
        print("歌词采样各自最接近本主题前景色的有 \(matched)/\(expected.count) 套 \(matched == expected.count ? "✓" : "✗")")
        if matched != expected.count {
            for (index, offset) in nearest.enumerated() where offset != index {
                print("  \(PanelThemeCatalog.all[index].name)：采样 \(lyrics[index].hex) 最接近 \(PanelThemeCatalog.all[offset].name) 的 \(expected[offset])")
            }
        }

        // 收起形态里的歌词行也要跟着主题变
        var compactLyrics: [(id: String, hex: String)] = []
        for palette in PanelThemeCatalog.all {
            SettingsStore.shared.update { $0.panelTheme = palette.id }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let hex = compactLyricColor(content: content)
            compactLyrics.append((palette.id, hex))
            print("\(palette.name)：收起形态歌词采样 \(hex)")
        }
        SettingsStore.shared.update { $0.panelTheme = original }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let compactUnique = Set(compactLyrics.map(\.hex))
        print("六套配色渲染出 \(compactUnique.count) 种不同的收起形态歌词颜色 \(compactUnique.count == compactLyrics.count ? "✓" : "✗")")
        liveRestyleReport()
    }

    // 渲染收起形态并取条子内部像素的平均色
    private static func barColor(content: CompactContent) -> String {
        let canvas = CGSize(width: 640, height: 170)
        let barWidth: CGFloat = 393
        let barHeight: CGFloat = 32
        let barRect = CGRect(x: (canvas.width - barWidth) / 2, y: 26, width: barWidth, height: barHeight)

        let view = ZStack {
            Color(white: 0.5)
            CompactIslandView(content: content)
                .frame(width: barWidth, height: barHeight)
                .padding(.top, 26)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: canvas.width, height: canvas.height)

        guard let bitmap = capture(view, canvas: canvas) else { return "取不到位图" }
        return bitmap.meanColor(in: barRect.insetBy(dx: 6, dy: 6))
    }

    // 歌词颜色：同一页面渲染两次，当前句为空的那张作为底，两张相减只留歌词笔画；
    // 笔画边缘是半透明的过渡像素，取最亮的一批才能代表文字本身的颜色
    private static func lyricColor() -> String {
        let canvas = CGSize(width: 320, height: 150)
        guard let withLyric = capture(musicPage(current: "自检歌词示例"), canvas: canvas),
              let blank = capture(musicPage(current: " "), canvas: canvas) else { return "渲染失败" }
        return coreColor(withLyric, blank)
    }

    // 收起形态里的歌词行：同样用「有歌词」与「只有空格」两张图相减
    private static func compactLyricColor(content: CompactContent) -> String {
        let canvas = CGSize(width: 640, height: 170)
        var withLyric = content
        withLyric.musicText = "自检歌词示例"
        withLyric.equalizer = false
        var blank = content
        blank.musicText = " "
        blank.equalizer = false
        guard let a = capture(compactView(withLyric, canvas: canvas), canvas: canvas),
              let b = capture(compactView(blank, canvas: canvas), canvas: canvas) else { return "渲染失败" }
        return coreColor(a, b)
    }

    private static func compactView(_ content: CompactContent, canvas: CGSize) -> some View {
        let barWidth: CGFloat = 393
        let barHeight: CGFloat = 32
        return ZStack {
            Color(white: 0.5)
            CompactIslandView(content: content)
                .frame(width: barWidth, height: barHeight)
                .padding(.top, 26)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    // 两张图相减，取差异像素里最亮的一批的平均色
    private static func coreColor(_ withText: Bitmap, _ blank: Bitmap) -> String {
        var samples: [(luminance: Int, red: Int, green: Int, blue: Int)] = []
        for y in 0..<min(withText.height, blank.height) {
            for x in 0..<min(withText.width, blank.width) {
                let a = withText.pixel(x: x, y: y)
                let b = blank.pixel(x: x, y: y)
                let difference = max(abs(a.0 - b.0), max(abs(a.1 - b.1), abs(a.2 - b.2)))
                guard difference > 12 else { continue }
                samples.append((a.0 + a.1 + a.2, a.0, a.1, a.2))
            }
        }
        guard !samples.isEmpty else { return "没有取样到歌词像素" }
        samples.sort { $0.luminance > $1.luminance }
        let core = samples.prefix(max(1, samples.count / 10))
        let red = core.reduce(0) { $0 + $1.red }
        let green = core.reduce(0) { $0 + $1.green }
        let blue = core.reduce(0) { $0 + $1.blue }
        return String(format: "#%02X%02X%02X", red / core.count, green / core.count, blue / core.count)
    }

    private static func musicPage(current: String) -> some View {
        ZStack {
            Color(white: 0.5)
            MusicPageView(music: LyricFadeTest.display(current: current, next: "下一句示例"),
                          showTranslation: false,
                          onCommand: { _ in },
                          onSeek: { _ in },
                          onMode: {})
                .frame(width: 320, height: 150)
        }
        .frame(width: 320, height: 150)
    }

    // 按 alpha 覆盖在采样用的中灰底色上，得到期望出现的颜色
    private static func blended(_ hex: String, alpha: CGFloat) -> String {
        let color = Theme.nsColor(hex).usingColorSpace(.sRGB) ?? .white
        let red = Int((color.redComponent * alpha + 0.5 * (1 - alpha)) * 255)
        let green = Int((color.greenComponent * alpha + 0.5 * (1 - alpha)) * 255)
        let blue = Int((color.blueComponent * alpha + 0.5 * (1 - alpha)) * 255)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    // 两个十六进制色之间的差值，用来做最近邻比较
    private static func distance(_ lhs: String, _ rhs: String) -> Int {
        let a = channels(lhs)
        let b = channels(rhs)
        guard a.count == 3, b.count == 3 else { return Int.max }
        return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }
    }

    private static func channels(_ hex: String) -> [Int] {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return [] }
        return [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
    }

    private struct Bitmap {
        var width: Int
        var height: Int
        var bytes: [UInt8]
        var bytesPerRow: Int
        var bytesPerPixel: Int
        var scale: CGFloat

        func pixel(x: Int, y: Int) -> (Int, Int, Int) {
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard offset + 2 < bytes.count else { return (0, 0, 0) }
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }

        // 取一块逻辑坐标区域内的像素平均色
        func meanColor(in rect: CGRect) -> String {
            let minX = max(0, Int(rect.minX * scale))
            let maxX = min(width - 1, Int(rect.maxX * scale))
            let minY = max(0, Int(rect.minY * scale))
            let maxY = min(height - 1, Int(rect.maxY * scale))
            guard minX <= maxX, minY <= maxY else { return "没有取样到像素" }
            var red = 0.0
            var green = 0.0
            var blue = 0.0
            var count = 0.0
            for y in minY...maxY {
                for x in minX...maxX {
                    let value = pixel(x: x, y: y)
                    red += Double(value.0)
                    green += Double(value.1)
                    blue += Double(value.2)
                    count += 1
                }
            }
            guard count > 0 else { return "没有取样到像素" }
            return String(format: "#%02X%02X%02X", Int(red / count), Int(green / count), Int(blue / count))
        }
    }

    // 离屏渲染一个视图并取回像素
    private static func capture(_ view: some View, canvas: CGSize) -> Bitmap? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: canvas)
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
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return bitmap(of: rep, canvas: canvas)
    }

    private static func bitmap(of rep: NSBitmapImageRep, canvas: CGSize) -> Bitmap? {
        guard let image = rep.cgImage,
              let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: pointer, count: CFDataGetLength(data)))
        return Bitmap(width: image.width,
                      height: image.height,
                      bytes: bytes,
                      bytesPerRow: image.bytesPerRow,
                      bytesPerPixel: image.bitsPerPixel / 8,
                      scale: CGFloat(image.width) / canvas.width)
    }

    // 收起形态的歌词画在 CATextLayer 里：换主题只改颜色、文字不变时也要立刻换色，
    // 否则要等下一次换句或重新展开才更新。这里走完整的链路：
    // 改设置 → 模型发布 → SwiftUI 重新求值 → 表示层换色
    @MainActor
    private static func liveRestyleReport() {
        let canvas = CGSize(width: 200, height: 22)
        let original = SettingsStore.shared.settings.panelTheme
        SettingsStore.shared.update { $0.panelTheme = "dark" }
        let hosting = NSHostingView(rootView: AnyView(RestyleProbe(model: DeckModel.shared)))
        hosting.frame = NSRect(origin: .zero, size: canvas)
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
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        func sample() -> String {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return "取不到位图" }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let bitmap = bitmap(of: rep, canvas: canvas) else { return "取不到位图" }
            var best = (luminance: -1, red: 0, green: 0, blue: 0)
            for y in 0..<bitmap.height {
                for x in 0..<bitmap.width {
                    let pixel = bitmap.pixel(x: x, y: y)
                    let luminance = pixel.0 + pixel.1 + pixel.2
                    if luminance > best.luminance {
                        best = (luminance, pixel.0, pixel.1, pixel.2)
                    }
                }
            }
            return String(format: "#%02X%02X%02X", best.red, best.green, best.blue)
        }

        let before = sample()
        SettingsStore.shared.update { $0.panelTheme = "cyberpunk" }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let after = sample()
        SettingsStore.shared.update { $0.panelTheme = original }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let expected = PanelThemeCatalog.all.first { $0.id == "cyberpunk" }?.lyric ?? "#FCE566"
        print("收起形态歌词：深色下最亮像素 \(before)，换成赛博朋克后 \(after)（应为 \(expected) 附近）")
    }

    private struct RestyleProbe: View {
        @ObservedObject var model: DeckModel

        var body: some View {
            MarqueeLayer(text: "自检歌词示例",
                         font: .systemFont(ofSize: 13, weight: .semibold),
                         color: NSColor(Theme.lyric),
                         paused: true)
                .frame(width: 200, height: 22)
                .background(Color.black)
        }
    }
}
