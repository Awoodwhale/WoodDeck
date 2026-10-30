import AppKit
import SwiftUI

// 设置页配色自检：逐页渲染侧栏图标块与行首图标，读出像素颜色，确认每页颜色各不相同且跟随本页颜色
@MainActor
enum SettingsColorTest {
    static func run() -> [String] {
        var lines: [String] = []
        var tileColors: Set<String> = []
        var matched = 0
        for section in SettingsSection.allCases {
            // 渲染用深色外观，期望值也按深色外观解析系统颜色
            var expected = "无"
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                expected = hex(NSColor(section.tint))
            }
            let tile = sample(SettingsIconTile(symbol: section.icon, tint: section.tint, side: 20),
                              size: CGSize(width: 20, height: 20), at: CGPoint(x: 3, y: 10))
            let row = sample(SettingRow(icon: "circle.fill", title: section.title, description: nil) { EmptyView() }
                                .environment(\.settingsTint, section.tint)
                                .frame(width: 300, height: 40),
                             size: CGSize(width: 300, height: 40), at: CGPoint(x: 14, y: 20))
            tileColors.insert(tile)
            if close(row, expected) { matched += 1 }
            lines.append("\(section.title)：本页颜色 \(expected) 图标块 \(tile) 行首图标 \(row)")
        }
        let count = SettingsSection.allCases.count
        lines.append("图标块颜色 \(tileColors.count) 种（共 \(count) 页）\(tileColors.count == count ? "✓" : "✗")")
        lines.append("行首图标与本页颜色一致 \(matched)/\(count) \(matched == count ? "✓" : "✗")")
        return lines
    }

    // 按点坐标（左上为原点）读一个像素
    private static func sample(_ view: some View, size: CGSize, at point: CGPoint) -> String {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return "无" }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        guard let color = rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)) else { return "无" }
        return hex(color)
    }

    // 滑块刻度自检：同一个范围与步长，分别渲染带 step 的系统 Slider 与 SettingsSlider，
    // 数滑轨下方（视图下半部分）里画了东西的像素行数；再确认写回的数值按步长取整
    static func sliderReport() -> [String] {
        var lines: [String] = []
        let size = CGSize(width: 160, height: 28)
        let cases: [(String, ClosedRange<Double>, Double)] = [
            ("歌词延迟", -1000...1000, 10),
            ("提示停留时长", 2...60, 1),
        ]
        var cleared = 0
        for (name, range, step) in cases {
            var stored = (range.lowerBound + range.upperBound) / 2
            let binding = Binding(get: { stored }, set: { stored = $0 })
            let system = Slider(value: binding, in: range, step: step).frame(width: size.width, height: size.height)
            let custom = SettingsSlider(value: binding, range: range, step: step).frame(width: size.width, height: size.height)
            let before = inkRowsBelowTrack(system, size: size)
            let after = inkRowsBelowTrack(custom, size: size)
            if after < before { cleared += 1 }
            SettingsSlider(value: binding, range: range, step: step).snappedForTest(range.lowerBound + step * 2.4)
            let snapped = stored
            lines.append("\(name)：带 step 的系统滑块下方有内容的像素行 \(before)，设置页滑块 \(after)；写入 \(range.lowerBound + step * 2.4) 后取整为 \(snapped)")
        }
        lines.append("设置页滑块去掉了滑轨下方的刻度 \(cleared)/\(cases.count) \(cleared == cases.count ? "✓" : "✗")")
        return lines
    }

    private static func inkRowsBelowTrack(_ view: some View, size: CGSize) -> Int {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return -1 }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        var rows = 0
        // 滑轨在垂直中线附近，从中线往下 3 个点开始数；滑块把手停在正中，跳过中间 40% 的列
        let scale = CGFloat(rep.pixelsWide) / size.width
        let start = Int((size.height / 2 + 3) * scale)
        let thumb = Int(CGFloat(rep.pixelsWide) * 0.3)..<Int(CGFloat(rep.pixelsWide) * 0.7)
        for y in start..<rep.pixelsHigh {
            let inked = (0..<rep.pixelsWide).contains { x in
                !thumb.contains(x) && (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
            }
            if inked { rows += 1 }
        }
        return rows
    }

    // 合成与色彩空间转换会差几个色阶，三个通道各差不超过 6 算一致
    private static func close(_ lhs: String, _ rhs: String) -> Bool {
        func channels(_ text: String) -> [Int] {
            let digits = Array(text.dropFirst())
            guard digits.count == 6 else { return [] }
            return stride(from: 0, to: 6, by: 2).compactMap { Int(String(digits[$0...$0 + 1]), radix: 16) }
        }
        let a = channels(lhs), b = channels(rhs)
        guard a.count == 3, b.count == 3 else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) <= 6 }
    }

    private static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "无" }
        return String(format: "#%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }
}
