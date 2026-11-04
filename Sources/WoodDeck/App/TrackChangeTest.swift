import AppKit
import SwiftUI

// 切歌过程的诊断：把「新曲目事件到得很早、封面与歌词晚一步」这条真实序列喂进模型，
// 逐步截取收起形态与展开面板，数出画面上还有多少内容。
// 如果中途画面突然变空再变满，那一瞬就是换歌时看到的闪动
enum TrackChangeTest {
    @MainActor
    static func run() {
        guard let first = imageData(path: "docs/icon.png") else {
            print("—— 切歌闪动：docs 目录下没有可用的封面图片，这次跳过 ✗")
            return
        }
        let model = DeckModel.shared
        let settings = SettingsStore.shared.settings
        // 换歌时歌词会先清空再联网查；自检不需要真的去查，只复现「清空」这一段
        DeckModel.suppressLyricsFetch = true

        // 第一首：封面与歌词都齐全
        model.applyNowPlayingForTest(track(title: "上一首自检曲目",
                                           artist: "WoodDeck",
                                           duration: 240,
                                           artwork: first,
                                           identifier: "self-old"))
        model.seedLyricsForTest([LyricLine(time: 0, text: "上一首的歌词第一句")],
                                current: "上一首的歌词第一句",
                                next: "上一首的歌词第二句")
        settle()
        let start = snapshot(model: model, settings: settings, note: "第一首（封面与歌词齐全）")

        // 换歌那一条事件：新曲目的名字到了，封面与歌词还没到
        model.applyNowPlayingForTest(track(title: "下一首自检曲目",
                                           artist: "WoodDeck",
                                           duration: 180,
                                           artwork: nil,
                                           identifier: "self-new"))
        settle()
        let midway = snapshot(model: model, settings: settings, note: "换歌事件到达（封面与歌词还没到）")

        // 封面与歌词补齐
        model.applyNowPlayingForTest(track(title: "下一首自检曲目",
                                           artist: "WoodDeck",
                                           duration: 180,
                                           artwork: first,
                                           identifier: "self-new"))
        model.seedLyricsForTest([LyricLine(time: 0, text: "下一首的歌词第一句")],
                                current: "下一首的歌词第一句",
                                next: "下一首的歌词第二句")
        settle()
        let end = snapshot(model: model, settings: settings, note: "封面与歌词补齐")

        print("—— 切歌过程里画面内容的变化（内容像素个数，越接近 0 越接近空画面）")
        report(name: "收起形态", start: start.compact, midway: midway.compact, end: end.compact)
        report(name: "展开面板", start: start.expanded, midway: midway.expanded, end: end.expanded)
        identifierReport(model: model, artwork: first)
    }

    // 系统会给同一首歌报出不同的曲目标识，图还是同一张：这时界面不该换图
    @MainActor
    private static func identifierReport(model: DeckModel, artwork: Data) {
        print("—— 同一张封面换了曲目标识")
        let tokenBefore = model.music.artworkToken
        model.applyNowPlayingForTest(track(title: "下一首自检曲目",
                                           artist: "WoodDeck",
                                           duration: 180,
                                           artwork: artwork,
                                           identifier: "self-new-again"))
        settle()
        let tokenAfter = model.music.artworkToken
        print("  换标识前的标识：\(tokenBefore.isEmpty ? "（空）" : tokenBefore)")
        print("  换标识后的标识：\(tokenAfter.isEmpty ? "（空）" : tokenAfter)")
        print("  同一张图没有触发换图：\(tokenAfter == tokenBefore ? "是 ✓" : "否 ✗")")

        guard let other = imageData(path: "docs/themes.png") else { return }
        model.applyNowPlayingForTest(track(title: "下一首自检曲目",
                                           artist: "WoodDeck",
                                           duration: 180,
                                           artwork: other,
                                           identifier: "self-new-again"))
        settle()
        print("  换了一张新图后的标识：\(model.music.artworkToken.isEmpty ? "（空）" : model.music.artworkToken)")
        print("  换新图会触发换图：\(model.music.artworkToken != tokenAfter ? "是 ✓" : "否 ✗")")
    }

    private struct Snapshot {
        var compact: Int
        var expanded: Int
        var note: String
    }

    @MainActor
    private static func snapshot(model: DeckModel, settings: DeckSettings, note: String) -> Snapshot {
        var content = model.compactContent()
        content.style = .capsule
        content.splitLeft = 0
        content.splitNotch = 0
        content.splitRight = 0
        content.alertText = nil
        print("    [\(note)] 曲目=\(model.music.title) 封面=\(model.music.artwork?.count ?? 0) 字节 " +
              "标识=\(model.music.artworkToken) 歌词=\(model.music.lyrics.count) 行 当前句=\(model.music.currentLyric)")
        let compactSize = CGSize(width: max(240, settings.capsuleWidth), height: 32)
        let panelSize = CGSize(width: CGFloat(settings.width), height: CGFloat(settings.height))
        let compact = ink(of: AnyView(CompactIslandView(content: content, themeID: settings.panelTheme, onTap: {})),
                          size: compactSize,
                          fill: PanelThemeCatalog.palette(id: settings.panelTheme).surfaceColor)
        let expanded = ink(of: AnyView(MusicPageView(music: model.music,
                                                    showTranslation: true,
                                                    onCommand: { _ in },
                                                    onSeek: { _ in },
                                                    onMode: {})),
                           size: panelSize,
                           fill: PanelThemeCatalog.palette(id: settings.panelTheme).panelColor)
        return Snapshot(compact: compact, expanded: expanded, note: note)
    }

    private static func report(name: String, start: Int, midway: Int, end: Int) {
        let dip = start > 0 ? Double(midway) / Double(start) : 1
        print(String(format: "  %@：第一首 %d → 换歌瞬间 %d → 补齐 %d（换歌瞬间是前一状态的 %.0f%%）",
                     name, start, midway, end, dip * 100))
        let verdict = (midway > 0 && Double(midway) / Double(max(start, 1)) > 0.7) ? " ✓" : " ✗"
        print("  \(name)换歌时没有掉成空画面：\(verdict)")
    }

    // 内容像素：与面板底色有明显差别的像素
    @MainActor
    private static func ink(of view: AnyView, size: CGSize, fill: Color) -> Int {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.clipsToBounds = true
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.clipsToBounds = true
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        // 窗口放在主屏左下角、几乎全透明：用户看不到，但窗口在屏幕上，视图照常布局
        let origin = NSScreen.screens.first?.frame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: origin.x + 20, y: origin.y + 20, width: size.width, height: size.height),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
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
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let base = NSColor(fill).usingColorSpace(.sRGB) ?? NSColor.black
        var count = 0
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.4 {
                    let delta = max(abs(pixel.redComponent - base.redComponent),
                                    max(abs(pixel.greenComponent - base.greenComponent),
                                        abs(pixel.blueComponent - base.blueComponent)))
                    if delta > 0.06 { count += 1 }
                }
                x += 2
            }
            y += 2
        }
        return count
    }

    private static func settle() {
        // 覆盖淡入时长（0.34 秒），否则量到的是交叉淡入的中途
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    }

    private static func track(title: String,
                              artist: String,
                              duration: Double,
                              artwork: Data?,
                              identifier: String) -> NowPlaying {
        NowPlaying(bundleIdentifier: "com.netease.163music",
                   title: title,
                   artist: artist,
                   album: "自检专辑",
                   duration: duration,
                   elapsed: 0,
                   timestamp: Date(),
                   rate: 1,
                   playing: true,
                   artwork: artwork,
                   uniqueIdentifier: identifier,
                   shuffleMode: nil,
                   repeatMode: nil,
                   supportsLiked: false,
                   liked: false)
    }

    private static func imageData(path: String) -> Data? {
        let url = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: path)
        return try? Data(contentsOf: url)
    }
}
