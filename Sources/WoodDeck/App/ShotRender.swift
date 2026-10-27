import AppKit
import SwiftUI

// 生成文档用的界面截图：把视图放进离屏窗口真实排版后取位图。
// ImageRenderer 无法渲染走马灯与律动条这类 CALayer 内容，会画成占位图形，所以不能用它
@MainActor
enum ShotRender {
    static func run(directory: String) {
        let folder = URL(filePath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let model = DeckModel.shared
        model.start()
        SystemMonitorModel.shared.start(includeProcesses: true, interval: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(7))

        let content = model.compactContent()
        // 尺寸取默认值，截图展示的是出厂样子；内容仍是本机的真实数据
        var shotSettings = DeckSettings()
        // 没有连接额度来源时右侧只有时间，打开它截图才看得出两段各有内容
        shotSettings.showClock = true

        collapsed(content: content, settings: shotSettings, style: .notch, to: folder.appending(path: "closed.png"))
        collapsed(content: content, settings: shotSettings, style: .capsule, to: folder.appending(path: "capsule.png"))
        panel(model: model, page: .music, size: CGSize(width: 520, height: 260), to: folder.appending(path: "panel-music.png"))
        monitor(to: folder.appending(path: "monitor.png"))
        settingsShot(.general, size: CGSize(width: 800, height: 660), to: folder.appending(path: "settings-general.png"))
        settingsShot(.sessions, size: CGSize(width: 800, height: 1150), to: folder.appending(path: "settings-sessions.png"))
        settingsShot(.appearance, size: CGSize(width: 800, height: 1240), to: folder.appending(path: "settings-appearance.png"))
        settingsShot(.music, size: CGSize(width: 800, height: 900), to: folder.appending(path: "settings-music.png"))
        agentSheet(.dsh, to: folder.appending(path: "agent-dsh.png"))
        themes(content: content, settings: shotSettings, to: folder.appending(path: "themes.png"))
        print("截图目录：\(folder.path(percentEncoded: false))")
    }

    private struct CollapsedShot: View {
        var content: CompactContent
        var size: CGSize
        var topInset: CGFloat

        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.19), Color(white: 0.06)],
                               startPoint: .top,
                               endPoint: .bottom)
                CompactIslandView(content: content)
                    .frame(width: size.width, height: size.height)
                    .padding(.top, topInset)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    // 收起形态按设置算出真实尺寸，刘海分列时中间的空隙就是摄像头区域
    private static func collapsed(content: CompactContent, settings: DeckSettings, style: CompactStyle, to url: URL) {
        let metrics = ScreenMetrics.of(NSScreen.screens.first)
        let geometry = CompactGeometry.compact(settings, style: style, metrics: metrics)
        // 分列宽度跟着这张截图的设置走，不沿用本机设置算出的旧值
        var shotContent = content
        shotContent.style = style
        shotContent.scale = Double(geometry.height) / CollapsedLimits.baseHeight
        shotContent.contentTopPadding = geometry.contentTopPadding
        shotContent.splitLeft = geometry.splitLeft
        shotContent.splitRight = geometry.splitRight
        shotContent.splitNotch = geometry.splitNotch
        if shotContent.clock.isEmpty, settings.showsClockContent(style) {
            shotContent.clock = TimeFormatting.clock(Date(), hour24: settings.clock24Hour, style: settings.clockStyle)
        }

        let canvas = CGSize(width: geometry.width + 120, height: 150)
        let view = CollapsedShot(content: shotContent,
                                 size: CGSize(width: geometry.width, height: geometry.height),
                                 topInset: 30)
            .frame(width: canvas.width, height: canvas.height)
        save(view, size: canvas, to: url)
    }

    private static func panel(model: DeckModel, page: DeckPage, size: CGSize, to url: URL) {
        let view = ExpandedPanelView(settings: model.settings,
                                     columns: model.columns,
                                     music: model.music,
                                     page: page,
                                     refreshing: false,
                                     lastRefresh: Date(),
                                     onPageChange: { _ in },
                                     onRefresh: {},
                                     onSettings: {},
                                     onMusicCommand: { _ in },
                                     onSeek: { _ in },
                                     onMode: {},
                                     onDetails: { _, _ in },
                                     pages: [.quota, .sessions, .music, .monitor])
            .frame(width: size.width, height: size.height)
            .padding(18)
            .background(Color(white: 0.10))
        save(view, size: CGSize(width: size.width + 36, height: size.height + 36), to: url)
    }

    private static func monitor(to url: URL) {
        let size = CGSize(width: 520, height: 130)
        let view = MonitorPageView(monitor: SystemMonitorModel.shared)
            .frame(width: size.width, height: size.height)
            .background(Color(white: 0.06))
        save(view, size: size, to: url)
    }

    private static func settingsShot(_ section: SettingsSection, size: CGSize, to url: URL) {
        let view = SettingsView(initialSection: section, showsSidebar: false)
            .environmentObject(DeckModel.shared)
            .frame(width: size.width, height: size.height)
        save(view, size: size, to: url)
    }

    private static func agentSheet(_ agent: AgentKind, to url: URL) {
        let view = AgentConfigSheet(agent: agent)
            .environmentObject(DeckModel.shared)
        save(view, size: CGSize(width: 540, height: 460), to: url)
    }

    // 六套配色排成一列，同一条收起形态内容，便于对照底色与歌词色。
    // 配色是全局设置，逐套切换后各自截一张条子，再画进同一张图
    private static func themes(content: CompactContent, settings: DeckSettings, to url: URL) {
        let metrics = ScreenMetrics.of(NSScreen.screens.first)
        let geometry = CompactGeometry.compact(settings, style: .notch, metrics: metrics)
        let original = settings.panelTheme
        let labelWidth: CGFloat = 92
        let leading: CGFloat = 16
        let rowHeight: CGFloat = 62
        let islandSize = CGSize(width: geometry.width, height: geometry.height)
        let size = CGSize(width: leading * 2 + labelWidth + 16 + islandSize.width,
                          height: rowHeight * CGFloat(PanelThemeCatalog.all.count) + 20)

        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: Int(size.width * 2),
                                           pixelsHigh: Int(size.height * 2),
                                           bitsPerSample: 8,
                                           samplesPerPixel: 4,
                                           hasAlpha: true,
                                           isPlanar: false,
                                           colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0,
                                           bitsPerPixel: 0) else {
            print("themes.png：建位图失败")
            return
        }
        canvas.size = size

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: canvas) {
            NSGraphicsContext.current = context
            NSColor(white: 0.10, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()

            for (index, palette) in PanelThemeCatalog.all.enumerated() {
                SettingsStore.shared.update { $0.panelTheme = palette.id }
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))

                let rowY = size.height - CGFloat(index + 1) * rowHeight
                let label = NSAttributedString(string: Loc.t(palette.name, palette.nameEn),
                                               attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                            .foregroundColor: NSColor(white: 0.62, alpha: 1)])
                label.draw(at: NSPoint(x: leading + labelWidth - label.size().width,
                                       y: rowY + (rowHeight - label.size().height) / 2))

                let island = CompactIslandView(content: content)
                    .frame(width: islandSize.width, height: islandSize.height)
                guard let rep = image(island, size: islandSize) else { continue }
                rep.draw(in: NSRect(x: leading + labelWidth + 16,
                                    y: rowY + (rowHeight - islandSize.height) / 2,
                                    width: islandSize.width,
                                    height: islandSize.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        SettingsStore.shared.update { $0.panelTheme = original }

        guard let png = canvas.representation(using: .png, properties: [:]) else {
            print("themes.png：编码失败")
            return
        }
        try? png.write(to: url)
        print("themes.png：\(canvas.pixelsWide)x\(canvas.pixelsHigh)")
    }

    private static func image(_ view: some View, size: CGSize) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = hosting
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: 0, y: -6000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    private static func save(_ view: some View, size: CGSize, to url: URL) {
        guard let rep = image(view, size: size) else {
            print("\(url.lastPathComponent)：取不到位图")
            return
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("\(url.lastPathComponent)：编码失败")
            return
        }
        try? png.write(to: url)
        print("\(url.lastPathComponent)：\(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}
