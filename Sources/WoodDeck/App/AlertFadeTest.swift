import AppKit
import SwiftUI

// 会话提醒出现与收回的渐变诊断：逐帧截取面板，量出提醒文字当前的不透明度，
// 看它是一帧之内整块跳出来，还是沿着曲线渐变
enum AlertFadeTest {
    // 提醒用红色，与白色歌词、深色底都拉得开
    private static let alertColor = Color(#colorLiteral(red: 0.906, green: 0.51, blue: 0.518, alpha: 1))
    private static let alertText = "DSH · 修复歌词提前 · 出错"

    @MainActor
    static func run() {
        let settings = SettingsStore.shared.settings
        let model = DeckModel.shared
        model.start()
        // 歌词要等媒体流和歌词查询回来，收起条上才有内容可以对比
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && model.compactContent().musicText.isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let base = model.compactContent()
        print("当前歌词「\(base.musicText)」")

        // 分列刘海：提醒替换左侧那一段的歌词
        var split = clean(base)
        split.style = .notch
        measure(name: "分列刘海左段",
                size: CGSize(width: max(split.splitLeft + split.splitNotch + split.splitRight, 200), height: 32),
                rows: nil,
                base: split,
                make: { box in AnyView(CompactProbe(box: box, themeID: settings.panelTheme)) },
                apply: { box, text in box.content.alertText = text })

        // 胶囊：提醒替换整行的内容
        var capsule = clean(base)
        capsule.style = .capsule
        capsule.splitLeft = 0
        capsule.splitNotch = 0
        capsule.splitRight = 0
        measure(name: "胶囊整行",
                size: CGSize(width: max(240, settings.capsuleWidth), height: 32),
                rows: nil,
                base: capsule,
                make: { box in AnyView(CompactProbe(box: box, themeID: settings.panelTheme)) },
                apply: { box, text in box.content.alertText = text })

        // 展开面板：提醒条插在标题行与分隔线之间，只量那一条所在的高度
        measure(name: "展开面板",
                size: CGSize(width: CGFloat(settings.width), height: CGFloat(settings.height)),
                rows: 30...58,
                base: clean(base),
                make: { box in AnyView(ExpandedProbe(box: box, settings: settings, model: model)) },
                apply: { box, text in box.alertText = text ?? "" })

        layoutReport(base: base, settings: settings)
    }

    // 没有提醒时，封面、歌词、律动条应当左右排开。
    // 三者叠在一起时歌词会压住封面，律动条也会被歌词遮住
    @MainActor
    private static func layoutReport(base: CompactContent, settings: DeckSettings) {
        guard base.artwork != nil else {
            print("—— 收起形态排版：当前曲目没有封面，这次跳过")
            return
        }
        guard !base.musicText.isEmpty else {
            print("—— 收起形态排版：当前没有歌词，这次跳过")
            return
        }
        var notch = base
        notch.alertText = nil
        notch.style = .notch
        notch.equalizer = true
        notch.playing = false
        notch.animating = true
        // 整条岛都要画出来：分列布局的左右两段按总宽度排开，只留左段会把内容推出画面
        let island = max(notch.splitLeft + notch.splitNotch + notch.splitRight, 200)
        check(name: "分列刘海左段",
              content: notch,
              size: CGSize(width: island, height: 32),
              band: (notch.splitLeft - 12 - 16)...(notch.splitLeft - 10),
              themeID: settings.panelTheme,
              note: "岛宽 \(Int(island)) 点，左段 \(Int(notch.splitLeft)) 点")
        // 胶囊整行按自己的宽度排，内边距随缩放变化，这里只核对次序
        var capsule = notch
        capsule.style = .capsule
        capsule.splitLeft = 0
        capsule.splitNotch = 0
        capsule.splitRight = 0
        let width = max(settings.capsuleWidth, 240)
        check(name: "胶囊整行",
              content: capsule,
              size: CGSize(width: width, height: 32),
              band: (width - 30)...(width - 6),
              themeID: settings.panelTheme,
              note: "宽 \(Int(width)) 点")
    }

    @MainActor
    private static func check(name: String,
                              content: CompactContent,
                              size: CGSize,
                              band: ClosedRange<CGFloat>,
                              themeID: String,
                              note: String) {
        // 换一句长度不同的歌词，两张截图相减就只剩歌词本身的像素
        var alternate = content
        alternate.musicText = "排版自检替代歌词甲乙丙丁戊己庚辛壬癸子丑寅卯"
        guard let current = shot(content, size: size, themeID: themeID),
              let other = shot(alternate, size: size, themeID: themeID) else {
            print("—— \(name) 排版：截图失败 ✗")
            return
        }
        let lyric = span(of: changed(from: current, to: other))
        let scaleValue = CGFloat(min(max(content.scale, 0.75), 2))
        let musicScale = content.style == .capsule ? scaleValue : max(1.15, min(1.55, scaleValue * 1.25))
        let artworkRight = 12 + 20 * musicScale
        print("—— \(name) 排版（\(note)，含封面、歌词、律动条）")
        print(String(format: "  封面右边缘约 %.0f 点，歌词从 %.0f 点到 %.0f 点", artworkRight, lyric.left, lyric.right))
        print("  歌词没有压在封面上：\(lyric.left >= artworkRight + 2 ? "是 ✓" : "否 ✗")")

        // 律动条固定在右端：把歌词换成一句短的，右端就只剩律动条的像素
        var short = content
        short.musicText = "排版自检"
        short.playing = true
        var quiet = short
        quiet.equalizer = false
        guard let bars = shot(short, size: size, themeID: themeID),
              let bare = shot(quiet, size: size, themeID: themeID) else { return }
        let withBars = ink(in: bars, band: band, themeID: themeID)
        let withoutBars = ink(in: bare, band: band, themeID: themeID)
        print(String(format: "  右端的律动条：有 %d 个着色像素，去掉律动条后 %d 个", withBars, withoutBars))
        print("  律动条画在歌词右边：\(withBars > 100 && withoutBars < 40 ? "是 ✓" : "否 ✗")")
    }

    // 一次渲染的结果，坐标按点算
    @MainActor
    private static func shot(_ content: CompactContent, size: CGSize, themeID: String) -> NSBitmapImageRep? {
        let hosting = host(AnyView(CompactProbe(box: AlertBox(content: content), themeID: themeID)),
                           size: size)
        let rep = bitmap(of: hosting)
        hosting.window?.orderOut(nil)
        return rep
    }

    // 两张截图里颜色不同的像素
    @MainActor
    private static func changed(from first: NSBitmapImageRep, to second: NSBitmapImageRep) -> [(x: CGFloat, y: CGFloat)] {
        guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else { return [] }
        let scale = CGFloat(first.pixelsHigh) / max(first.size.height, 1)
        var list: [(x: CGFloat, y: CGFloat)] = []
        var y = 0
        while y < first.pixelsHigh {
            var x = 0
            while x < first.pixelsWide {
                if let one = first.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   let two = second.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let delta = max(abs(one.redComponent - two.redComponent),
                                    max(abs(one.greenComponent - two.greenComponent),
                                        abs(one.blueComponent - two.blueComponent)))
                    if delta > 0.06 { list.append((CGFloat(x) / scale, CGFloat(y) / scale)) }
                }
                x += 1
            }
            y += 1
        }
        return list
    }

    private static func span(of points: [(x: CGFloat, y: CGFloat)]) -> (left: CGFloat, right: CGFloat) {
        guard !points.isEmpty else { return (-1, -1) }
        return (points.map(\.x).min() ?? -1, points.map(\.x).max() ?? -1)
    }

    // 指定横条里与底色不同的像素个数
    @MainActor
    private static func ink(in rep: NSBitmapImageRep, band: ClosedRange<CGFloat>, themeID: String) -> Int {
        let scale = CGFloat(rep.pixelsHigh) / max(rep.size.height, 1)
        let lower = Int(band.lowerBound * scale)
        let upper = Int(band.upperBound * scale)
        let fill = (NSColor(PanelThemeCatalog.palette(id: themeID).surfaceColor).usingColorSpace(.sRGB)
                    ?? NSColor.black)
        var count = 0
        var y = Int(8 * scale)
        while y < Int(24 * scale) && y < rep.pixelsHigh {
            var x = max(lower, 0)
            while x < min(upper, rep.pixelsWide) {
                if let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let delta = max(abs(pixel.redComponent - fill.redComponent),
                                    abs(pixel.greenComponent - fill.greenComponent),
                                    abs(pixel.blueComponent - fill.blueComponent))
                    if delta > 0.1 { count += 1 }
                }
                x += 1
            }
            y += 1
        }
        return count
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
        // 窗口放在主屏左下角、几乎全透明：用户看不到，但窗口在屏幕上，视图照常布局
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

    @MainActor
    private static func bitmap(of hosting: NSView) -> NSBitmapImageRep? {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    // 探针只留歌词与提醒：封面、额度环、律动条都可能带接近提醒色的像素
    private static func clean(_ content: CompactContent) -> CompactContent {
        var item = content
        item.alertText = nil
        item.alertColor = alertColor
        item.artwork = nil
        item.rings = []
        item.equalizer = false
        item.clock = ""
        item.monitorCpu = nil
        item.monitorMemory = nil
        item.monitorNetwork = nil
        return item
    }

    @MainActor
    private static func measure<Content: View>(name: String,
                                               size: CGSize,
                                               rows: ClosedRange<CGFloat>?,
                                               base: CompactContent,
                                               make: @escaping (AlertBox) -> Content,
                                               apply: @escaping (AlertBox, String?) -> Void) {
        let box = AlertBox(content: base)
        let hosting = NSHostingView(rootView: make(box))
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
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        let rest = opacity(of: hosting, rows: rows)
        let appear = trace {
            apply(box, alertText)
        } sample: { opacity(of: hosting, rows: rows) }
        let full = appear.map(\.1).max() ?? rest
        let vanish = trace {
            apply(box, nil)
        } sample: { opacity(of: hosting, rows: rows) }

        print("—— \(name)（\(Int(size.width))×\(Int(size.height))）")
        print(String(format: "  出现前提醒不透明度 %.2f，显示时 %.2f", rest, full))
        report(label: "出现", samples: appear, from: rest, to: full)
        report(label: "收回", samples: vanish, from: full, to: rest)
    }

    // 每隔一帧取一次读数，返回（毫秒，不透明度）
    @MainActor
    private static func trace(trigger: () -> Void,
                              sample: () -> Double) -> [(Double, Double)] {
        let begin = CACurrentMediaTime()
        trigger()
        var list: [(Double, Double)] = []
        while CACurrentMediaTime() - begin < 0.7 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.008))
            list.append(((CACurrentMediaTime() - begin) * 1000, sample()))
        }
        return list
    }

    // 从 from 变到 to 的过程里，落在中间的帧数与用时
    private static func report(label: String, samples: [(Double, Double)], from: Double, to: Double) {
        let span = to - from
        guard abs(span) > 0.3 else {
            print(String(format: "  %@：起点 %.2f 与终点 %.2f 差别太小，这次没有可比对的提醒 ✗", label, from, to))
            return
        }
        func progress(_ value: Double) -> Double { (value - from) / span }
        let ramp = samples.filter { progress($0.1) > 0.05 && progress($0.1) < 0.95 }
        let first = samples.first { progress($0.1) > 0.02 }?.0
        let reached = samples.first { progress($0.1) > 0.98 }?.0
        let duration = (reached ?? 0) - (first ?? 0)
        let times = samples.map(\.0)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        let average = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
        let list = samples.prefix(18).map { String(format: "%.0fms:%.2f", $0.0, $0.1) }.joined(separator: " ")
        print("  \(label)：\(list)")
        print(String(format: "  %@由 %.2f 变到 %.2f：中间帧 %d 个，用时 %.0f 毫秒（采样间隔平均 %.1f 毫秒）%@",
                     label, from, to, ramp.count, duration, average,
                     ramp.count >= 2 && duration >= 100 ? " ✓" : " ✗"))
    }

    // 量提醒文字当前的不透明度：红色通道比绿蓝高出多少，与完全不透明时的差值相比。
    // 白字与底色在这项上都是 0，只有提醒的红色会随不透明度线性变化
    @MainActor
    private static func opacity(of hosting: NSView, rows: ClosedRange<CGFloat>?) -> Double {
        guard let target = NSColor(alertColor).usingColorSpace(.sRGB),
              let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let full = target.redComponent - max(target.greenComponent, target.blueComponent)
        guard full > 0.05 else { return 0 }
        let scale = CGFloat(rep.pixelsHigh) / max(rep.size.height, 1)
        let lower = max(Int((rows?.lowerBound ?? 0) * scale), 0)
        let upper = min(Int((rows?.upperBound ?? rep.size.height) * scale), rep.pixelsHigh)
        var peak: Double = 0
        var y = lower
        while y < upper {
            var x = 0
            while x < rep.pixelsWide {
                if let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.4 {
                    let excess = (pixel.redComponent - max(pixel.greenComponent, pixel.blueComponent)) / full
                    if excess > peak { peak = min(Double(excess), 1) }
                }
                x += 2
            }
            y += 2
        }
        return peak
    }
}

// 探针的状态：收起形态改 content.alertText，展开形态改 alertText
@MainActor
final class AlertBox: ObservableObject {
    @Published var content: CompactContent
    @Published var alertText: String = ""

    init(content: CompactContent) {
        self.content = content
    }
}

// 收起条的宿主：内容放在 box 里，改 box 的 content 时视图自己重算
private struct CompactProbe: View {
    @ObservedObject var box: AlertBox
    var themeID: String

    var body: some View {
        CompactIslandView(content: box.content, themeID: themeID, onTap: {})
    }
}

// 展开面板的宿主：提醒文字作为入参传进去，与应用的传法一致
private struct ExpandedProbe: View {
    @ObservedObject var box: AlertBox
    var settings: DeckSettings
    var model: DeckModel

    var body: some View {
        ExpandedPanelView(settings: settings,
                          columns: model.columns,
                          music: model.music,
                          page: .sessions,
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
                          pages: [.quota, .sessions, .music],
                          alertText: box.alertText,
                          alertColor: Color(#colorLiteral(red: 0.906, green: 0.51, blue: 0.518, alpha: 1)))
    }
}
