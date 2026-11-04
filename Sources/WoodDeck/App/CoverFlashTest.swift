import AppKit
import SwiftUI

// 换封面时画面会不会从底色里透出来：两张图各自淡入淡出时，中途两边都只有半透明，
// 底色会透上来，看起来就是闪一下。这里逐帧量封面区域的平均亮度，看它是否掉到两端之下
enum CoverFlashTest {
    @MainActor
    static func run() {
        guard let first = imageData(path: "docs/icon.png"),
              let second = imageData(path: "docs/themes.png") else {
            print("—— 换封面闪动：docs 目录下没有可用的封面图片，这次跳过 ✗")
            return
        }
        for (name, size, radius) in [("收起形态封面（20 点）", CGFloat(20), CGFloat(4)),
                                     ("展开面板封面（96 点）", 96, 8)] {
            report(name: name, size: size, radius: radius, first: first, second: second)
        }
    }

    @MainActor
    private static func report(name: String, size: CGFloat, radius: CGFloat, first: Data, second: Data) {
        let box = CoverBox(data: first, token: "self#1")
        let canvas = size + 20
        let fill = PanelThemeCatalog.palette(id: SettingsStore.shared.settings.panelTheme).surfaceColor
        let hosting = host(AnyView(CoverProbe(box: box, size: size, radius: radius, fill: fill)),
                           size: CGSize(width: canvas, height: canvas))
        defer { hosting.window?.orderOut(nil) }

        let before = luminance(hosting, size: size, canvas: canvas) ?? 0
        box.data = second
        box.token = "self#2"
        var samples: [(ms: Double, value: Double)] = []
        let begin = CACurrentMediaTime()
        while CACurrentMediaTime() - begin < 0.6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.008))
            guard let value = luminance(hosting, size: size, canvas: canvas) else { continue }
            samples.append(((CACurrentMediaTime() - begin) * 1000, value))
        }
        let after = luminance(hosting, size: size, canvas: canvas) ?? 0
        let lowest = min(before, after)
        let dip = samples.map(\.value).min() ?? lowest
        let drop = lowest > 0.001 ? (lowest - dip) / lowest : 0
        let list = samples.prefix(14).map { String(format: "%.0fms:%.3f", $0.ms, $0.value) }.joined(separator: " ")
        print("—— \(name)")
        print(String(format: "  换图前 %.3f，换图后 %.3f", before, after))
        print("  \(list)")
        print(String(format: "  过渡途中最低 %.3f，比两端更暗 %.0f%%%@",
                     dip, drop * 100, drop < 0.06 ? " ✓" : " ✗"))
    }

    // 封面区域的平均亮度：只看中间部分，避开圆角与边缘
    @MainActor
    private static func luminance(_ hosting: NSView, size: CGFloat, canvas: CGFloat) -> Double? {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / max(canvas, 1)
        let inset = (canvas - size) / 2 + size * 0.25
        let span = size * 0.5
        var sum = 0.0
        var count = 0
        var y = Int(inset * scale)
        while y < Int((inset + span) * scale) {
            var x = Int(inset * scale)
            while x < Int((inset + span) * scale) {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    sum += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                    count += 1
                }
                x += 2
            }
            y += 2
        }
        return count > 0 ? sum / Double(count) : nil
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
final class CoverBox: ObservableObject {
    @Published var data: Data?
    @Published var token: String

    init(data: Data?, token: String) {
        self.data = data
        self.token = token
    }
}

private struct CoverProbe: View {
    @ObservedObject var box: CoverBox
    var size: CGFloat
    var radius: CGFloat
    var fill: Color

    var body: some View {
        ZStack {
            fill
            CoverView(data: box.data, token: box.token, size: size, cornerRadius: radius)
        }
    }
}
