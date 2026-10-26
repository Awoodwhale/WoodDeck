import AppKit
import SwiftUI

// 律动条：每根柱子的高度用 CABasicAnimation 反复来回，位移与高度都由 Core Animation 在渲染服务器上计算，
// SwiftUI 与主线程不参与逐帧工作，因此可以按显示器刷新率跑满而不占 CPU
final class EqualizerLayerView: NSView {
    private var barLayers: [CALayer] = []
    private var barWidth: CGFloat = 2.5
    private var maxHeight: CGFloat = 13
    private var color: NSColor = .white
    private var playing = false
    private var isPaused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override var isFlipped: Bool { true }

    func configure(color: NSColor, barWidth: CGFloat, height: CGFloat, count: Int, playing: Bool, paused: Bool) {
        let needsRebuild = self.barWidth != barWidth || self.maxHeight != height || barLayers.count != count
        self.color = color
        self.barWidth = barWidth
        self.maxHeight = height
        self.playing = playing
        self.isPaused = paused
        if needsRebuild {
            rebuild(count: count)
        } else {
            for bar in barLayers { bar.backgroundColor = color.cgColor }
        }
        needsLayout = true
        updateAnimations()
    }

    private func rebuild(count: Int) {
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers = (0..<max(1, count)).map { _ in
            let bar = CALayer()
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = color.cgColor
            layer?.addSublayer(bar)
            return bar
        }
    }

    override func layout() {
        super.layout()
        let gap = barWidth
        let totalWidth = CGFloat(barLayers.count) * barWidth + CGFloat(max(0, barLayers.count - 1)) * gap
        let startX = max(0, (bounds.width - totalWidth) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            let x = startX + CGFloat(index) * (barWidth + gap)
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight(index))
            bar.position = CGPoint(x: x + barWidth / 2, y: maxHeight / 2)
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = color.cgColor
        }
        CATransaction.commit()
    }

    private func barHeight(_ index: Int) -> CGFloat {
        // 静止时给一组固定的错落高度，看起来是有起伏但不跳动
        let base: [CGFloat] = [0.45, 0.75, 0.35, 0.6, 0.5]
        return max(2, maxHeight * base[index % base.count])
    }

    private func updateAnimations() {
        guard playing, !isPaused else {
            for bar in barLayers { bar.removeAnimation(forKey: "bounce") }
            return
        }
        for (index, bar) in barLayers.enumerated() {
            guard bar.animation(forKey: "bounce") == nil else { continue }
            let low = max(2, maxHeight * 0.18)
            let high = maxHeight * (0.62 + 0.28 * CGFloat(index % 3) / 2)
            let animation = CABasicAnimation(keyPath: "bounds.size.height")
            animation.fromValue = index % 2 == 0 ? low : high
            animation.toValue = index % 2 == 0 ? high : low
            animation.duration = 0.38 + Double(index) * 0.11
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.07
            bar.add(animation, forKey: "bounce")
        }
    }
}

// SwiftUI 侧的封装
struct EqualizerLayer: NSViewRepresentable {
    var color: NSColor
    var barWidth: CGFloat
    var height: CGFloat
    var count: Int = 4
    var playing: Bool
    var paused: Bool

    func makeNSView(context: Context) -> EqualizerLayerView {
        let view = EqualizerLayerView()
        view.configure(color: color, barWidth: barWidth, height: height, count: count, playing: playing, paused: paused)
        return view
    }

    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.configure(color: color, barWidth: barWidth, height: height, count: count, playing: playing, paused: paused)
    }
}
