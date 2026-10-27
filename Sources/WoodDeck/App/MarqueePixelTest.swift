import AppKit
import SwiftUI

// 自检：走马灯滚动时文字层是否始终落在设备像素网格上。
// 落在网格上意味着字形不会被重新取样，滚动与静止两种状态的深浅、粗细一致
@MainActor
enum MarqueePixelTest {
    static func run() {
        let size = CGSize(width: 180, height: 20)
        let view = MarqueeLayerView(frame: NSRect(origin: .zero, size: size))
        view.configure(text: "这是一句很长的歌词用来触发走马灯滚动效果",
                       font: .systemFont(ofSize: 11, weight: .semibold),
                       color: NSColor.white.withAlphaComponent(0.86),
                       spacing: 28,
                       speed: 26,
                       initialDelay: 0.2,
                       paused: false)

        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = view
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let quantum = 1 / (window.backingScaleFactor)
        var samples = 0
        var misaligned = 0
        var positions: [CGFloat] = []
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        for _ in 0..<40 {
            if let layers = view.layer?.sublayers?.compactMap({ $0 as? CATextLayer }) {
                for textLayer in layers {
                    let x = textLayer.presentation()?.position.x ?? textLayer.position.x
                    samples += 1
                    let units = x / quantum
                    if abs(units - units.rounded()) > 0.001 { misaligned += 1 }
                    if textLayer === layers.first { positions.append(x) }
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let moving = (positions.max() ?? 0) - (positions.min() ?? 0)
        let advance = (positions.first ?? 0) - (positions.last ?? 0)
        print("设备像素 \(String(format: "%.2f", quantum)) 点")
        print("取样 \(samples) 次，偏离像素网格 \(misaligned) 次 \(misaligned == 0 ? "✓" : "✗")")
        print("首个文字层位置从 \(String(format: "%.2f", positions.first ?? 0)) 到 \(String(format: "%.2f", positions.last ?? 0))，"
              + "变化幅度 \(String(format: "%.1f", moving)) 点，净位移 \(String(format: "%.1f", advance)) 点 \(moving > 20 ? "✓" : "✗")")
        let distinct = Set(positions.map { Int(($0 / quantum).rounded()) }).count
        print("取样到 \(distinct) 个不同的像素位置 \(distinct > 10 ? "✓" : "✗")")

        // 换主题只改颜色、文字不变时，文字层要立刻换成新颜色
        let restyled = NSColor.systemRed
        view.configure(text: "这是一句很长的歌词用来触发走马灯滚动效果",
                       font: .systemFont(ofSize: 11, weight: .semibold),
                       color: restyled,
                       spacing: 28,
                       speed: 26,
                       initialDelay: 0.2,
                       paused: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let colors = (view.layer?.sublayers?.compactMap { $0 as? CATextLayer } ?? []).compactMap {
            ($0.string as? NSAttributedString)?
                .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        let restyledAll = !colors.isEmpty && colors.allSatisfy { $0.isEqual(restyled) }
        print("文字不变只换颜色后，\(colors.count) 个文字层都换成新颜色 \(restyledAll ? "✓" : "✗")")
    }
}
