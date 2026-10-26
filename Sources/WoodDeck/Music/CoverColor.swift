import AppKit
import SwiftUI

// 从封面图取主色：跳过接近黑白与过暗的像素，取剩下的平均色
enum CoverColor {
    static func tint(from data: Data) -> Color? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return nil }
        let stepX = max(1, width / 24)
        let stepY = max(1, height / 24)
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0.0
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = color.redComponent
                let g = color.greenComponent
                let b = color.blueComponent
                let maximum = max(r, max(g, b))
                let minimum = min(r, min(g, b))
                // 过暗或几乎无饱和度的像素对主色没有帮助
                guard maximum > 0.18, maximum - minimum > 0.08 else { continue }
                red += r
                green += g
                blue += b
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let average = (red / count, green / count, blue / count)
        // 抬一点亮度，深色封面也能看清
        let lift = 0.25
        func boost(_ value: Double) -> Double {
            min(1, value * (1 - lift) + lift)
        }
        return Color(red: boost(average.0), green: boost(average.1), blue: boost(average.2))
    }
}
