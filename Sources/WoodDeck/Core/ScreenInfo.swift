import AppKit
import CoreGraphics

// 一块屏幕的对外信息，供设置里的显示屏选择使用
struct ScreenInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var width: Double
    var height: Double
    var isMain: Bool
    var hasNotch: Bool
}

enum ScreenCatalog {
    static func current() -> [ScreenInfo] {
        NSScreen.screens.map { screen in
            ScreenInfo(id: identifier(of: screen),
                       name: screen.localizedName,
                       width: screen.frame.width,
                       height: screen.frame.height,
                       isMain: screen == NSScreen.screens.first,
                       hasNotch: ScreenMetrics.of(screen).hasNotch)
        }
    }

    static func identifier(of screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return String(number.uint32Value)
        }
        return screen.localizedName
    }

    static func screen(matching id: String) -> NSScreen? {
        guard !id.isEmpty else { return nil }
        return NSScreen.screens.first { identifier(of: $0) == id }
    }

    // 按设置挑出面板要显示的那块屏幕。系统主显示屏是带菜单栏的那一块，也就是 screens 的第一块
    static func target(for settings: DeckSettings) -> NSScreen? {
        let main = NSScreen.screens.first
        switch settings.displayMode {
        case .main:
            return main
        case .active:
            let point = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? main
        case .specific:
            return screen(matching: settings.displayID) ?? main
        }
    }
}

// 刘海与安全区域：MacBook Pro 的摄像头区域没有像素，内容必须让开
struct ScreenMetrics {
    var hasNotch: Bool = false
    // 刘海（摄像头区域）的高度，等于顶部安全区域
    var notchHeight: CGFloat = 0
    var notchWidth: CGFloat = 0

    // 查询 NSScreen 的辅助区域与安全边距较慢（单次约 50 微秒），
    // 60Hz 的指针轮询里不能每次都问，按屏幕身份与尺寸缓存
    private static var cache: [String: ScreenMetrics] = [:]

    static func invalidateCache() {
        cache.removeAll()
    }

    private static func cacheKey(_ screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        return "\(number)-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    static func of(_ screen: NSScreen?) -> ScreenMetrics {
        guard let screen else { return ScreenMetrics() }
        let key = cacheKey(screen)
        if let cached = cache[key] { return cached }
        let computed = compute(screen)
        cache[key] = computed
        return computed
    }

    private static func compute(_ screen: NSScreen) -> ScreenMetrics {
        var metrics = ScreenMetrics()
        metrics.notchHeight = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        if let left, let right {
            metrics.hasNotch = true
            metrics.notchWidth = max(0, screen.frame.width - left.width - right.width)
        } else if metrics.notchHeight > 0 {
            metrics.hasNotch = true
            metrics.notchWidth = screen.frame.width * 0.12
        }
        if !metrics.hasNotch {
            metrics.notchHeight = 0
            metrics.notchWidth = 0
        }
        return metrics
    }
}
