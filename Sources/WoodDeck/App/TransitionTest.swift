import AppKit
import SwiftUI

// 换歌与换页的渐变诊断：逐帧截取界面，量出正在更换的那部分内容与前后两端的距离，
// 看它是一帧之内换掉，还是沿着曲线在两段之间过渡；同时量封面解码与取色的耗时
enum TransitionTest {
    @MainActor
    static func run() {
        let first = imageData(path: "docs/icon.png")
        let second = imageData(path: "docs/monitor.png")
        if let first, let second {
            coverReport(first: first, second: second)
            compactCoverReport(first: first, second: second)
        } else {
            print("—— 换歌渐变：docs 目录下没有可用的封面图片，这次跳过 ✗")
        }
        pageReport()
        costReport()
    }

    // MARK: - 换歌

    @MainActor
    private static func coverReport(first: Data, second: Data) {
        var music = MusicDisplay()
        music.available = true
        music.playing = true
        music.title = "渐变换歌自检曲目"
        music.artist = "WoodDeck"
        music.album = "Self Test"
        music.duration = 240
        music.sourceName = "自检"
        music.currentLyric = "Let the new cover fade in gently"
        music.nextLyric = "and the old one fade away"
        music.artwork = first
        music.artworkToken = "self#1"
        let box = MusicBox(music: music)
        let size = CGSize(width: 520, height: 200)
        let hosting = host(AnyView(MusicProbe(box: box)), size: size)
        defer { hosting.window?.orderOut(nil) }
        guard let before = pixels(hosting) else {
            print("—— 换歌渐变：截图失败 ✗")
            return
        }
        var swapped = music
        swapped.artwork = second
        swapped.artworkToken = "self#2"
        swapped.title = "渐变换歌之后的曲目"
        swapped.artist = "WoodDeck 自检"
        box.music = swapped
        let frames = trace(hosting: hosting)
        guard let after = pixels(hosting) else { return }
        let total = meanDelta(before, after)
        print("—— 换歌渐变（封面、曲名、歌手，\(Int(size.width))×\(Int(size.height))）")
        print(String(format: "  换图前后整块画面的平均差异 %.3f", total))
        guard total > 0.01 else {
            print("  两张封面与两段文字太接近，这次没有可比对的差异 ✗")
            return
        }
        let progress = frames.map { ($0.ms, meanDelta(before, $0.pixels) / total) }
        reportProgress(name: "换歌", samples: progress)
    }

    // 收起形态（胶囊整行）里的封面换图
    @MainActor
    private static func compactCoverReport(first: Data, second: Data) {
        let settings = SettingsStore.shared.settings
        var content = DeckModel.shared.compactContent()
        content.style = .capsule
        content.splitLeft = 0
        content.splitNotch = 0
        content.splitRight = 0
        content.alertText = nil
        content.musicText = "渐变换歌自检"
        content.equalizer = false
        content.rings = []
        content.clock = ""
        content.artwork = first
        content.artworkToken = "self#1"
        let box = CompactBox(content: content)
        let size = CGSize(width: max(240, settings.capsuleWidth), height: 32)
        let hosting = host(AnyView(CompactProbe(box: box, themeID: settings.panelTheme)), size: size)
        defer { hosting.window?.orderOut(nil) }
        guard let before = pixels(hosting) else {
            print("—— 收起形态换歌渐变：截图失败 ✗")
            return
        }
        var swapped = content
        swapped.artwork = second
        swapped.artworkToken = "self#2"
        box.content = swapped
        let frames = trace(hosting: hosting)
        guard let after = pixels(hosting) else { return }
        let total = meanDelta(before, after)
        print("—— 收起形态换歌渐变（胶囊整行，\(Int(size.width))×\(Int(size.height))）")
        print(String(format: "  换图前后整行的平均差异 %.3f", total))
        guard total > 0.002 else {
            print("  两张封面太接近，这次没有可比对的差异 ✗")
            return
        }
        let progress = frames.map { ($0.ms, meanDelta(before, $0.pixels) / total) }
        reportProgress(name: "收起形态换歌", samples: progress)
    }

    // MARK: - 换页

    @MainActor
    private static func pageReport() {
        let settings = SettingsStore.shared.settings
        let model = DeckModel.shared
        let box = PageBox(page: .quota)
        let size = CGSize(width: CGFloat(settings.width), height: CGFloat(settings.height))
        let hosting = host(AnyView(PanelProbe(box: box, settings: settings, model: model)), size: size)
        defer { hosting.window?.orderOut(nil) }
        guard let before = pixels(hosting) else {
            print("—— 换页渐变：截图失败 ✗")
            return
        }
        box.page = .music
        let frames = trace(hosting: hosting)
        guard let after = pixels(hosting) else { return }
        let total = meanDelta(before, after)
        print("—— 换页渐变（额度页到音乐页，\(Int(size.width))×\(Int(size.height))）")
        print(String(format: "  换页前后整块画面的平均差异 %.3f", total))
        guard total > 0.01 else {
            print("  两页内容太接近，这次没有可比对的差异 ✗")
            return
        }
        let progress = frames.map { ($0.ms, meanDelta(before, $0.pixels) / total) }
        reportProgress(name: "换页", samples: progress)
    }

    // MARK: - 耗时

    @MainActor
    private static func costReport() {
        guard let data = imageData(path: "docs/icon.png") else {
            print("—— 封面缓存耗时：docs 目录下没有可用的封面图片，这次跳过 ✗")
            return
        }
        print("—— 封面解码与取色的耗时（\(data.count) 字节的封面）")
        let decodeStart = CACurrentMediaTime()
        var decoded = 0
        for _ in 0..<10 where NSImage(data: data) != nil {
            decoded += 1
        }
        let decodeCost = (CACurrentMediaTime() - decodeStart) / 10 * 1000

        CoverCache.shared.clear()
        let missStart = CACurrentMediaTime()
        let firstImage = CoverCache.shared.image(for: data, token: "cost#1")
        let missCost = (CACurrentMediaTime() - missStart) * 1000
        let hitStart = CACurrentMediaTime()
        for _ in 0..<1000 {
            _ = CoverCache.shared.image(for: data, token: "cost#1")
        }
        let hitCost = (CACurrentMediaTime() - hitStart) / 1000 * 1000

        CoverColor.clearCache()
        let tintStart = CACurrentMediaTime()
        let firstTint = CoverColor.tint(from: data, token: "cost#1")
        let tintCost = (CACurrentMediaTime() - tintStart) * 1000
        let tintHitStart = CACurrentMediaTime()
        for _ in 0..<1000 {
            _ = CoverColor.tint(from: data, token: "cost#1")
        }
        let tintHitCost = (CACurrentMediaTime() - tintHitStart) / 1000 * 1000

        print(String(format: "  直接解码一张封面：%.2f 毫秒（成功 %d 次）", decodeCost, decoded))
        print(String(format: "  封面缓存第一次取图：%.2f 毫秒 → 命中一次：%.4f 毫秒", missCost, hitCost))
        print(String(format: "  取主色第一次：%.2f 毫秒 → 命中一次：%.4f 毫秒", tintCost, tintHitCost))
        let sample = firstTint == nil ? "无" : "有"
        print("  第一次取图与取主色都成功：\(firstImage != nil && firstTint != nil ? "是 ✓" : "否 ✗")（主色：\(sample)）")
        CoverCache.shared.clear()
        CoverColor.clearCache()
    }

    // MARK: - 度量

    // 每隔约一帧取一次画面，返回（毫秒，像素快照）
    @MainActor
    private static func trace(hosting: NSView) -> [(ms: Double, pixels: [Double])] {
        let begin = CACurrentMediaTime()
        var list: [(ms: Double, pixels: [Double])] = []
        while CACurrentMediaTime() - begin < 0.7 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.008))
            guard let snapshot = pixels(hosting) else { continue }
            list.append(((CACurrentMediaTime() - begin) * 1000, snapshot))
        }
        return list
    }

    private static func reportProgress(name: String, samples: [(ms: Double, delta: Double)]) {
        // 起点是 0、终点是 1，落在中间的就是正在过渡的帧
        let ramp = samples.filter { $0.delta > 0.05 && $0.delta < 0.95 }
        let first = samples.first { $0.delta > 0.02 }?.ms
        let last = samples.first { $0.delta > 0.98 }?.ms
        let duration = (last ?? 0) - (first ?? 0)
        let times = samples.map(\.ms)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        let average = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
        let list = samples.prefix(18).map { String(format: "%.0fms:%.2f", $0.ms, $0.delta) }.joined(separator: " ")
        print("  \(name)：\(list)")
        print(String(format: "  %@过渡：中间帧 %d 个，用时 %.0f 毫秒（采样间隔平均 %.1f 毫秒）%@",
                     name, ramp.count, duration, average,
                     ramp.count >= 2 && duration >= 100 ? " ✓" : " ✗"))
    }

    // 按固定步长取一遍像素，用于比较两次画面
    @MainActor
    private static func pixels(_ hosting: NSView) -> [Double]? {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        var list: [Double] = []
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    list.append(color.redComponent)
                    list.append(color.greenComponent)
                    list.append(color.blueComponent)
                } else {
                    list.append(0)
                    list.append(0)
                    list.append(0)
                }
                x += 6
            }
            y += 6
        }
        return list
    }

    private static func meanDelta(_ first: [Double], _ second: [Double]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        var sum = 0.0
        for index in first.indices {
            sum += abs(first[index] - second[index])
        }
        return sum / Double(first.count)
    }

    private static func imageData(path: String) -> Data? {
        let url = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: path)
        return try? Data(contentsOf: url)
    }

    @MainActor
    private static func host(_ view: AnyView, size: CGSize) -> NSView {
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        return hosting
    }
}

@MainActor
final class MusicBox: ObservableObject {
    @Published var music: MusicDisplay

    init(music: MusicDisplay) {
        self.music = music
    }
}

@MainActor
final class PageBox: ObservableObject {
    @Published var page: DeckPage

    init(page: DeckPage) {
        self.page = page
    }
}

@MainActor
final class CompactBox: ObservableObject {
    @Published var content: CompactContent

    init(content: CompactContent) {
        self.content = content
    }
}

private struct CompactProbe: View {
    @ObservedObject var box: CompactBox
    var themeID: String

    var body: some View {
        CompactIslandView(content: box.content, themeID: themeID, onTap: {})
    }
}

private struct MusicProbe: View {    @ObservedObject var box: MusicBox

    var body: some View {
        MusicPageView(music: box.music,
                      showTranslation: true,
                      onCommand: { _ in },
                      onSeek: { _ in },
                      onMode: {})
    }
}

private struct PanelProbe: View {
    @ObservedObject var box: PageBox
    var settings: DeckSettings
    var model: DeckModel

    var body: some View {
        ExpandedPanelView(settings: settings,
                          columns: model.columns,
                          music: model.music,
                          page: box.page,
                          refreshing: false,
                          lastRefresh: model.lastRefresh,
                          onPageChange: { _ in },
                          onRefresh: {},
                          onSettings: {},
                          onMusicCommand: { _ in },
                          onSeek: { _ in },
                          onMode: {},
                          onDetails: { _, _ in },
                          sessions: [],
                          onDismissSession: { _ in },
                          onClearFinished: {},
                          pages: [.quota, .music, .sessions])
    }
}
