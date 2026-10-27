import SwiftUI

// 刘海形状：顶部与屏幕边缘相接，两侧有与边缘过渡的肩部，底部圆角
struct NotchShape: Shape {
    var bottomRadius: CGFloat = CollapsedLimits.notchCorner
    var shoulder: CGFloat = CollapsedLimits.notchShoulder

    func path(in rect: CGRect) -> Path {
        let radius = min(bottomRadius, rect.height / 2, rect.width / 2)
        let shoulderRadius = min(shoulder, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + shoulderRadius, y: rect.minY + shoulderRadius),
                          control: CGPoint(x: rect.minX + shoulderRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + shoulderRadius, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + shoulderRadius + radius, y: rect.maxY),
                          control: CGPoint(x: rect.minX + shoulderRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - shoulderRadius - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - shoulderRadius, y: rect.maxY - radius),
                          control: CGPoint(x: rect.maxX - shoulderRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - shoulderRadius, y: rect.minY + shoulderRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - shoulderRadius, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// 配额环：细圆环显示已用比例
struct QuotaRing: View {
    var percent: Double
    var color: Color
    var thickness: CGFloat = 2.4
    var diameter: CGFloat = 18
    var dimmed: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.14), lineWidth: thickness)
            Circle()
                .trim(from: 0, to: min(max(percent / 100, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .opacity(dimmed ? 0.35 : 1)
    }
}

struct CompactIslandView: View {
    var content: CompactContent
    // 主题作为显式入参参与视图值。切换配色时内容可以完全没变，
    // 视图值没有差别就会被跳过重算，颜色要等到下一次内容变化才更新
    var themeID: String = Theme.palette.id
    var onTap: () -> Void = {}

    private var palette: PanelPalette { PanelThemeCatalog.palette(id: themeID) }
    private var scale: CGFloat { CGFloat(min(max(content.scale, 0.75), 2)) }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            contentBody(size: size)
                .frame(width: size.width, height: size.height)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    @ViewBuilder
    private func contentBody(size: CGSize) -> some View {
        switch content.style {
        case .line:
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                if let progress = content.lineProgress {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(content.rings.first?.color ?? .white)
                            .frame(width: max(2, proxy.size.width * min(max(progress, 0), 1)))
                    }
                } else if let ring = content.rings.first {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(ring.color)
                            .frame(width: max(2, proxy.size.width * min(max(ring.percent / 100, 0), 1)))
                    }
                }
            }
            .clipShape(Capsule())
        case .notch:
            if content.splitLeft > 0 {
                splitBody(size: size)
            } else {
                ZStack {
                    NotchShape()
                        .fill(palette.surfaceColor)
                    VStack(spacing: 0) {
                        Spacer(minLength: content.contentTopPadding)
                        row(size: size)
                    }
                    .padding(.horizontal, CollapsedLimits.notchInset * scale)
                }
            }
        case .capsule:
            ZStack {
                Capsule().fill(palette.surfaceColor)
                row(size: size)
                    .padding(.top, content.contentTopPadding)
                    .padding(.horizontal, CollapsedLimits.capsuleInset * scale)
            }
        }
    }

    // 分列刘海两侧：左段放音乐，右段放额度与会话，中间让开摄像头
    @ViewBuilder
    private func splitBody(size: CGSize) -> some View {
        ZStack {
            SplitNotchShape(bottomRadius: Theme.splitCorner)
                .fill(palette.surfaceColor)
            HStack(spacing: 0) {
                splitSegment(width: content.splitLeft, alignment: .trailing, isLeft: true)
                Color.clear.frame(width: content.splitNotch)
                splitSegment(width: content.splitRight, alignment: .leading, isLeft: false)
            }
        }
    }

    @ViewBuilder
    private func splitSegment(width: CGFloat, alignment: HorizontalAlignment, isLeft: Bool) -> some View {
        VStack(alignment: isLeft ? .trailing : .leading, spacing: 0) {
            // 左侧只放音乐内容，不再占用一行显示「音乐」角标，把高度留给文字
            if !isLeft, let tag = content.rightTag {
                Text(tag)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.32))
                    .padding(.top, 1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if isLeft {
                    musicSegmentContent
                } else {
                    quotaSegmentContent
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, isLeft ? 12 : 10)
        .padding(.vertical, isLeft ? 0 : 1)
        .frame(width: width, alignment: isLeft ? .trailing : .leading)
        .clipped()
    }

    // 分列布局的左侧放大系数：刘海本身有 32pt 高，字号比收起形态的默认值再大一档
    private var splitMusicScale: CGFloat {
        max(1.15, min(1.55, scale * 1.25))
    }

    @ViewBuilder
    private var musicSegmentContent: some View {
        if let alert = content.alertText {
            Text(alert)
                .font(.system(size: 11 * splitMusicScale, weight: .medium))
                .foregroundStyle(content.alertColor)
                .lineLimit(1)
        } else if content.musicText.isEmpty {
            Image(systemName: "music.note")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.22))
        } else {
            if let artwork = content.artwork, let image = NSImage(data: artwork) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 20 * splitMusicScale, height: 20 * splitMusicScale)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            // 放不下时先停留再匀速滚动；短句换长句时靠淡入淡出过渡，位置不跳
            LyricLineText(text: content.musicText,
                          font: .system(size: 11 * splitMusicScale, weight: .semibold),
                          color: palette.lyricColor.opacity(0.92),
                          paused: content.animating,
                          alignment: .leading,
                          nsFont: .systemFont(ofSize: 11 * splitMusicScale, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            if content.equalizer {
                EqualizerLayer(color: NSColor(content.coverTint ?? Color.white.opacity(0.75)),
                               barWidth: 2.2, height: 12,
                               playing: content.playing, paused: content.animating)
                    .frame(width: 4 * 2.2 + 3 * 2.2, height: 12)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var quotaSegmentContent: some View {
        if content.sessionBadge > 0, let agent = content.sessionAgent {
            Image(systemName: agent.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(agent.accent)
            Text("\(content.sessionBadge)")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(agent.accent)
        }
        if !content.rings.isEmpty {
            ForEach(Array(content.rings.prefix(3).enumerated()), id: \.offset) { _, ring in
                QuotaRing(percent: ring.percent, color: ring.color, thickness: 1.8, diameter: 13)
            }
        }
        if !content.clock.isEmpty {
            Text(content.clock)
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(content.clockColor.opacity(0.9))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func row(size: CGSize) -> some View {
        HStack(spacing: 8 * scale) {
            if let alert = content.alertText {
                Text(alert)
                    .font(.system(size: 11.5 * scale, weight: .medium))
                    .foregroundStyle(content.alertColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                if let artwork = content.artwork, let image = NSImage(data: artwork) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 20 * scale, height: 20 * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 4 * scale, style: .continuous))
                } else if content.sessionBadge > 0, let agent = content.sessionAgent {
                    SessionBadge(count: content.sessionBadge, agent: agent, scale: scale)
                } else if !content.rings.isEmpty {
                    ringCluster
                }
                if !content.musicText.isEmpty {
                    LyricLineText(text: content.musicText,
                                  font: .system(size: 11.5 * scale, weight: .medium),
                                  color: palette.lyricColor.opacity(0.86),
                                  paused: content.animating,
                                  nsFont: .systemFont(ofSize: 11.5 * scale, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if content.rings.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                }
                if content.equalizer {
                    let barWidth = 2.2 * scale
                    EqualizerLayer(color: NSColor(content.coverTint ?? Color.white.opacity(0.75)),
                                   barWidth: barWidth, height: 12 * scale,
                                   playing: content.playing, paused: content.animating)
                        .frame(width: 4 * barWidth + 3 * barWidth, height: 12 * scale)
                        .allowsHitTesting(false)
                }
                if !content.clock.isEmpty {
                    clockView
                }
                if content.monitorCpu != nil || content.monitorMemory != nil || content.monitorNetwork != nil {
                    monitorChip
                }
            }
        }
        .frame(width: size.width - 2 * inset(for: content.style) * scale, alignment: .center)
        .clipped()
    }

    // 收起形态的系统读数：CPU / 内存百分比与网络速率，读不到的项不显示
    private var monitorChip: some View {
        HStack(spacing: 4 * scale) {
            if let cpu = content.monitorCpu {
                reading(icon: "cpu", text: String(format: "%.0f%%", cpu * 100),
                        color: cpu > 0.85 ? Theme.color("#F2777F") : Color.white.opacity(0.6))
            }
            if let memory = content.monitorMemory {
                reading(icon: "memorychip", text: String(format: "%.0f%%", memory * 100),
                        color: memory > 0.9 ? Theme.color("#E5C890") : Color.white.opacity(0.6))
            }
            if let network = content.monitorNetwork {
                reading(icon: "arrow.down", text: network, color: Color.white.opacity(0.5))
            }
        }
    }

    private func reading(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 1.5 * scale) {
            Image(systemName: icon)
                .font(.system(size: 7 * scale, weight: .semibold))
                .foregroundStyle(color.opacity(0.8))
            Text(text)
                .font(.system(size: 8.5 * scale, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private func inset(for style: CompactStyle) -> CGFloat {
        style == .notch ? CollapsedLimits.notchInset : CollapsedLimits.capsuleInset
    }

    private var ringCluster: some View {
        HStack(spacing: 5 * scale) {
            ForEach(Array(content.rings.enumerated().prefix(4)), id: \.offset) { _, ring in
                QuotaRing(percent: ring.percent, color: ring.color,
                          thickness: 2.2 * scale, diameter: 18 * scale)
            }
        }
    }

    // 时间：上下样式分两行，其余单行
    private var clockView: some View {
        Group {
            if content.clockStyle == .stacked {
                let parts = content.clock.split(separator: "\n", omittingEmptySubsequences: false)
                VStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Text(String(part))
                            .font(Theme.clockFont(size: 10.5 * scale, style: content.clockStyle))
                    }
                }
                .foregroundStyle(content.clockColor)
            } else {
                Text(content.clock)
                    .font(Theme.clockFont(size: 13 * scale, style: content.clockStyle))
                    .foregroundStyle(clockTextColor)
                    .shadow(color: content.clockColor.opacity(content.clockStyle == .neon ? 0.8 : 0), radius: 4 * scale)
            }
        }
        .fixedSize()
    }

    private var clockTextColor: Color {
        switch content.clockStyle {
        case .neon: content.clockColor
        default: content.clockColor.opacity(0.95)
        }
    }
}

// 分列布局的形状：上边缘贴屏幕顶部，左右两段之间有让开摄像头的缺口，底部圆角
struct SplitNotchShape: Shape {
    var bottomRadius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let radius = min(bottomRadius, rect.height, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}


