import AppKit
import SwiftUI

// 用 CATextLayer 自带的动画实现走马灯：位移由 Core Animation 在渲染服务器上插值，
// 屏幕上按显示器刷新率平滑推进，而进程不需要逐帧重绘视图树，CPU 占用与帧率无关。
final class MarqueeLayerView: NSView {
    private let first = CATextLayer()
    private let second = CATextLayer()

    private var textAttributes = NSAttributedString()
    private var textWidth: CGFloat = 0
    private var spacing: CGFloat = 28
    private var speed: CGFloat = 26
    private var initialDelay: TimeInterval = 0.9
    private var isPaused = false
    private var needsRestart = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for textLayer in [first, second] {
            textLayer.anchorPoint = CGPoint(x: 0, y: 0)
            textLayer.alignmentMode = .left
            textLayer.truncationMode = .none
            textLayer.isWrapped = false
            layer?.addSublayer(textLayer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override var isFlipped: Bool { true }

    func configure(text: String, font: NSFont, color: NSColor, spacing: CGFloat, speed: CGFloat,
                   initialDelay: TimeInterval, paused: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let width = ceil(attributed.size().width)
        let changed = width != textWidth
            || textAttributes.string != text
            || self.spacing != spacing
            || self.speed != speed
            || self.initialDelay != initialDelay
        textAttributes = attributed
        textWidth = width
        self.spacing = spacing
        self.speed = speed
        self.initialDelay = initialDelay
        let wasPaused = isPaused
        isPaused = paused
        if changed {
            needsRestart = true
            applyText()
        }
        if paused {
            pauseAnimations()
        } else if wasPaused {
            // 从暂停恢复：重新走一遍，否则会停在原地直到文本变化
            needsRestart = true
            needsLayout = true
        }
    }

    private func applyText() {
        let scale = window?.backingScaleFactor ?? 2
        for textLayer in [first, second] {
            textLayer.contentsScale = scale
            textLayer.string = textAttributes
        }
        needsLayout = true
    }

    private var lastLayoutWidth: CGFloat = -1

    override func layout() {
        super.layout()
        let height = bounds.height
        let scale = window?.backingScaleFactor ?? 2
        // 可用宽度变了说明是展开/收起或旋转导致的重新布局，重启走马灯，
        // 否则可能保留下上一轮的动画状态，看起来像歌词没出现
        if bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            needsRestart = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for textLayer in [first, second] {
            textLayer.contentsScale = scale
            textLayer.bounds = CGRect(x: 0, y: 0, width: textWidth, height: height)
            textLayer.fontSize = (textAttributes.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont)?.pointSize ?? 11
        }
        // 垂直居中：CATextLayer 的 bounds 以左下为原点，这里按翻转坐标系摆位
        let textHeight = textAttributes.size().height
        let top = max(0, (height - textHeight) / 2)
        first.position = CGPoint(x: 0, y: top)
        second.position = CGPoint(x: textWidth + spacing, y: top)
        first.isHidden = false
        // 第二份只在真正滚动时才显示：放得下的时候显示两份会看到重复的文本
        let scrolling = !isPaused && textWidth > bounds.width + 0.5
        second.isHidden = !scrolling
        CATransaction.commit()
        if needsRestart {
            needsRestart = false
            startAnimations()
        }
    }

    private func startAnimations() {
        guard !isPaused, speed > 0, textWidth > bounds.width + 0.5 else {
            resetPositions()
            return
        }
        let distance = textWidth + spacing
        let duration = max(1.2, Double(distance / speed))
        layer?.speed = 1
        resetPositions()
        for textLayer in [first, second] {
            textLayer.removeAllAnimations()
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = 0
            animation.toValue = -distance
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.beginTime = CACurrentMediaTime() + initialDelay
            textLayer.add(animation, forKey: "marquee")
        }
    }

    // 把两份文本放回起点。暂停时用回到起点而不是冻结时钟：
    // 冻结会让画面停在滚动中间，面板收起后若这一帧没有重新布局，
    // 文本就可能停在屏幕外，看起来就是「歌词消失了」。
    // 显隐交给 layout()，这里不动，否则滚动时第二份会一直被藏起来
    private func resetPositions() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        first.removeAllAnimations()
        second.removeAllAnimations()
        layer?.speed = 1
        let top = first.position.y
        first.position = CGPoint(x: 0, y: top)
        first.isHidden = false
        second.position = CGPoint(x: textWidth + spacing, y: top)
        CATransaction.commit()
    }

    private func pauseAnimations() {
        resetPositions()
    }

    // 面板在动或隐藏时停住，避免无谓的合成
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            pauseAnimations()
        } else {
            needsRestart = true
            needsLayout = true
        }
    }
}

// SwiftUI 侧的封装：尺寸变化、文本变化都重新开始
struct MarqueeLayer: NSViewRepresentable {
    var text: String
    var font: NSFont
    var color: NSColor
    var spacing: CGFloat = 28
    var speed: CGFloat = 26
    var initialDelay: TimeInterval = 0.9
    var paused: Bool = false

    func makeNSView(context: Context) -> MarqueeLayerView {
        let view = MarqueeLayerView()
        view.configure(text: text, font: font, color: color, spacing: spacing, speed: speed,
                       initialDelay: initialDelay, paused: paused)
        return view
    }

    func updateNSView(_ view: MarqueeLayerView, context: Context) {
        view.configure(text: text, font: font, color: color, spacing: spacing, speed: speed,
                       initialDelay: initialDelay, paused: paused)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarqueeLayerView, context: Context) -> CGSize? {
        nil
    }
}
