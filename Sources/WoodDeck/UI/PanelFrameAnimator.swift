import AppKit
import QuartzCore

// 面板尺寸动画：按显示器刷新节拍逐帧改窗口矩形。
// AppKit 自带的 window.animator() 用固定节拍的定时器驱动，120 Hz 屏幕上每两帧才动一次，
// 收尾处还会出现上百毫秒不动的停顿，时长也会超出设定值
@MainActor
final class PanelFrameAnimator {
    private weak var window: NSWindow?
    private var link: CADisplayLink?
    private var from = NSRect.zero
    private var to = NSRect.zero
    private var startTime: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var completion: (() -> Void)?
    private let curve: UnitBezier

    // 与原先 CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1) 同一条曲线
    init(window: NSWindow, controlPoints: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.22, 1, 0.36, 1)) {
        self.window = window
        curve = UnitBezier(x1: controlPoints.0, y1: controlPoints.1, x2: controlPoints.2, y2: controlPoints.3)
    }

    var isRunning: Bool { link != nil }

    var target: NSRect? { link == nil ? nil : to }

    func animate(to target: NSRect, duration: TimeInterval, completion: @escaping () -> Void) {
        guard let window, let host = window.contentView, duration > 0 else {
            window?.setFrame(target, display: true)
            completion()
            return
        }
        stop()
        from = window.frame
        to = target
        self.duration = duration
        self.completion = completion
        startTime = CACurrentMediaTime()
        let link = host.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    // 中途被打断：停掉节拍，当前位置就是新动画的起点
    func stop() {
        link?.invalidate()
        link = nil
        completion = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let window else {
            finish()
            return
        }
        let elapsed = CACurrentMediaTime() - startTime
        let progress = min(1, max(0, elapsed / duration))
        let eased = curve.value(for: progress)
        let next = interpolated(eased)
        // 这条缓动曲线尾段只剩不到半个点的位移，继续等只是让面板停在原地占着动画状态
        if progress >= 1 || settled(next) {
            window.setFrame(to, display: true)
            finish()
            return
        }
        window.setFrame(next, display: true)
    }

    private func settled(_ rect: NSRect) -> Bool {
        abs(rect.minX - to.minX) < 0.5
            && abs(rect.minY - to.minY) < 0.5
            && abs(rect.width - to.width) < 0.5
            && abs(rect.height - to.height) < 0.5
    }

    private func interpolated(_ t: CGFloat) -> NSRect {
        NSRect(x: from.minX + (to.minX - from.minX) * t,
               y: from.minY + (to.minY - from.minY) * t,
               width: from.width + (to.width - from.width) * t,
               height: from.height + (to.height - from.height) * t)
    }

    private func finish() {
        link?.invalidate()
        link = nil
        let done = completion
        completion = nil
        done?()
    }
}

// 三次贝塞尔的进度曲线：给定时间比例求位移比例
struct UnitBezier {
    private let ax: CGFloat
    private let bx: CGFloat
    private let cx: CGFloat
    private let ay: CGFloat
    private let by: CGFloat
    private let cy: CGFloat

    init(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) {
        cx = 3 * x1
        bx = 3 * (x2 - x1) - cx
        ax = 1 - cx - bx
        cy = 3 * y1
        by = 3 * (y2 - y1) - cy
        ay = 1 - cy - by
    }

    private func sampleX(_ t: CGFloat) -> CGFloat { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: CGFloat) -> CGFloat { ((ay * t + by) * t + cy) * t }
    private func slopeX(_ t: CGFloat) -> CGFloat { (3 * ax * t + 2 * bx) * t + cx }

    func value(for progress: CGFloat) -> CGFloat {
        sampleY(solveX(progress))
    }

    // 牛顿迭代求 t，落不进精度就退回二分
    private func solveX(_ x: CGFloat) -> CGFloat {
        var t = x
        for _ in 0..<8 {
            let error = sampleX(t) - x
            if abs(error) < 1e-5 { return t }
            let slope = slopeX(t)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var low: CGFloat = 0
        var high: CGFloat = 1
        t = x
        while low < high {
            let value = sampleX(t)
            if abs(value - x) < 1e-5 { return t }
            if x > value { low = t } else { high = t }
            let next = (high - low) / 2 + low
            if abs(next - t) < 1e-6 { break }
            t = next
        }
        return t
    }
}
