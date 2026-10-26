import SwiftUI
import AppKit

enum Theme {
    static let cornerRadius: CGFloat = 22
    static let compactCorner: CGFloat = 14
    static let splitCorner: CGFloat = 14
    static let panelPadding: CGFloat = 16
    static let columnSpacing: CGFloat = 12

    static func color(_ hex: String, fallback: Color = .gray) -> Color {
        guard AppPresets.isColor(hex) else { return fallback }
        return Color(nsColor: nsColor(hex))
    }

    static func nsColor(_ hex: String, fallback: NSColor = .gray) -> NSColor {
        guard AppPresets.isColor(hex), let value = UInt32(hex.dropFirst(), radix: 16) else { return fallback }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }

    static func quotaColor(_ entry: AppEntry, percent: Double) -> Color {
        color(AppPresets.quotaColor(entry, percent: percent))
    }

    // 当前主题：颜色随设置变化，界面统一从这里取
    @MainActor
    static var palette: PanelPalette { PanelThemeCatalog.palette(id: SettingsStore.shared.settings.panelTheme) }

    // 收起形态的底色：不透明的深色，避免透过桌面元素
    @MainActor
    static var compactFill: Color { palette.surfaceColor }
    @MainActor
    static var compactStroke: Color { palette.strokeColor }

    // 三级文字色：面板里的文字统一用这三个，跟随主题
    @MainActor
    static var textPrimary: Color { palette.primaryText }
    @MainActor
    static var textSecondary: Color { palette.secondaryText }
    @MainActor
    static var textTertiary: Color { palette.tertiaryText }
    @MainActor
    static var accent: Color { palette.accentColor }
    @MainActor
    static var cardFill: Color { palette.cardColor }

    static func appearance(_ theme: SettingsTheme) -> NSAppearance? {
        switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    // 时间文字使用的等宽数字字体
    static func clockFont(size: CGFloat, style: ClockStyle) -> Font {
        switch style {
        case .serif: .system(size: size, weight: .medium, design: .serif).monospacedDigit()
        case .wide: .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
        case .condensed: .system(size: size, weight: .medium).monospacedDigit().width(.condensed)
        case .neon: .system(size: size, weight: .heavy, design: .rounded).monospacedDigit()
        case .dots: .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
        case .segment: .system(size: size, weight: .heavy).monospacedDigit()
        case .digits: .system(size: size, weight: .bold, design: .monospaced)
        default: .system(size: size, weight: .medium).monospacedDigit()
        }
    }
}

extension Notification.Name {
    static let deckSettingsChanged = Notification.Name("BrimDeckSettingsChanged")
}

// 收起形态的尺寸与位置计算
struct CompactGeometry {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    // 形状上边缘与屏幕顶部的距离
    var topInset: CGFloat
    // 内容需要让开的顶部空间：有刘海时等于摄像头区域的高度
    var contentTopPadding: CGFloat
    // 分列布局时每侧的宽度与中间让开的刘海宽度；为 0 表示不做分列
    // 分列布局：左右两段各自的宽度，以及中间让开的刘海宽度
    var splitLeft: CGFloat = 0
    var splitRight: CGFloat = 0
    var splitNotch: CGFloat = 0

    static func compact(_ settings: DeckSettings, style: CompactStyle, metrics: ScreenMetrics = ScreenMetrics()) -> CompactGeometry {
        switch style {
        case .notch:
            if metrics.hasNotch, settings.notchLayout == .split {
                // 分列刘海两侧：形状与刘海同高，左段放音乐（更宽），右段放额度与会话
                let left = max(settings.notchLeftWidth, 72)
                let right = max(settings.notchRightWidth, 56)
                let width = metrics.notchWidth + left + right
                return CompactGeometry(width: width, height: metrics.notchHeight,
                                       cornerRadius: metrics.notchHeight / 2, topInset: 0, contentTopPadding: 0,
                                       splitLeft: left, splitRight: right, splitNotch: metrics.notchWidth)
            }
            if metrics.hasNotch {
                // 有刘海时形状从屏幕顶部向下延伸：上半是摄像头区域，内容放在下面这条带子里
                let band = max(settings.notchHeight, 22)
                let width = max(settings.notchWidth, metrics.notchWidth + 16)
                return CompactGeometry(width: width, height: metrics.notchHeight + band,
                                       cornerRadius: 14, topInset: 0, contentTopPadding: metrics.notchHeight)
            }
            // 没有刘海可让位时，不再按刘海尺寸挤成一条窄带：改成落在顶部下方的胶囊形状，
            // 宽度取「胶囊宽度 + 配额环 + 时间」的实际需要，保证歌词、额度环与时间都能显示
            let ringCount = CGFloat(settings.configuredApps.count)
            let ringsWidth: CGFloat = settings.showQuota && ringCount > 0 ? 18 * min(4, ringCount) + 5 * (min(4, ringCount) - 1) + 8 : 0
            let clockWidth: CGFloat = settings.showClock ? 46 : 0
            let contentWidth = settings.capsuleWidth + ringsWidth + clockWidth
            return CompactGeometry(width: max(settings.notchWidth, contentWidth), height: settings.capsuleHeight,
                                   cornerRadius: settings.capsuleHeight / 2,
                                   topInset: metrics.notchHeight + settings.capsuleTop,
                                   contentTopPadding: 0)
        case .capsule:
            // 胶囊始终落在刘海下方，避免被摄像头区域挡住
            let top = metrics.notchHeight + settings.capsuleTop
            return CompactGeometry(width: settings.capsuleWidth, height: settings.capsuleHeight,
                                   cornerRadius: settings.capsuleHeight / 2, topInset: top, contentTopPadding: 0)
        case .line:
            let top = metrics.notchHeight + settings.lineTop
            return CompactGeometry(width: settings.lineLength, height: settings.lineThickness,
                                   cornerRadius: settings.lineThickness / 2, topInset: top, contentTopPadding: 0)
        }
    }

    static func offsetX(_ settings: DeckSettings, style: CompactStyle) -> CGFloat {
        switch style {
        case .notch: settings.notchOffsetX
        case .capsule: settings.capsuleOffsetX
        case .line: settings.lineOffsetX
        }
    }
}
