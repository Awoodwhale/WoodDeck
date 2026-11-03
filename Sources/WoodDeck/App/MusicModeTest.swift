import AppKit
import SwiftUI

// 播放模式按钮的显示自检：播放器不上报播放模式时，音乐页左下角不画播放模式，
// 播放键仍然停在整行正中；上报了播放模式的播放器，左下角出现播放模式。
@MainActor
enum MusicModeTest {
    static func run() {
        let size = CGSize(width: 520, height: 220)
        guard let hidden = render(track(canChangeMode: false), size: size, to: "mode-hidden.png"),
              let shown = render(track(canChangeMode: true), size: size, to: "mode-shown.png") else {
            print("渲染失败 ✗")
            exit(1)
        }

        guard let band = controlBand(shown, size: size) else {
            print("没有找到底部的控制条 ✗")
            exit(1)
        }
        print("整页着色像素 \(brightCount(shown, region: CGRect(origin: .zero, size: size))) 个，"
              + "控制条在第 \(Int(band.lowerBound))–\(Int(band.upperBound)) 点")

        let hiddenLeft = brightCount(hidden, region: leftRegion(band, size), threshold: 0.12)
        let shownLeft = brightCount(shown, region: leftRegion(band, size), threshold: 0.12)
        var lines = ["左下角的着色像素：不支持播放模式 \(hiddenLeft) 个，支持播放模式 \(shownLeft) 个 "
                     + (hiddenLeft == 0 && shownLeft > 40 ? "✓" : "✗")]

        let hiddenCenter = meanX(hidden, region: transportRegion(band, size))
        let shownCenter = meanX(shown, region: transportRegion(band, size))
        let expected = size.width / 2
        lines.append(String(format: "播放键的水平中心：不支持 %.1f 点，支持 %.1f 点，理想值 %.1f 点（相差 %.1f 点）",
                            hiddenCenter, shownCenter, expected, abs(hiddenCenter - shownCenter))
                     + (abs(hiddenCenter - shownCenter) < 1 ? " ✓" : " ✗"))

        for line in lines { print(line) }
        if lines.contains(where: { $0.hasSuffix("✗") }) { exit(1) }
    }

    private static func track(canChangeMode: Bool) -> MusicDisplay {
        var music = MusicDisplay()
        music.available = true
        music.playing = true
        music.title = "自检歌曲"
        music.artist = "自检歌手"
        music.album = "自检专辑"
        music.duration = 220
        music.position = 30
        music.positionStamp = Date()
        music.canToggle = true
        music.canPrevious = true
        music.canNext = true
        music.canSeek = true
        music.canShuffle = canChangeMode
        music.canRepeat = canChangeMode
        music.shuffle = false
        music.repeatMode = 1
        music.sourceName = "自检"
        music.currentLyric = "当前这一句歌词"
        music.nextLyric = "下一句歌词"
        music.previousLyric = "上一句歌词"
        return music
    }

    // 找最下面一段有内容的横条，也就是播放控制所在的那一行
    private static func controlBand(_ rep: NSBitmapImageRep, size: CGSize) -> ClosedRange<CGFloat>? {
        let scale = Double(rep.pixelsHigh) / Double(size.height)
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?
        for row in 0..<rep.pixelsHigh {
            let from = Int(Double(size.width) * 0.3 * scale)
            let to = Int(Double(size.width) * 0.7 * scale)
            var found = false
            for column in from..<to where bright(rep, column, row) {
                found = true
                break
            }
            if found, start == nil { start = row }
            if !found, let began = start {
                runs.append(CGFloat(began) / scale...CGFloat(row) / scale)
                start = nil
            }
        }
        if let began = start {
            runs.append(CGFloat(began) / scale...CGFloat(rep.pixelsHigh) / scale)
        }
        // 跳过太矮的横线，取最靠下的那一段
        return runs.filter { $0.upperBound - $0.lowerBound >= 6 }.last
    }

    private static func leftRegion(_ band: ClosedRange<CGFloat>, _ size: CGSize) -> CGRect {
        CGRect(x: 0, y: band.lowerBound - 2, width: size.width * 0.3, height: band.upperBound - band.lowerBound + 4)
    }

    private static func transportRegion(_ band: ClosedRange<CGFloat>, _ size: CGSize) -> CGRect {
        CGRect(x: size.width * 0.3, y: band.lowerBound - 2,
               width: size.width * 0.4, height: band.upperBound - band.lowerBound + 4)
    }

    private static func render(_ music: MusicDisplay, size: CGSize, to name: String) -> NSBitmapImageRep? {
        let root = MusicPageView(music: music, showTranslation: false,
                                 onCommand: { _ in }, onSeek: { _ in }, onMode: {})
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.clipsToBounds = true
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.clipsToBounds = true
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        // 窗口放在主屏左下角、几乎全透明：用户看不到，但视图照常布局与绘制
        let origin = NSScreen.screens.first?.frame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: origin.x + 20, y: origin.y + 20, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.alphaValue = 0.02
        window.animationBehavior = .none
        window.ignoresMouseEvents = true
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["WOODDECK_SHOT_DIR"] {
            let url = URL(fileURLWithPath: folder).appending(path: name)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        return rep
    }

    private static func bright(_ rep: NSBitmapImageRep, _ column: Int, _ row: Int) -> Bool {
        guard let color = rep.colorAt(x: column, y: row) else { return false }
        return max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.4
    }

    private static func brightCount(_ rep: NSBitmapImageRep, region: CGRect, threshold: Double = 0.4) -> Int {
        var total = 0
        eachPixel(rep, region: region) { if $0 > threshold { total += 1 } }
        return total
    }

    private static func meanX(_ rep: NSBitmapImageRep, region: CGRect) -> Double {
        let scale = Double(rep.pixelsWide) / Double(rep.size.width)
        var weighted = 0.0
        var weight = 0.0
        for row in Int(region.minY * scale)..<Int(region.maxY * scale) {
            for column in Int(region.minX * scale)..<Int(region.maxX * scale) {
                guard let color = rep.colorAt(x: column, y: row) else { continue }
                let brightness = Double(max(color.redComponent, max(color.greenComponent, color.blueComponent)))
                if brightness > 0.4 {
                    weighted += Double(column) / scale * brightness
                    weight += brightness
                }
            }
        }
        return weight > 0 ? weighted / weight : -1
    }

    private static func eachPixel(_ rep: NSBitmapImageRep, region: CGRect, _ body: (Double) -> Void) {
        let scale = Double(rep.pixelsWide) / Double(rep.size.width)
        for row in Int(region.minY * scale)..<Int(region.maxY * scale) {
            for column in Int(region.minX * scale)..<Int(region.maxX * scale) {
                guard let color = rep.colorAt(x: column, y: row) else { continue }
                body(Double(max(color.redComponent, max(color.greenComponent, color.blueComponent))))
            }
        }
    }
}
