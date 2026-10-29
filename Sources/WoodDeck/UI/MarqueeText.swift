import SwiftUI

// 走马灯文本：内容放得下就静止显示；放不下时先停留一小段，再匀速横向走完「文本宽度 + 间隔」。
// 相对开源的 SwiftUI 走马灯实现（harflabs/MarqueeText、cbpowell/MarqueeLabel）取了三点做法：
// 偏移是「从起点开始的时间」的纯函数、内容或可用宽度一变就把起点重置、位移只做 .offset 不触发布局。
struct MarqueeText: View {
    var text: String
    var font: Font
    var color: Color
    // 每秒移动的点数
    var speed: CGFloat = 26
    // 两份文本之间的间隔
    var spacing: CGFloat = 28
    // 起步前的停留时间，避免一出现就动
    var initialDelay: TimeInterval = 0.9
    // 面板动画期间暂停推进
    var paused: Bool = false
    // 文本放得下时的对齐方式：分列布局用前导对齐，短句换长句时位置不跳
    var alignment: Alignment = .leading

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    // 当前位移，由 Core Animation 在两次取值之间插值
    @State private var offset: CGFloat = 0

    private var measured: Bool { textWidth > 0 && containerWidth > 0 }
    private var overflows: Bool { measured && textWidth - containerWidth > 0.5 }
    private var shouldScroll: Bool { overflows && !paused }
    private var scrollDistance: CGFloat { textWidth + spacing }
    private var duration: TimeInterval {
        guard speed > 0 else { return 4 }
        return max(1.2, Double(scrollDistance / speed))
    }

    // 动画身份：任一项变化都从头开始走，于是新的一句先停留再滚动
    private var identity: String {
        "\(text)|\(Int(containerWidth))|\(Int(textWidth))|\(shouldScroll)|\(Int(speed))|\(Int(spacing))"
    }

    var body: some View {
        GeometryReader { proxy in
            content(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func content(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: alignment) {
            if shouldScroll {
                // 位移交给 Core Animation 插值：屏幕上按显示器刷新率平滑推进，
                // 但视图树每帧不再重新求值，CPU 占用与帧率无关
                HStack(spacing: spacing) {
                    label
                    label
                }
                .offset(x: offset)
            } else {
                label
            }
        }
        .frame(width: width, height: height, alignment: alignment)
        .clipped()
        .background(measurement)
        .onAppear {
            containerWidth = width
            restart()
        }
        .onChange(of: width) { _, value in
            containerWidth = value
            restart()
        }
        .onChange(of: identity) { _, _ in restart() }
    }

    // 先停在起点，再以线性节奏循环走完「文本宽度 + 间隔」。
    // 两份文本的间隔正好等于一次行程的终点，于是循环回头时看不出接缝
    private func restart() {
        offset = 0
        guard shouldScroll, !paused else { return }
        let distance = scrollDistance
        let duration = self.duration
        // 停留结束后再启动循环
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) {
            guard shouldScroll else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                offset = -distance
            }
        }
    }

    // 用隐藏的同一份文本量出自然宽度，避免把同样的排版算两遍
    private var measurement: some View {
        label
            .fixedSize()
            .hidden()
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { textWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, value in textWidth = value }
                        .onChange(of: text) { _, _ in textWidth = proxy.size.width }
                }
            )
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

// 歌词切换的过渡容器：文本一变就在旧句与新句之间做淡入淡出，
// 这样「短句换成长句」时不会看到位置与内容的硬切。位移由 CATextLayer 负责，按刷新率平滑且几乎不耗 CPU
struct LyricLineText: View {
    // 收起条刚换上时内容也按这个节奏淡入，与换句一致
    static let fadeDuration: Double = 0.32

    var text: String
    var font: Font
    var color: Color
    var speed: CGFloat = 26
    var paused: Bool = false
    var alignment: Alignment = .leading
    // 与 SwiftUI 字体对应的 NSFont 字号与字重
    var nsFont: NSFont = .systemFont(ofSize: 11, weight: .semibold)

    var body: some View {
        ZStack(alignment: alignment) {
            MarqueeLayer(text: text,
                         font: nsFont,
                         color: NSColor(color),
                         speed: speed,
                         paused: paused)
                .id(text)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: Self.fadeDuration), value: text)
    }
}
