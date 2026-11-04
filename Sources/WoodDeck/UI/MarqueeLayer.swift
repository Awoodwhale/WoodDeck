import AppKit
import SwiftUI

// 用 CATextLayer 自带的动画实现走马灯：位移由 Core Animation 在渲染服务器上插值，
// 屏幕上按显示器刷新率平滑推进，而进程不需要逐帧重绘视图树，CPU 占用与帧率无关。
// 位移按设备像素对齐取样：文字层只出现在整数像素位置上，成形方式与静止时完全一致，
// 于是滚动与否不会改变字形的深浅与粗细。
final class MarqueeLayerView: NSView {
    private let first = CATextLayer()
    private let second = CATextLayer()
    private let fadeDuration: TimeInterval = 0.22

    // 自检用：新建过几次视图。文字层被重建时这个数会露出来
    nonisolated(unsafe) static var makeCount = 0

    private var textAttributes = NSAttributedString()
    private var textWidth: CGFloat = 0
    private var textColor: NSColor = .white
    private var textFont: NSFont = .systemFont(ofSize: 11)
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
        let textChanged = textAttributes.string != text
        let changed = width != textWidth
            || textChanged
            || self.spacing != spacing
            || self.speed != speed
            || self.initialDelay != initialDelay
        // 换主题时只有颜色与字重会变，这时就地重画并保持当前滚动位置
        let restyled = !sameColor(textColor, color) || textFont != font
        // 换句时旧句由替身原地淡出、新句同时淡入：两层的不透明度互补，
        // 画面上始终有等量的字，既不空白也不整体变暗
        let crossfade = textChanged && !textAttributes.string.isEmpty && !isPaused
        textAttributes = attributed
        textWidth = width
        textColor = color
        textFont = font
        self.spacing = spacing
        self.speed = speed
        self.initialDelay = initialDelay
        let wasPaused = isPaused
        isPaused = paused
        if changed {
            if crossfade {
                crossfadeToText()
            } else {
                needsRestart = true
                applyText(fadeIn: textChanged && !text.isEmpty && !isPaused)
            }
        } else if restyled {
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

    // NSColor 的相等判断对颜色空间敏感，按 sRGB 分量比较，
    // 免得同一颜色每次求值都被当成变了而反复重画
    private func sameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.sRGB), let right = rhs.usingColorSpace(.sRGB) else {
            return lhs.isEqual(rhs)
        }
        return abs(left.redComponent - right.redComponent) < 0.001
            && abs(left.greenComponent - right.greenComponent) < 0.001
            && abs(left.blueComponent - right.blueComponent) < 0.001
            && abs(left.alphaComponent - right.alphaComponent) < 0.001
    }

    private func applyText(fadeIn: Bool = false) {
        let scale = window?.backingScaleFactor ?? 2
        for textLayer in [first, second] {
            textLayer.contentsScale = scale
            textLayer.rasterizationScale = scale
            textLayer.string = textAttributes
        }
        pendingFadeIn = fadeIn
        needsLayout = true
        // 当场摆好两层文字：换字之前视图尺寸可能还没变，等下一轮布局的话，
        // 新文字会按旧宽度排在外面，看起来就是这一段没有歌词
        reflow()
    }

    private var pendingFadeIn = false

    // 自检用：换过几次字
    nonisolated(unsafe) static var crossfadeCount = 0

    // 旧句的替身：按此刻呈现出的样子复制一层，原地淡出，新句同时淡入
    private var ghosts: [CATextLayer] = []

    private func crossfadeToText() {
        Self.crossfadeCount += 1
        swapGeneration += 1
        for source in [first, second] where !source.isHidden {
            let live = source.presentation() ?? source
            let ghost = CATextLayer()
            ghost.string = live.string
            ghost.font = live.font
            ghost.fontSize = live.fontSize
            ghost.anchorPoint = live.anchorPoint
            ghost.bounds = live.bounds
            ghost.position = live.position
            ghost.alignmentMode = live.alignmentMode
            ghost.truncationMode = live.truncationMode
            ghost.isWrapped = live.isWrapped
            ghost.contentsScale = live.contentsScale
            ghost.rasterizationScale = live.rasterizationScale
            ghost.opacity = 0
            ghost.setAffineTransform(live.affineTransform())
            layer?.addSublayer(ghost)
            ghosts.append(ghost)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = fadeDuration
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ghost.add(fade, forKey: "ghostFadeOut")
            // 淡完就摘掉，不等换字的节拍：下一次换字可能来得更早
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration) { [weak self, weak ghost] in
                guard let ghost else { return }
                ghost.removeFromSuperlayer()
                self?.ghosts.removeAll { $0 === ghost }
            }
        }
        // 替身太多说明换字过密，先清掉最早的几个，避免图层越堆越多
        while ghosts.count > 6, let oldest = ghosts.first {
            oldest.removeFromSuperlayer()
            ghosts.removeFirst()
        }
        needsRestart = true
        applyText(fadeIn: true)
    }

    private var swapGeneration = 0

    private func fadeInText() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for textLayer in [first, second] {
            textLayer.opacity = 1
        }
        CATransaction.commit()
        for textLayer in [first, second] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = fadeDuration
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            textLayer.add(fade, forKey: "textFadeIn")
        }
    }

    private var lastLayoutWidth: CGFloat = -1

    // 自检用：两层文字此刻真正呈现出的不透明度
    func presentedAlphas() -> (first: Double, second: Double) {
        let firstAlpha = Double((first.presentation() ?? first).opacity)
        let secondAlpha = Double((second.presentation() ?? second).opacity)
        return (firstAlpha, secondAlpha)
    }

    // 自检用：仍在淡出的旧句替身此刻呈现出的不透明度
    func presentedGhostAlphas() -> [Double] {
        ghosts.map { Double(($0.presentation() ?? $0).opacity) }
    }

    override func layout() {
        super.layout()
        reflow()
    }

    // 按当前尺寸重新摆好两层文字。只动自己的图层，不去触碰视图树：
    // 在 SwiftUI 更新过程中再触发一次子树布局会撞上 AppKit 的递归检查
    private func reflow() {
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
        // 空文字时没有字形可取，attributes(at: 0) 会抛越界异常，这里回退到当前字号
        let fontSize = textAttributes.length > 0
            ? (textAttributes.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont)?.pointSize ?? textFont.pointSize
            : textFont.pointSize
        for textLayer in [first, second] {
            textLayer.contentsScale = scale
            textLayer.rasterizationScale = scale
            textLayer.bounds = CGRect(x: 0, y: 0, width: textWidth, height: height)
            textLayer.fontSize = fontSize
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
        // 淡入放在走马灯重启之后：重启会清掉这两层上的动画，之前挂上去的淡入会被一并抹掉
        if pendingFadeIn {
            pendingFadeIn = false
            fadeInText()
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
        // 位移只取设备像素的整数倍：文字每一帧都落在像素网格上，
        // 于是字形的成形方式与静止时相同，不会因为亚像素位移被重新取样而变淡或变糊。
        // 文字速度远低于刷新率（26 点/秒 对 120 帧/秒），按帧取样会产生大量重复位置，
        // 这里改为每跨过一个设备像素取一个关键帧
        let quantum = 1 / (window?.backingScaleFactor ?? 2)
        let steps = max(2, Int((distance / quantum).rounded()))
        var offsets: [CGFloat] = []
        var keyTimes: [NSNumber] = []
        for step in 0...steps {
            offsets.append(min(distance, CGFloat(step) * quantum))
            keyTimes.append(NSNumber(value: Double(step) / Double(steps)))
        }
        for textLayer in [first, second] {
            let base = textLayer === first ? 0 : distance
            textLayer.removeAllAnimations()
            let animation = CAKeyframeAnimation(keyPath: "position.x")
            animation.values = offsets.map { base - $0 }
            animation.keyTimes = keyTimes
            animation.calculationMode = .discrete
            animation.duration = duration
            animation.repeatCount = .infinity
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
        MarqueeLayerView.makeCount += 1
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
